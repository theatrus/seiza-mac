import AppKit
import SwiftUI

@MainActor
final class ParallaxWindowController: NSObject, NSWindowDelegate {
    private static var windows: [UUID: ParallaxWindowController] = [:]
    private let id = UUID()
    private let session: ParallaxSession
    private var window: NSWindow!

    static var activeSession: ParallaxSession? {
        windows.values.first { $0.window === NSApp.keyWindow }?.session
    }

    static func present(model: ImageDocumentModel) {
        let controller = ParallaxWindowController(model: model)
        windows[controller.id] = controller
        controller.window.makeKeyAndOrderFront(nil)
    }

    private init(model: ImageDocumentModel) {
        session = ParallaxSession(model: model)
        super.init()
        window = NSWindow(contentViewController: NSHostingController(rootView: ParallaxWorkspace(session: session)))
        window.title = "Parallax Video — \(session.sourceName)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1150, height: 800))
        window.minSize = NSSize(width: 980, height: 680)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
    }

    func windowWillClose(_ notification: Notification) {
        session.close()
        Self.windows[id] = nil
    }
}

@MainActor
struct ParallaxWorkspace: View {
    @ObservedObject var session: ParallaxSession
    @ObservedObject private var setup = CatalogSetupController.shared
    @State private var inspector = "Source"
    @State private var showsActivity = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Parallax Video", systemImage: "film").font(.headline)
                Text(session.sourceName).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(action: session.undo) { Image(systemName: "arrow.uturn.backward") }
                    .help("Undo video edit").disabled(!session.canUndo || session.isBusy)
                Button(action: session.redo) { Image(systemName: "arrow.uturn.forward") }
                    .help("Redo video edit").disabled(!session.canRedo || session.isBusy)
                Button(session.hasScene ? "Update Preview" : "Prepare Preview", action: session.preparePreview).disabled(!session.canPrepare)
                Button("Export Video…", action: session.exportVideo).disabled(!session.canPrepare)
                    .buttonStyle(.borderedProminent)
            }.padding(12)
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    preview
                    if let warning = session.summary?.fit.edgeWarning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                            .padding(.horizontal, 12).padding(.top, 8)
                    }
                    transport.padding(12)
                    if session.composition.motion == .tour {
                        Divider()
                        stops
                    }
                }.frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 0) {
                    Picker("Inspector", selection: $inspector) {
                        ForEach(["Source", "Camera", "Labels", "Output"], id: \.self) { Text($0) }
                    }.pickerStyle(.segmented).labelsHidden().padding(12)
                    ScrollView {
                        Form {
                            switch inspector {
                            case "Camera": cameraInspector
                            case "Output": outputInspector
                            case "Labels": labelsInspector
                            default: sourceInspector
                            }
                        }.formStyle(.grouped)
                    }.disabled(session.isBusy)
                }.frame(minWidth: 310, idealWidth: 350, maxWidth: 440)
            }
            Divider()
            statusBar
        }
        .alert("Parallax Video", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
            Button("OK") { session.error = nil }
        } message: { Text(session.error ?? "") }
        .onAppear { setup.refreshStatus() }
        .onChange(of: setup.installVersion) { _, _ in session.catalogsDidChange() }
    }

    private var preview: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("View", selection: $session.showsSource) {
                    Text("Source").tag(true)
                    Text("Video Preview").tag(false)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 230)
                Spacer()
                if session.pickingDestination || session.pickingDistance { Text(session.pickingDistance ? "Click the scene’s distance reference" : "Click a destination in the source").foregroundStyle(.tint) }
            }.padding([.top, .horizontal], 12)
            GeometryReader { geometry in
                let image = session.showsSource ? session.sourceImage : session.previewImage
                ZStack {
                    Color.black
                    if let image {
                        Image(decorative: image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    } else {
                        ContentUnavailableView("Preview your camera move", systemImage: "play.rectangle",
                            description: Text("Choose the source and camera settings, then click Prepare Preview."))
                            .foregroundStyle(.white)
                    }
                    if session.showsSource, let point = pickedFocus {
                        let rect = sourceRect(in: geometry.size)
                        Image(systemName: "scope").font(.title).foregroundStyle(.orange)
                            .position(x: rect.minX + point[0] / Double(max(1, session.width)) * rect.width,
                                      y: rect.minY + point[1] / Double(max(1, session.height)) * rect.height)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                    guard session.showsSource, !session.isBusy else { return }
                    let rect = sourceRect(in: geometry.size)
                    guard rect.contains(value.location), rect.width > 0 else { return }
                    session.pick(x: (value.location.x - rect.minX) / rect.width * Double(session.width),
                                 y: (value.location.y - rect.minY) / rect.height * Double(session.height))
                })
            }.padding(.horizontal, 12)
        }
    }

    private var pickedFocus: [Double]? {
        if session.pickingDistance { return session.composition.scene.distanceFocus }
        if session.composition.motion == .tour, let index = session.selectedIndex {
            return session.composition.stops[index].focus
        }
        return session.composition.focus
    }

    private func sourceRect(in size: CGSize) -> CGRect {
        guard session.width > 0, session.height > 0 else { return .zero }
        let scale = min(size.width / Double(session.width), size.height / Double(session.height))
        let width = Double(session.width) * scale, height = Double(session.height) * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    private var transport: some View {
        HStack {
            Button(action: session.togglePlayback) { Image(systemName: session.isPlaying ? "pause.fill" : "play.fill") }
                .disabled(!session.hasPreview || session.isBusy)
                .help(session.isPlaying ? "Pause" : "Play preview")
            Slider(value: Binding(get: { min(session.playhead, timelineDuration) }, set: {
                session.stopPlayback(); session.playhead = $0; session.requestFrame()
            }), in: 0...timelineDuration)
                .disabled(!session.hasPreview || session.isBusy).accessibilityLabel("Video time")
            Text("\(session.playhead, specifier: "%.1f") / \(session.composition.duration, specifier: "%.1f") s")
                .monospacedDigit().font(.caption).frame(width: 110, alignment: .trailing)
        }
    }

    private var timelineDuration: Double {
        let duration = session.composition.duration
        return duration.isFinite && duration > 0 ? duration : 0.01
    }

    private var stops: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tour Stops").font(.headline)
                Spacer()
                Button("Load…", action: session.loadTour)
                Button("Save…", action: session.saveTour)
                Button("Add Point") { session.addStop(); inspector = "Camera" }
                Button("Add Whole Image") { session.addStop(whole: true) }
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(session.composition.stops.enumerated()), id: \.element.id) { index, stop in
                        Button {
                            session.selectStop(stop.id); inspector = "Camera"
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(index + 1). \(stop.displayName)").fontWeight(.medium).lineLimit(1)
                                Text("\(index == 0 ? 0 : stop.travel, specifier: "%.1f") s travel · \(stop.hold, specifier: "%.1f") s hold")
                                Text("\(stop.rotateDegrees, specifier: "%.0f")° roll · \(stop.pan * 100, specifier: "%.0f")% pan")
                                Text("\(stop.spinDegrees, specifier: "%.0f")° spin · \(stop.push * 100, specifier: "%.0f")% push")
                            }.font(.caption).frame(width: 175, alignment: .leading).padding(10)
                                .background(session.selectedStop == stop.id ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                    if session.composition.loopClosingDuration > 0 {
                        VStack(alignment: .leading, spacing: 5) {
                            Label("Return to opening", systemImage: "repeat")
                            Text("\(session.composition.loopClosingDuration, specifier: "%.1f") s travel and hold")
                            Text("Added automatically for the loop")
                        }.font(.caption).foregroundStyle(.secondary).padding(10)
                    }
                }
            }
        }.padding(12).disabled(session.isBusy)
    }

    @ViewBuilder private var sourceInspector: some View {
        Section("Source snapshot") {
            Text("\(session.width) × \(session.height) pixels")
            Text(session.hasWCS ? "Sky coordinates available" : "The source will be plate solved when preparing or generating a tour. If it fails, an aligned stars layer is tried when available.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Uses the current image adjustments. Imported layers must use the same stretch and alignment.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Star separation") {
            Toggle("Use StarXTerminator", isOn: $session.automaticSeparation)
            if session.automaticSeparation {
                inputPicker(.separator)
                Text("Requires your installed, licensed rc-astro CLI.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Choose Starless…") { session.chooseLayer(starless: true) }.disabled(!session.sourceReady)
                if let name = session.starlessName { Text(name).font(.caption).textSelection(.enabled) }
                Button("Choose Stars…") { session.chooseLayer(starless: false) }.disabled(!session.sourceReady)
                if let name = session.starsName { Text(name).font(.caption).textSelection(.enabled) }
                Text("PNG or TIFF, full size. Stars must be unscreened.").font(.caption).foregroundStyle(.secondary)
                Toggle("Layers match source alignment and stretch", isOn: $session.layersAligned)
                    .disabled(session.starlessName == nil || session.starsName == nil)
            }
        }
        Section("Scene depth") {
            DistanceCatalogDownloadView(setup: setup, magnitude: session.composition.scene.gaiaMaxMagnitude)
            Toggle("Look up stellar distances online", isOn: compositionBinding(\.scene.online))
            Text("Uses the installed database when it covers the selected Gaia limit. Online lookup sends sky coordinates to the catalogues when needed. Unmatched stars use the fallback distance.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Distance reference: \(session.composition.distanceName)").font(.caption)
            Button("Pick Distance Reference", action: session.pickDistanceReference)
            HStack {
                TextField("X", value: distanceCoordinate(0), format: .number)
                TextField("Y", value: distanceCoordinate(1), format: .number)
            }
            Text("Moving the camera does not change this reference.").font(.caption).foregroundStyle(.secondary)
            optionalNumber("Set background distance", key: \.scene.distanceParsecs, fallback: 400, label: "Background (pc)")
            optionalNumber("Set unmatched star distance", key: \.scene.unmatchedDistanceParsecs, fallback: 1000, label: "Unmatched (pc)")
            TextField("Gaia magnitude limit", value: compositionBinding(\.scene.gaiaMaxMagnitude), format: .number)
        }
        Section("Stars and dust") {
            Toggle("Limit moving stars", isOn: Binding(get: { session.composition.scene.maxStars != nil }, set: { enabled in
                session.edit { $0.scene.maxStars = enabled ? 2000 : nil }
            }))
            if session.composition.scene.maxStars != nil {
                TextField("Brightest stars", value: Binding(get: { session.composition.scene.maxStars ?? 2000 }, set: { value in
                    session.edit { $0.scene.maxStars = value }
                }), format: .number)
            }
            Picker("Remaining stars", selection: compositionBinding(\.scene.smallStars)) {
                Text("Keep on field").tag("field"); Text("Drop").tag("drop")
            }
            Toggle("Keep galaxies on background", isOn: compositionBinding(\.scene.keepGalaxies))
            Toggle("Dust dimming", isOn: compositionBinding(\.scene.dust))
            TextField("Dust strength", value: compositionBinding(\.scene.dustOpacity), format: .number)
                .disabled(!session.composition.scene.dust)
            // A map painted white where the dust is opaque replaces the counted
            // dust; stars seen through its opaque places fly in front.
            inputPicker(.dustMap).disabled(!session.composition.scene.dust)
            HStack {
                Button("Reload") { session.reloadDustMap() }.disabled(!session.canReloadDustMap)
                Button("Export Dust Map…") { session.exportDustMap() }.disabled(!session.canExportDustMap)
            }
            Text(session.dustDescription).font(.caption)
        }
        Section("Depth planes") {
            Toggle("Automatic depth planes", isOn: compositionBinding(\.scene.autoPlanes))
            Text("Catalogued nebulae at distances of their own, and dust clouds in front of the nebula, move on planes of their own. A dark nebula moves with the dust it lies in.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(session.listedPlanes.enumerated()), id: \.offset) { _, plane in planeRow(plane) }
            if let description = session.planesDescription { Text(description).font(.caption) }
            // A distance whose object places no listed plane: it may have moved
            // its plane within reach of the nebula, or planes may be off.
            ForEach(session.unlistedDistances, id: \.object) { given in
                HStack {
                    Text("\(given.object): \(given.distanceParsecs, specifier: "%.0f") pc").font(.caption)
                    Spacer()
                    Button("Remove") { session.clearDistance(for: given.object) }
                }
            }
        }
        DisclosureGroup("Catalogues and solving") {
            Text(CatalogAccess.displayPath.isEmpty ? "Choose a catalogue directory in Seiza Settings to enable solving and tour generation." : CatalogAccess.displayPath)
                .font(.caption).textSelection(.enabled)
            inputPicker(.objects); inputPicker(.objectDistances); inputPicker(.starDistances)
            TextField("Minimum scale (arcsec/px)", value: compositionBinding(\.scene.minimumScaleArcsecPerPixel), format: .number)
            TextField("Maximum scale (arcsec/px)", value: compositionBinding(\.scene.maximumScaleArcsecPerPixel), format: .number)
        }
        if let summary = session.summary {
            Section("Prepared scene") {
                Text("\(summary.withDistance) / \(summary.detectedStars) stars with distances")
                Text("Background: \(summary.backgroundDistanceParsecs, specifier: "%.0f") pc (\(summary.backgroundBasis))").font(.caption)
            }
        }
        if !session.warnings.isEmpty {
            Section("Preparation notes") {
                ForEach(session.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            }
        }
        if !session.preparationNotes.isEmpty {
            DisclosureGroup("Preparation details") {
                ForEach(Array(session.preparationNotes.enumerated()), id: \.offset) { _, note in
                    Text(note).font(.caption).textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder private var cameraInspector: some View {
        Section {
            Picker("Motion", selection: compositionBinding(\.motion)) {
                ForEach(ParallaxComposition.Motion.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
        }
        Section("Generate tour") {
            Toggle("Automatic target count", isOn: Binding(get: { session.tourOptions.targets == nil }, set: { session.tourOptions.targets = $0 ? nil : 5 }))
            if session.tourOptions.targets != nil {
            Stepper("Targets: \(session.tourOptions.targets ?? 5)", value: Binding(get: { session.tourOptions.targets ?? 5 }, set: { session.tourOptions.targets = $0 }), in: 1...20)
            }
            TextField("Hold per stop (s)", value: $session.tourOptions.hold, format: .number)
            Slider(value: $session.tourOptions.motion, in: 0...2) { Text("Motion") }
            Text("Motion \(session.tourOptions.motion, specifier: "%.1f")× · 0 removes generated roll and pan")
                .font(.caption).foregroundStyle(.secondary)
            Button(session.hasWCS ? "Generate Tour" : "Solve & Generate Tour", action: session.generateTour)
                .disabled(!session.sourceReady || setup.isRunning)
            if let candidate = session.candidate {
                Text("\(candidate.tour.count) stops · \(candidate.seconds, specifier: "%.1f") seconds")
                HStack {
                    Button("Apply Tour", action: session.applyCandidate)
                    Button("Keep Draft", action: session.discardCandidate)
                }
            }
        }
        if session.composition.motion == .flyIn {
            Section("Fly in") {
                TextField("Duration (s)", value: compositionBinding(\.seconds), format: .number)
                Picker("Start", selection: compositionBinding(\.start)) { Text("Whole Image").tag("whole"); Text("At Focus").tag("focus") }
                Button("Pick Destination") { session.pickingDistance = false; session.showsSource = true; session.pickingDestination = true }
                Button("Use Image Center") { session.edit { $0.focus = [Double(session.width - 1) / 2, Double(session.height - 1) / 2]; $0.focusName = "Image center" } }
                destinationCoordinates
                Slider(value: compositionBinding(\.dolly), in: 0...0.95) { Text("Dolly") }
                Slider(value: compositionBinding(\.pan), in: 0...1) { Text("Pan") }
                TextField("Start roll (°)", value: compositionBinding(\.rotationStart), format: .number)
                TextField("End roll (°)", value: compositionBinding(\.rotation), format: .number)
                rollExplanation
                TextField("Opening zoom", value: compositionBinding(\.zoom), format: .number)
                TextField("End lens multiplier", value: compositionBinding(\.zoomEnd), format: .number)
                TextField("Sideways swing", value: compositionBinding(\.truck), format: .number)
                TextField("Swing direction (°)", value: compositionBinding(\.truckAngleDegrees), format: .number)
                Picker("Easing", selection: compositionBinding(\.easing)) {
                    Text("Smooth").tag("inOut"); Text("Linear").tag("linear")
                }
            }
        } else if let index = session.selectedIndex {
            Section("Stop \(index + 1)") {
                TextField("Name", text: Binding(get: { session.composition.stops[index].name ?? "" }, set: { name in session.editStop { $0.name = name } }))
                TextField("On-screen title", text: Binding(get: { session.composition.stops[index].title ?? "" }, set: { title in session.editStop { $0.title = title.isEmpty ? nil : title } }))
                    .help("Shown during this stop when Show stop titles is enabled. Leave blank for no title.")
                overlayPicker("Card", path: session.composition.stops[index].card, slot: .stop(session.composition.stops[index].id))
                    .help("An image with transparency shown during this stop in place of its title, with or without stop titles.")
                    Button("Pick Destination") { session.pickingDistance = false; session.showsSource = true; session.pickingDestination = true }
                Button("Use Whole Image") { session.editStop { $0.focus = nil; $0.name = "Whole Image"; $0.dolly = 0; $0.zoom = 1; $0.pan = 0 } }
                destinationCoordinates
                TextField("Travel to stop (s)", value: stopBinding(\.travel), format: .number).disabled(index == 0)
                TextField("Hold (s)", value: stopBinding(\.hold), format: .number)
                Text("Set hold to 0 to pass straight through. Glide, spin and push can keep a held stop moving.").font(.caption).foregroundStyle(.secondary)
                Slider(value: stopBinding(\.dolly), in: 0...0.95) { Text("Dolly") }
                TextField("Zoom", value: stopBinding(\.zoom), format: .number)
                Slider(value: stopBinding(\.pan), in: 0...1) { Text("Pan") }
                TextField("Roll (°)", value: stopBinding(\.rotateDegrees), format: .number)
                HStack {
                    Button("Travel Turn CW") { session.edit { $0.setTravelTurn(at: index, clockwise: true) } }
                    Button("Travel Turn CCW") { session.edit { $0.setTravelTurn(at: index, clockwise: false) } }
                }.disabled(index == 0)
                TextField("Spin around stop (°)", value: stopBinding(\.spinDegrees), format: .number)
                HStack {
                    Button("Spin CW") { session.edit { $0.setSpin(at: index, clockwise: true) } }
                    Button("Spin CCW") { session.edit { $0.setSpin(at: index, clockwise: false) } }
                }
                Slider(value: stopBinding(\.push), in: 0...0.95) { Text("Push during hold") }
                Text("Push \(session.composition.stops[index].push * 100, specifier: "%.0f")% of the remaining distance")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Spin blends into arrival and departure and carries through later stops. It needs a positive hold; combine it with push for a spiral.")
                    .font(.caption).foregroundStyle(.secondary)
                rollExplanation
                HStack {
                    Button("Earlier") { session.moveStop(-1) }.disabled(index == 0)
                    Button("Later") { session.moveStop(1) }.disabled(index == session.composition.stops.count - 1)
                }
                HStack {
                    Button("Duplicate", action: session.duplicateStop)
                    Button("Remove", action: session.removeStop).disabled(session.composition.stops.count <= 2)
                }
            }
        } else { Text("Select a stop below the image to edit its camera and timing.").foregroundStyle(.secondary) }
        if session.composition.motion == .tour {
            Section("Tour motion") {
                TextField("Overall zoom", value: compositionBinding(\.zoom), format: .number)
                    .help("Multiplies every stop's zoom, including the opening stop.")
                TextField("Glide through holds", value: compositionBinding(\.tourGlide), format: .number)
                Text("A fraction of travel speed: 0 pauses, 0.2 glides gently. Spinning stops turn around their own destination.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show stop titles", isOn: compositionBinding(\.tourTitles))
                Toggle("Loop tour", isOn: compositionBinding(\.tourLoop))
                Text(session.composition.tourLoop
                    ? "Returns to the opening view with a gentle zoom through the join, even at zero glide. Push at the opening and closing stops is unused."
                    : "The final hold drifts gently to rest.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("Preview") {
            Toggle("Update camera preview automatically", isOn: $session.automaticPreview)
            if let fit = session.summary?.fit {
                if let warning = fit.edgeWarning {
                    Text(warning).font(.caption).foregroundStyle(.orange)
                } else if fit.adjustments.isEmpty {
                    Text("Requested framing fits the image.").font(.caption)
                }
                if !fit.adjustments.isEmpty {
                    Text(fit.inside ? "Adjusted to keep image edges outside the frame:" : "Framing adjustments applied:").font(.caption)
                    ForEach(fit.adjustments, id: \.self) { Text($0).font(.caption).monospacedDigit() }
                }
            }
        }
    }

    private var rollExplanation: some View {
        Text("Positive roll and spin turn counterclockwise. Roll defines travel between stops; spin adds a turn around a held stop. Pan turns toward the destination; 0 uses translation only.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var destinationCoordinates: some View {
        HStack {
            TextField("X", value: coordinateBinding(0), format: .number)
            TextField("Y", value: coordinateBinding(1), format: .number)
        }.help("Destination in source pixels, measured from the top-left corner")
    }

    private func coordinateBinding(_ axis: Int) -> Binding<Double> {
        Binding(get: {
            pickedFocus?[axis] ?? Double((axis == 0 ? session.width : session.height) - 1) / 2
        }, set: { value in
            var point = pickedFocus ?? [Double(session.width - 1) / 2, Double(session.height - 1) / 2]
            point[axis] = value
            if session.composition.motion == .tour {
                session.editStop { $0.focus = point; $0.name = "Custom Point" }
            } else { session.edit { $0.focus = point; $0.focusName = "Custom Point" } }
        })
    }

    @ViewBuilder private var outputInspector: some View {
        Section("Video") {
            HStack {
                Button("720p") { session.edit { $0.width = 1280; $0.height = 720 } }
                Button("1080p") { session.edit { $0.width = 1920; $0.height = 1080 } }
                Button("1440p") { session.edit { $0.width = 2560; $0.height = 1440 } }
                Button("4K") { session.edit { $0.width = 3840; $0.height = 2160 } }
            }
            Button("Swap Orientation") { session.edit { swap(&$0.width, &$0.height) } }
            TextField("Width", value: compositionBinding(\.width), format: .number)
            TextField("Height", value: compositionBinding(\.height), format: .number)
            Picker("Frames per second", selection: compositionBinding(\.fps)) {
                ForEach([24, 30, 60], id: \.self) { Text(String($0)).tag($0) }
            }
            Picker("Codec", selection: $session.codec) {
                ForEach(NativeVideoExporter.Codec.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Picker("Quality", selection: compositionBinding(\.quality)) { Text("Standard").tag("standard"); Text("High").tag("high") }
            TextField("Star growth limit", value: compositionBinding(\.growthLimit), format: .number)
                .help("At least 1. Stars swell by the square root of the capped growth: 4 allows twice their original size.")
            TextField("Fade stars from growth", value: compositionBinding(\.fadeFrom), format: .number)
                .help("Stars start fading at this growth and disappear at twice it.")
            Text("MP4 · SDR · silent\nPreview uses a smaller frame. Export renders every frame at the selected resolution.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if session.isBusy || session.isReconfiguring {
                if let progress = session.progress { ProgressView(value: progress).frame(width: 110) }
                else { ProgressView().controlSize(.small) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(session.composition.validationMessage ??
                    (session.isBusy && !session.activity.cancellationRequested ? session.activity.networkPhase : nil) ?? session.status)
                    .font(.caption).lineLimit(2)
                if session.isBusy || session.isReconfiguring {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.activity.detail(at: context.date)).monospacedDigit()
                            if let waiting = session.activity.waitingMessage(at: context.date) { Text(waiting) }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button("Activity…") { showsActivity.toggle() }
                .popover(isPresented: $showsActivity) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Preparation activity").font(.headline)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(session.activity.entries) { entry in
                                    HStack(alignment: .top) {
                                        Text(ParallaxActivity.time(entry.elapsed)).monospacedDigit().foregroundStyle(.secondary)
                                        Text(entry.message).foregroundStyle(entry.warning ? .orange : .primary).textSelection(.enabled)
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.font(.caption).padding(16).frame(width: 520, height: 300)
                }
            if session.isBusy || session.isReconfiguring { Button("Cancel", action: session.cancel).disabled(!session.sourceReady || session.activity.cancellationRequested) }
            if let url = session.exportedURL { Button("Show Video") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
        }.padding(12)
    }

    private func compositionBinding<T>(_ key: WritableKeyPath<ParallaxComposition, T>) -> Binding<T> {
        Binding(get: { session.composition[keyPath: key] }, set: { value in session.edit { $0[keyPath: key] = value } })
    }

    @ViewBuilder private var labelsInspector: some View {
        Section("Catalogue labels") {
            Toggle("Object labels", isOn: compositionBinding(\.overlay))
            Slider(value: compositionBinding(\.overlayDensity), in: 0...1) { Text("Density") }
            Text("Labels follow the depth and camera projection of their objects.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Custom labels") {
            TextField("Color (#RRGGBB)", text: compositionBinding(\.labelColor))
            ForEach(session.composition.labels) { label in
                VStack(alignment: .leading) {
                    TextField("Text", text: labelBinding(label.id, \.text, fallback: ""))
                    HStack {
                        TextField("X", value: labelBinding(label.id, \.x, fallback: 0), format: .number)
                        TextField("Y", value: labelBinding(label.id, \.y, fallback: 0), format: .number)
                    }
                    TextField("Radius (px)", value: labelBinding(label.id, \.radius, fallback: 0), format: .number)
                    Button("Remove Label") { session.edit { $0.labels.removeAll { $0.id == label.id } } }
                }
            }
            Button("Add Label") {
                session.edit { $0.labels.append(ParallaxLabel(x: Double(session.width - 1) / 2, y: Double(session.height - 1) / 2)) }
            }
            Text("Positions and radius use source pixels.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Credit and logo") {
            Toggle("Show credit", isOn: compositionBinding(\.creditEnabled))
            TextField("Credit text", text: compositionBinding(\.credit)).disabled(!session.composition.creditEnabled)
            overlayPicker("Logo", path: session.composition.logoPath, slot: .logo)
            Picker("Corner", selection: compositionBinding(\.watermarkCorner)) {
                Text("Bottom right").tag("bottomRight"); Text("Bottom left").tag("bottomLeft")
                Text("Top right").tag("topRight"); Text("Top left").tag("topLeft")
            }
            TextField("Logo height (share of frame)", value: compositionBinding(\.watermarkSize), format: .number)
                .disabled(session.composition.logoPath == nil)
            Slider(value: compositionBinding(\.watermarkOpacity), in: 0...1) { Text("Opacity") }
            Text("The logo sits in the credit's corner, just inside the credit text.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Title cards") {
            overlayPicker("Opening Card", path: session.composition.introCard, slot: .intro)
            overlayPicker("Closing Card", path: session.composition.outroCard, slot: .outro)
            TextField("Card duration (s)", value: compositionBinding(\.cardSeconds), format: .number)
            Text("Images with transparency, fitted inside the frame: make them the frame's size for sharp lettering. The opening card fades out after the start and the closing card fades in for the end; a looping tour shows them across its join.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// A button to choose an image laid over the video, and to remove it.
    private func overlayPicker(_ title: String, path: String?, slot: ParallaxSession.OverlayImage) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Button("Choose \(title)…") { session.chooseOverlayImage(slot) }
                if path != nil { Button("Remove") { session.clearOverlayImage(slot) } }
            }
            if let path { Text(URL(fileURLWithPath: path).lastPathComponent).font(.caption).textSelection(.enabled) }
        }
    }

    private func labelBinding<T>(_ id: UUID, _ key: WritableKeyPath<ParallaxLabel, T>, fallback: T) -> Binding<T> {
        Binding(get: { session.composition.labels.first { $0.id == id }?[keyPath: key] ?? fallback }, set: { value in
            session.edit { if let index = $0.labels.firstIndex(where: { $0.id == id }) { $0.labels[index][keyPath: key] = value } }
        })
    }

    /// A depth plane's name, distance, how the distance was found and how much
    /// of the image it covers. A plane its catalogued object places takes a
    /// distance of the user's.
    private func planeRow(_ plane: ParallaxPlane) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(plane.name).fontWeight(.medium)
            if let object = plane.object {
                HStack {
                    TextField("Distance (pc)", value: planeDistance(object, prepared: plane.distanceParsecs), format: .number)
                    if session.composition.scene.givenDistance(for: object) != nil {
                        Button("Use Catalogue") { session.clearDistance(for: object) }
                    }
                }
            } else {
                Text("\(plane.distanceParsecs, specifier: "%.0f") pc")
            }
            Text("\(plane.basis) · \(plane.coverage * 100, specifier: "%.1f")% of the image\(plane.absorbs ? " · dark cloud" : "")")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private func planeDistance(_ object: String, prepared: Double) -> Binding<Double> {
        Binding(get: { session.composition.scene.givenDistance(for: object) ?? prepared }, set: { value in
            // Committing the prepared distance unchanged gives no distance.
            guard session.composition.scene.givenDistance(for: object) != nil || value != prepared else { return }
            session.setDistance(value, for: object)
        })
    }

    private func inputPicker(_ kind: ParallaxSession.InputFile) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Button("Choose \(kind.rawValue)…") { session.chooseInput(kind) }
                if session.inputNames[kind] != nil { Button("Reset") { session.clearInput(kind) } }
            }
            if let name = session.inputNames[kind] { Text(name).font(.caption).textSelection(.enabled) }
        }
    }

    private func optionalNumber(_ title: String, key: WritableKeyPath<ParallaxComposition, Double?>,
                                fallback: Double, label: String) -> some View {
        VStack(alignment: .leading) {
            Toggle(title, isOn: Binding(get: { session.composition[keyPath: key] != nil }, set: { enabled in
                session.edit { $0[keyPath: key] = enabled ? fallback : nil }
            }))
            if session.composition[keyPath: key] != nil {
                TextField(label, value: Binding(get: { session.composition[keyPath: key] ?? fallback }, set: { value in
                    session.edit { $0[keyPath: key] = value }
                }), format: .number)
            }
        }
    }

    private func distanceCoordinate(_ axis: Int) -> Binding<Double> {
        Binding(get: { session.composition.scene.distanceFocus?[axis] ?? 0 }, set: { value in
            session.edit {
                var point = $0.scene.distanceFocus ?? [Double(session.width - 1) / 2, Double(session.height - 1) / 2]
                point[axis] = value; $0.scene.distanceFocus = point; $0.distanceName = "Custom point"
            }
        })
    }
    private func stopBinding(_ key: WritableKeyPath<ParallaxStop, Double>) -> Binding<Double> {
        Binding(get: { session.selectedIndex.map { session.composition.stops[$0][keyPath: key] } ?? 0 },
                set: { value in session.editStop { $0[keyPath: key] = value } })
    }
}
