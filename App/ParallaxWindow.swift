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
    @State private var distanceObject = ""
    @State private var objectDistance = 1000.0
    @State private var drawingCrop = false
    @State private var lockCropToFrame = false
    @State private var cropDrag: ParallaxCrop?

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
                    if session.showsSource, let crop = cropDrag ?? session.composition.scene.crop {
                        let rect = sourceRect(in: geometry.size)
                        let scale = rect.width / Double(max(1, session.width))
                        let cropRect = CGRect(x: rect.minX + Double(crop.x) * scale,
                            y: rect.minY + Double(crop.y) * scale,
                            width: Double(crop.width) * scale, height: Double(crop.height) * scale)
                        Path { path in path.addRect(rect); path.addRect(cropRect) }
                            .fill(.black.opacity(0.5), style: FillStyle(eoFill: true))
                        Path { $0.addRect(cropRect) }.stroke(.yellow, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    }
                    if session.showsSource, let point = pickedFocus {
                        let rect = sourceRect(in: geometry.size)
                        Image(systemName: "scope").font(.title).foregroundStyle(.orange)
                            .position(x: rect.minX + point[0] / Double(max(1, session.width)) * rect.width,
                                      y: rect.minY + point[1] / Double(max(1, session.height)) * rect.height)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    guard drawingCrop, session.showsSource, !session.isBusy else { return }
                    let rect = sourceRect(in: geometry.size)
                    guard rect.width > 0 else { return }
                    let scale = Double(session.width) / rect.width
                    let frame = session.composition.outputSize
                    cropDrag = ParallaxCrop.selecting(
                        from: CGPoint(x: (value.startLocation.x - rect.minX) * scale, y: (value.startLocation.y - rect.minY) * scale),
                        to: CGPoint(x: (value.location.x - rect.minX) * scale, y: (value.location.y - rect.minY) * scale),
                        width: session.width, height: session.height,
                        aspect: lockCropToFrame ? Double(frame.width) / Double(max(1, frame.height)) : nil)
                }.onEnded { value in
                    guard session.showsSource, !session.isBusy else { return }
                    if drawingCrop {
                        if let cropDrag { session.edit { $0.setCrop(cropDrag) }; drawingCrop = false }
                        cropDrag = nil
                        return
                    }
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
            Text("\(Int(session.composition.filmedBounds.width)) × \(Int(session.composition.filmedBounds.height)) pixels")
            Text(session.hasWCS ? "Sky coordinates available" : "The original file is solved first using its astrometric headers, followed by the snapshot and an aligned stars layer when needed.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Uses the current image adjustments. Imported layers must use the same stretch and alignment.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Crop") {
            HStack {
                Button(drawingCrop ? "Cancel Crop" : "Draw Crop") {
                    drawingCrop.toggle(); cropDrag = nil
                    session.showsSource = true; session.pickingDistance = false; session.pickingDestination = false
                }
                Button("Use Full Image") { session.edit { $0.setCrop(nil) }; cropDrag = nil; drawingCrop = false }
                    .disabled(session.composition.scene.crop == nil)
            }
            Toggle("Lock crop to frame shape", isOn: $lockCropToFrame)
            HStack {
                TextField("X", value: cropBinding(\.x), format: .number)
                TextField("Y", value: cropBinding(\.y), format: .number)
            }
            HStack {
                TextField("Width", value: cropBinding(\.width), format: .number)
                TextField("Height", value: cropBinding(\.height), format: .number)
            }
            Text(drawingCrop ? "Drag a rectangle on the source image." : "Source pixels. Changing the crop requires a new scene preparation.")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(!session.sourceReady)
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
        }
        Section("Object distances") {
            TextField("Object name", text: $distanceObject, prompt: Text("e.g. NGC 7000"))
            TextField("Distance (pc)", value: $objectDistance, format: .number)
            Button("Add or Update Distance") {
                if session.addDistanceOverride(object: distanceObject, parsecs: objectDistance) { distanceObject = "" }
            }.disabled(distanceObject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !objectDistance.isFinite || objectDistance <= 0)
            Text("Use any catalogue object name, including a large nebula left on the background. Enable Automatic depth planes to lift it at the given distance. Unknown names are reported when preparing the scene.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(session.composition.scene.distanceOverrides, id: \.object) { given in
                HStack {
                    TextField("\(given.object) (pc)", value: Binding(
                        get: { session.composition.scene.givenDistance(for: given.object) ?? given.distanceParsecs },
                        set: { session.setDistance($0, for: given.object) }), format: .number)
                    Button("Remove") { session.clearDistance(for: given.object) }
                }
            }
        }
        Section("Custom depth planes") {
            Button("Import Mask…") { session.choosePlaneMask() }.disabled(!session.sourceReady)
            Text("White marks the region to lift; black stays behind. Masks may be smaller but must match the source's aspect ratio. Use values from 0 to 1 for FITS or XISF masks. Custom planes work with automatic planes on or off.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(session.composition.scene.planes) { plane in
                VStack(alignment: .leading) {
                    TextField("Name", text: planeBinding(plane, \.name))
                    TextField("Distance (pc)", value: planeBinding(plane, \.distanceParsecs), format: .number)
                    Text(URL(fileURLWithPath: plane.mask).lastPathComponent).font(.caption).textSelection(.enabled)
                    HStack {
                        Button("Replace Mask…") { session.choosePlaneMask(replacing: plane.id) }
                        Button("Reload") { session.reloadPlane(plane.id) }
                        Button("Remove") { session.removePlane(plane.id) }
                    }
                }
            }
            if !session.composition.scene.planes.isEmpty {
                Text("Prepare Preview after changes. Reload after painting a mask in another app. Tour files contain camera stops; these scene settings stay in this workspace.")
                    .font(.caption).foregroundStyle(.secondary)
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
            if session.hasScene {
                Text("Plans on the prepared scene, including its depth planes and distance overrides. Applying the tour reuses that scene.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Prepare Preview first to generate framing from the scene's depths. Without a prepared scene, generation uses catalogue distances.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
                Button("Use Image Center") { session.edit { $0.focus = $0.imageCenter; $0.focusName = "Image center" } }
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
                Button("Use Whole Image") { session.editStop { $0.focus = nil; $0.depthParsecs = nil; $0.name = "Whole Image"; $0.dolly = 0; $0.zoom = 1; $0.pan = 0 } }
                destinationCoordinates
                Toggle("Follow scene depth", isOn: Binding(
                    get: { session.composition.stops[index].depthParsecs == nil },
                    set: { follow in session.editStop {
                        $0.depthParsecs = follow ? nil : session.summary?.backgroundDistanceParsecs ?? session.composition.scene.distanceParsecs ?? 1000
                    } }))
                if session.composition.stops[index].depthParsecs != nil {
                    TextField("Stop depth (pc)", value: Binding(
                        get: { session.composition.stops[index].depthParsecs ?? 1000 },
                        set: { depth in session.editStop { $0.depthParsecs = depth } }), format: .number)
                }
                Text("Follow the plane under the destination, or give a depth for this stop's framing. This does not move the scene's planes.")
                    .font(.caption).foregroundStyle(.secondary)
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
        }.help("Destination in filmed-image pixels, measured from the crop's top-left corner")
    }

    private func coordinateBinding(_ axis: Int) -> Binding<Double> {
        Binding(get: {
            session.composition.videoPoint(pickedFocus ?? session.composition.imageCenter)[axis]
        }, set: { value in
            var point = session.composition.videoPoint(pickedFocus ?? session.composition.imageCenter)
            guard point[axis] != value else { return }
            point[axis] = value
            point = session.composition.sourcePoint(point)
            if session.composition.motion == .tour {
                session.editStop { $0.focus = point; $0.name = "Custom Point" }
            } else { session.edit { $0.focus = point; $0.focusName = "Custom Point" } }
        })
    }

    @ViewBuilder private var outputInspector: some View {
        Section("Video") {
            Picker("Framing", selection: compositionBinding(\.framing)) {
                Text("Fill Frame").tag("fill")
                Text("Show Whole Image").tag("fit")
            }
            Text(session.composition.framing == "fit" ? "Shows the entire image, with black space when the frame has a different shape." : "Fills the frame by cropping image edges when the shapes differ.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("720p") { session.edit { $0.width = 1280; $0.height = 720 } }
                Button("1080p") { session.edit { $0.width = 1920; $0.height = 1080 } }
                Button("1440p") { session.edit { $0.width = 2560; $0.height = 1440 } }
                Button("4K") { session.edit { $0.width = 3840; $0.height = 2160 } }
            }
            Toggle("Match image shape", isOn: compositionBinding(\.matchImageShape))
            Button("Swap Orientation") { session.edit { swap(&$0.width, &$0.height) } }
                .disabled(session.composition.matchImageShape)
            TextField("Width", value: Binding(get: { session.composition.outputSize.width },
                set: { value in session.edit { $0.width = value } }), format: .number)
                .disabled(session.composition.matchImageShape)
            TextField("Height", value: Binding(get: { session.composition.outputSize.height },
                set: { value in session.edit { $0.height = value } }), format: .number)
                .disabled(session.composition.matchImageShape)
            Text("Video: \(session.composition.outputSize.width) × \(session.composition.outputSize.height) pixels")
                .font(.caption).monospacedDigit()
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
                        TextField("X", value: labelPositionBinding(label.id, axis: 0), format: .number)
                        TextField("Y", value: labelPositionBinding(label.id, axis: 1), format: .number)
                    }
                    TextField("Radius (px)", value: labelBinding(label.id, \.radius, fallback: 0), format: .number)
                    Button("Remove Label") { session.edit { $0.labels.removeAll { $0.id == label.id } } }
                }
            }
            Button("Add Label") {
                session.edit { $0.labels.append(ParallaxLabel(x: $0.imageCenter[0], y: $0.imageCenter[1])) }
            }
            Text("Positions use filmed-image pixels from the crop's top-left corner; radius uses image pixels.").font(.caption).foregroundStyle(.secondary)
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

    private func planeBinding<T>(_ plane: ParallaxMaskPlane, _ key: WritableKeyPath<ParallaxMaskPlane, T>) -> Binding<T> {
        Binding(get: { session.composition.scene.planes.first { $0.id == plane.id }?[keyPath: key] ?? plane[keyPath: key] },
                set: { value in session.editPlane(plane.id) { $0[keyPath: key] = value } })
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
        Binding(get: { session.composition.videoPoint(session.composition.scene.distanceFocus ?? session.composition.imageCenter)[axis] }, set: { value in
            let current = session.composition.videoPoint(session.composition.scene.distanceFocus ?? session.composition.imageCenter)
            guard current[axis] != value else { return }
            session.edit {
                var point = $0.videoPoint($0.scene.distanceFocus ?? $0.imageCenter)
                point[axis] = value; $0.scene.distanceFocus = $0.sourcePoint(point); $0.distanceName = "Custom point"
            }
        })
    }

    private func cropBinding(_ key: WritableKeyPath<ParallaxCrop, Int>) -> Binding<Int> {
        Binding(get: {
            (session.composition.scene.crop ?? ParallaxCrop(x: 0, y: 0, width: session.width, height: session.height))[keyPath: key]
        }, set: { value in
            var crop = session.composition.scene.crop ?? ParallaxCrop(x: 0, y: 0, width: session.width, height: session.height)
            crop[keyPath: key] = value
            crop.x = min(max(0, crop.x), max(0, session.width - 16))
            crop.y = min(max(0, crop.y), max(0, session.height - 16))
            crop.width = min(max(16, crop.width), session.width - crop.x)
            crop.height = min(max(16, crop.height), session.height - crop.y)
            if lockCropToFrame {
                let frame = session.composition.outputSize
                let aspect = Double(max(16, frame.width)) / Double(max(16, frame.height))
                if let locked = ParallaxCrop.selecting(from: CGPoint(x: crop.x, y: crop.y),
                    to: CGPoint(x: crop.x + crop.width, y: crop.y + crop.height), width: session.width, height: session.height, aspect: aspect) {
                    crop = locked
                }
            }
            session.edit { $0.setCrop(crop) }
        })
    }

    private func labelPositionBinding(_ id: UUID, axis: Int) -> Binding<Double> {
        Binding(get: {
            guard let label = session.composition.labels.first(where: { $0.id == id }) else { return 0 }
            return session.composition.videoPoint([label.x, label.y])[axis]
        }, set: { value in
            session.edit {
                guard let index = $0.labels.firstIndex(where: { $0.id == id }) else { return }
                var point = $0.videoPoint([$0.labels[index].x, $0.labels[index].y]); point[axis] = value
                point = $0.sourcePoint(point)
                $0.labels[index].x = point[0]; $0.labels[index].y = point[1]
            }
        })
    }
    private func stopBinding(_ key: WritableKeyPath<ParallaxStop, Double>) -> Binding<Double> {
        Binding(get: { session.selectedIndex.map { session.composition.stops[$0][keyPath: key] } ?? 0 },
                set: { value in session.editStop { $0[keyPath: key] = value } })
    }
}
