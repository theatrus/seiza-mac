import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class ParallaxScopedURL: @unchecked Sendable {
    let url: URL
    private let accessing: Bool
    init(_ url: URL) { self.url = url; accessing = url.startAccessingSecurityScopedResource() }
    deinit { if accessing { url.stopAccessingSecurityScopedResource() } }
}

final class ParallaxFiles: @unchecked Sendable {
    let directory: URL
    var image: URL { directory.appendingPathComponent("source.png") }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Seiza-Parallax-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    func importLayer(_ source: URL, width: Int, height: Int) throws -> URL {
        let access = ParallaxScopedURL(source)
        return try withExtendedLifetime(access) {
            guard let image = CGImageSourceCreateWithURL(source as CFURL, nil),
                let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                props[kCGImagePropertyPixelWidth] as? Int == width,
                props[kCGImagePropertyPixelHeight] as? Int == height,
                (props[kCGImagePropertyOrientation] as? Int ?? 1) == 1
            else { throw SeizaCoreError.message("Layers must match the source's \(width) × \(height) pixels and have no orientation transform. Export aligned, stretched PNG or TIFF layers.") }
            let output = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(source.pathExtension)
            try FileManager.default.copyItem(at: source, to: output)
            return output
        }
    }
}

@MainActor
final class ParallaxSession: ObservableObject {
    @Published private(set) var composition = ParallaxComposition()
    @Published var selectedStop: UUID?
    @Published var showsSource = true
    @Published var pickingDestination = false
    @Published var playhead = 0.0
    @Published private(set) var sourceImage: CGImage?
    @Published private(set) var previewImage: CGImage?
    @Published private(set) var isBusy = false
    @Published private(set) var isPlaying = false
    @Published private(set) var sourceReady = false
    @Published private(set) var status = "Preparing source snapshot…"
    @Published private(set) var progress: Double?
    @Published private(set) var activity = ParallaxActivity(message: "Preparing source snapshot…")
    @Published private(set) var warnings: [String] = []
    @Published private(set) var preparationNotes: [String] = []
    @Published var error: String?
    @Published private(set) var starlessName: String?
    @Published private(set) var starsName: String?
    @Published var layersAligned = false { didSet { invalidate(scene: true) } }
    @Published var automaticSeparation = false { didSet { invalidate(scene: true) } }
    private let rcAstroHost = "seiza-mac"
    @Published var automaticPreview = true {
        didSet {
            if automaticPreview { scheduleRefit() }
            else { refitSignal?.cancel(); refitRequested = false }
        }
    }
    @Published private(set) var isReconfiguring = false
    @Published private(set) var inputNames: [InputFile: String] = [:]
    @Published var pickingDistance = false
    @Published var codec = NativeVideoExporter.Codec.h264
    @Published var tourOptions = ParallaxTourOptions()
    @Published private(set) var candidate: ParallaxTourPlan?
    @Published private(set) var exportedURL: URL?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var summary: ParallaxSummary?
    let sourceName: String
    private(set) var width = 0
    private(set) var height = 0
    private var files: ParallaxFiles?
    private var starless: URL?
    private var stars: URL?
    private var wcs: WCSResult?
    private var prepared: ParallaxVideo?
    private var sceneVideo: ParallaxVideo?
    // Catalogue labels are loaded lazily on the first overlay reconfiguration.
    // Keep security scopes for as long as any scene/refit needs those files.
    private var sceneResources: [ParallaxScopedURL] = []
    private var selectedInputs: [InputFile: ParallaxScopedURL] = [:]
    private var refitTask: Task<Void, Never>?
    private var refitSignal: ParallaxCancellation?
    private var refitRequested = false
    private var cancellation: ParallaxCancellation?
    private var task: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private var playback: Task<Void, Never>?
    private var revision = 0
    private var frameRevision = 0
    private var framePending: Int?
    private var closed = false
    private var undoStates = [ParallaxComposition]()
    private var redoStates = [ParallaxComposition]()

    convenience init(model: ImageDocumentModel) {
        let wcs: WCSResult?
        if case .solved(let solution) = model.solveState { wcs = solution.wcs } else { wcs = nil }
        self.init(sourceURL: model.url, processing: model.processingConfiguration, wcs: wcs, preview: model.exportImage)
    }

    init(sourceURL: URL, processing: FITSImageProcessingConfiguration, wcs: WCSResult?, preview: CGImage? = nil) {
        sourceName = sourceURL.lastPathComponent
        sourceImage = preview; self.wcs = wcs
        let source = ParallaxScopedURL(sourceURL)
        isBusy = true
        task = Task {
            do {
                let files = try ParallaxFiles()
                self.files = files
                let rendered = try await Task.detached(priority: .userInitiated) {
                    try withExtendedLifetime(source) {
                        let rendered = try SeizaCore.render16(url: source.url, processing: processing)
                        try ImageFileWriter.write(rendered.image, to: files.image, format: .png)
                        return rendered.image
                    }
                }.value
                guard !closed else { return }
                sourceImage = rendered
                width = rendered.width; height = rendered.height
                // Keep a stable scene reference when manually editing a tour.
                composition.scene.distanceFocus = [Double(width - 1) / 2, Double(height - 1) / 2]
                sourceReady = true
                status = "Choose aligned starless and unscreened stars images."
            } catch { self.error = error.localizedDescription; status = "Source snapshot failed." }
            isBusy = false
            activity.finishedAt = .now
        }
    }

    var hasWCS: Bool { wcs != nil }
    var hasPreview: Bool { prepared != nil }
    var hasScene: Bool { sceneVideo != nil }
    var selectedIndex: Int? { composition.stops.firstIndex { $0.id == selectedStop } }
    var canPrepare: Bool { sourceReady && !isBusy && !CatalogSetupController.shared.isRunning && (automaticSeparation ? selectedInputs[.separator] != nil : (starless != nil && stars != nil && layersAligned)) && composition.validationMessage == nil }

    func catalogsDidChange() {
        if isBusy { cancel() }
        invalidate(scene: true)
    }

    func edit(_ body: (inout ParallaxComposition) -> Void) {
        guard !isBusy else { return }
        let previous = composition
        var updated = previous
        body(&updated)
        guard updated != previous else { return }
        undoStates.append(previous)
        if undoStates.count > 100 { undoStates.removeFirst() }
        redoStates.removeAll()
        composition = updated
        invalidate(scene: previous.scene != updated.scene)
        updateHistory()
    }

    func editStop(_ body: (inout ParallaxStop) -> Void) {
        guard let index = selectedIndex else { return }
        edit { body(&$0.stops[index]) }
    }

    func undo() {
        guard !isBusy, let previous = undoStates.popLast() else { return }
        let sceneChanged = previous.scene != composition.scene
        redoStates.append(composition); composition = previous; invalidate(scene: sceneChanged); updateHistory()
    }
    func redo() {
        guard !isBusy, let next = redoStates.popLast() else { return }
        let sceneChanged = next.scene != composition.scene
        undoStates.append(composition); composition = next; invalidate(scene: sceneChanged); updateHistory()
    }
    private func updateHistory() { canUndo = !undoStates.isEmpty; canRedo = !redoStates.isEmpty }

    private func invalidate(scene: Bool = false) {
        revision += 1; frameRevision += 1; framePending = nil
        refitSignal?.cancel(); refitRequested = false
        prepared = nil; summary = nil
        stopPlayback()
        if scene { sceneVideo = nil; sceneResources = []; previewImage = nil }
        playhead = composition.duration.isFinite ? min(playhead, max(0, composition.duration)) : 0
        if sourceReady && !isBusy {
            status = sceneVideo == nil ? "Scene changed. Prepare Preview to apply it." :
                (automaticPreview ? "Camera changed. Refitting preview…" : "Camera changed. Update Preview to apply it.")
        }
        if !scene && automaticPreview { scheduleRefit() }
    }

    enum InputFile: String, CaseIterable {
        case separator = "StarXTerminator executable"
        case objects = "Object catalogue"
        case objectDistances = "Object distances"
        case starDistances = "Star distances"
        case dustMap = "Dust map"
    }
    func chooseInput(_ kind: InputFile) {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose \(kind.rawValue.lowercased())."
        panel.canChooseDirectories = kind == .objects
        if kind == .dustMap {
            panel.message = "Choose a dust map, white where the dust is opaque."
            panel.allowedContentTypes = [.png, .jpeg, .tiff, .fits, .xisf]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if kind == .dustMap { chooseDustMap(ParallaxScopedURL(url)); return }
        if kind == .separator && !FileManager.default.isExecutableFile(atPath: url.path) {
            error = "Choose an executable rc-astro command."; return
        }
        selectedInputs[kind] = ParallaxScopedURL(url); inputNames[kind] = url.lastPathComponent
        invalidate(scene: true)
    }
    func clearInput(_ kind: InputFile) {
        if kind == .dustMap { clearDustMap(); return }
        selectedInputs[kind] = nil; inputNames[kind] = nil; invalidate(scene: true)
    }

    // Dust maps. A prepared scene takes a new map without being prepared
    // again: only its dust changes, and the result becomes the scene that
    // refits and exports start from, so the map stays with them.
    var canReloadDustMap: Bool {
        selectedInputs[.dustMap] != nil && sceneVideo != nil && !isBusy && composition.scene.dust
    }
    var canExportDustMap: Bool { (prepared ?? sceneVideo) != nil && !isBusy }
    var dustDescription: String {
        guard let summary else {
            return selectedInputs[.dustMap] != nil ? "The dust map applies when the scene is prepared." :
                "Dust is counted from the stars when the scene is prepared."
        }
        if summary.dustGiven == true {
            return "Dust from the map: \(summary.starsInFrontOfDust ?? 0) stars seen through opaque dust fly in front of the nebula."
        }
        return composition.scene.dust ? "Dust counted from the stars." : "Dust dimming is off."
    }
    private func chooseDustMap(_ map: ParallaxScopedURL) {
        guard composition.scene.dust else { error = "Turn on dust dimming to use a dust map."; return }
        guard sceneVideo != nil else {
            selectedInputs[.dustMap] = map; inputNames[.dustMap] = map.url.lastPathComponent
            invalidate(scene: true); return
        }
        swapDust(map, message: "Applying the dust map…", select: true)
    }
    private func clearDustMap() {
        // Without a scene, or with the dust off, no prepared scene holds the map.
        guard sceneVideo != nil, composition.scene.dust else {
            selectedInputs[.dustMap] = nil; inputNames[.dustMap] = nil; return
        }
        swapDust(nil, message: "Returning to the dust counted from the stars…", select: true)
    }
    /// Read the chosen map again, after it was edited in another program.
    func reloadDustMap() {
        guard canReloadDustMap, let map = selectedInputs[.dustMap] else { return }
        swapDust(map, message: "Reloading the dust map…", select: false)
    }
    /// Swap `map` (nil for the counted dust) onto the prepared scene, and with
    /// `select` make it the chosen map once it applies.
    private func swapDust(_ map: ParallaxScopedURL?, message: String, select: Bool) {
        // The latest camera, so the preview keeps its framing.
        guard let source = prepared ?? sceneVideo else { return }
        let (signal, generation) = begin(message)
        let events = eventHandler(generation)
        let path = map?.url.path
        task = Task {
            do {
                let video = try await Task.detached(priority: .userInitiated) {
                    try withExtendedLifetime(map) {
                        try ParallaxCore.withDustMap(source, path: path, cancellation: signal, events: events)
                    }
                }.value
                try signal.check()
                guard !closed, generation == revision else { return }
                sceneVideo = video; prepared = video; summary = video.summary
                if select { selectedInputs[.dustMap] = map; inputNames[.dustMap] = map?.url.lastPathComponent }
                status = dustDescription
                finish(signal, error: nil); requestFrame()
            } catch { finish(signal, error: error) }
        }
    }
    func exportDustMap() {
        guard canExportDustMap, let video = prepared ?? sceneVideo else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .tiff, .fits, .xisf]
        panel.nameFieldStringValue = (sourceName as NSString).deletingPathExtension + "-dust.png"
        panel.title = "Export Dust Map"
        panel.message = "White where the dust is opaque: 16-bit PNG or TIFF, or 32-bit FITS or XISF. Paint over it and choose it again."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            do {
                let written = try await Task.detached(priority: .userInitiated) { try video.writeDustMap(to: destination) }.value
                guard !closed else { return }
                status = written ? "Dust map written to \(destination.lastPathComponent)." :
                    "This scene has no dust to export: dust dimming is off, or too few stars show to map it."
            } catch { self.error = error.localizedDescription }
        }
    }
    func pickDistanceReference() { pickingDestination = false; pickingDistance = true; showsSource = true }

    func chooseLayer(starless isStarless: Bool) {
        guard files != nil, !isBusy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .tiff]
        panel.message = isStarless ? "Choose the aligned, stretched starless image." : "Choose the aligned, unscreened stars image."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importLayer(url, starless: isStarless)
    }

    func importLayer(_ url: URL, starless isStarless: Bool) {
        guard let files, !isBusy, !closed else { return }
        refitSignal?.cancel(); refitRequested = false
        isBusy = true
        let width = width, height = height
        task = Task {
            do {
                let imported = try await Task.detached(priority: .userInitiated) {
                    try files.importLayer(url, width: width, height: height)
                }.value
                guard !closed else { return }
                if isStarless { starless = imported; starlessName = url.lastPathComponent }
                else { stars = imported; starsName = url.lastPathComponent }
                layersAligned = false
                invalidate(scene: true)
            } catch { self.error = error.localizedDescription }
            isBusy = false
            status = "Confirm that both layers match the source alignment and stretch."
        }
    }

    func addStop(whole: Bool = false) {
        var stop = ParallaxStop(name: whole ? "Whole Image" : "Custom Point",
            focus: whole ? nil : [Double(width) / 2, Double(height) / 2], dolly: whole ? 0 : 0.4)
        stop.rotateDegrees = selectedIndex.map { composition.stops[$0].rotateDegrees } ?? 0
        let index = selectedIndex.map { $0 + 1 } ?? composition.stops.count
        edit { $0.stops.insert(stop, at: index) }
        selectedStop = stop.id
    }
    func duplicateStop() {
        guard let index = selectedIndex else { return }
        var stop = composition.stops[index]; stop.id = UUID()
        edit { $0.stops.insert(stop, at: index + 1) }; selectedStop = stop.id
    }
    func moveStop(_ offset: Int) {
        guard let index = selectedIndex, composition.stops.indices.contains(index + offset) else { return }
        edit { let stop = $0.stops.remove(at: index); $0.stops.insert(stop, at: index + offset) }
    }
    func removeStop() {
        guard let index = selectedIndex, composition.stops.count > 2 else { return }
        edit { $0.stops.remove(at: index) }
        selectedStop = composition.stops[min(index, composition.stops.count - 1)].id
    }
    func selectStop(_ id: UUID) {
        selectedStop = id
        guard let index = selectedIndex else { return }
        playhead = composition.arrival(at: index)
        requestFrame()
    }
    func pick(x: Double, y: Double) {
        if pickingDistance {
            edit { $0.scene.distanceFocus = [x, y]; $0.distanceName = "Custom point" }
            pickingDistance = false; return
        }
        guard pickingDestination else { return }
        if composition.motion == .tour {
            editStop { $0.focus = [x, y]; $0.name = "Custom Point" }
        } else { edit { $0.focus = [x, y]; $0.focusName = "Custom Point" } }
        pickingDestination = false
    }

    private func request(preview: Bool) throws -> ParallaxRequest {
        guard let files, sourceReady else { throw SeizaCoreError.message("The source snapshot is not ready.") }
        if let message = composition.validationMessage { throw SeizaCoreError.message(message) }
        let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ParallaxDistances", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let inputs = ParallaxInputs(image: files.image.path,
            starless: automaticSeparation ? nil : starless?.path,
            stars: automaticSeparation ? nil : stars?.path,
            wcs: wcs, catalogDirectory: CatalogAccess.resolve()?.path, gaiaCache: cache.path,
            objects: selectedInputs[.objects]?.url.path,
            objectDistances: selectedInputs[.objectDistances]?.url.path,
            starDistances: selectedInputs[.starDistances]?.url.path,
            rcAstroExecutable: selectedInputs[.separator]?.url.path,
            rcAstroHost: rcAstroHost.isEmpty ? nil : rcAstroHost,
            // The core refuses a dust map with the dust off.
            dustMap: composition.scene.dust ? selectedInputs[.dustMap]?.url.path : nil)
        return ParallaxRequest(inputs: inputs, scene: composition.scene, video: composition.videoSettings(preview: preview))
    }

    private func resources() -> [ParallaxScopedURL] {
        Array(selectedInputs.values) + [CatalogAccess.resolve().map(ParallaxScopedURL.init)].compactMap { $0 }
    }

    private func begin(_ message: String) -> (ParallaxCancellation, Int) {
        stopPlayback()
        refitSignal?.cancel(); refitRequested = false
        revision += 1
        isBusy = true; status = message; progress = nil; warnings = []; preparationNotes = []; error = nil
        activity = ParallaxActivity(message: message)
        let signal = ParallaxCancellation(); cancellation = signal
        return (signal, revision)
    }
    private func eventHandler(_ generation: Int) -> (ParallaxEvent) -> Void {
        { [weak self] event in
            Task { @MainActor in
                guard let self, !self.closed, (self.isBusy || self.isReconfiguring), self.revision == generation else { return }
                self.activity.receive(event)
                if event.message != nil { self.progress = nil }
                if event.kind == "warning", let message = event.message {
                    if !self.warnings.contains(message) { self.warnings.append(message) }
                } else if event.kind == "split", let fraction = event.fraction {
                    self.progress = fraction
                } else if let message = event.message {
                    self.preparationNotes.append(message)
                    if self.preparationNotes.count > 100 { self.preparationNotes.removeFirst() }
                    if self.cancellation?.isCancelled != true && self.refitSignal?.isCancelled != true { self.status = message }
                }
            }
        }
    }
    private func finish(_ signal: ParallaxCancellation, error: Error?) {
        guard !closed else { return }
        isBusy = false; cancellation = nil; progress = nil
        activity.finishedAt = .now
        if signal.isCancelled || error is CancellationError { status = "Cancelled." }
        else if let error { self.error = error.localizedDescription; status = "Could not complete the operation." }
        activity.receive(ParallaxEvent(kind: error == nil ? "note" : "warning", message: error?.localizedDescription ?? status, fraction: nil))
    }

    func generateTour() {
        guard sourceReady, !isBusy, !CatalogSetupController.shared.isRunning else { return }
        guard tourOptions.hold.isFinite, tourOptions.hold >= 0,
              tourOptions.motion.isFinite, tourOptions.motion >= 0 else {
            error = "Tour hold and motion must be finite, nonnegative numbers."; return
        }
        do {
            var request = try request(preview: false)
            request.autoTour = tourOptions
            request.video.tour = []
            let files = files!
            let access = resources()
            let allowStarsFallback = layersAligned
            let (signal, generation) = begin(hasWCS ? "Planning tour…" : "Solving image and planning tour…")
            let events = eventHandler(generation)
            task = Task {
                do {
                    let result = try await Task.detached(priority: .userInitiated) { () -> (ParallaxTourPlan, WCSResult?) in
                        try withExtendedLifetime((files, access)) {
                            let request = try ParallaxCore.resolvingWCS(request, allowStarsFallback: allowStarsFallback,
                                cancellation: signal, events: events)
                            try signal.check()
                            return (try ParallaxCore.plan(request, cancellation: signal, events: events), request.inputs.wcs)
                        }
                    }.value
                    try signal.check()
                    guard !closed, generation == revision else { return }
                    wcs = result.1; candidate = result.0
                    status = "Generated \(result.0.tour.count) stops. Apply the tour or keep your draft."
                    finish(signal, error: nil)
                } catch { finish(signal, error: error) }
            }
        } catch { self.error = error.localizedDescription }
    }

    func applyCandidate() {
        guard let plan = candidate else { return }
        edit {
            $0.motion = .tour; $0.stops = plan.tour
            $0.scene.distanceFocus = plan.focus; $0.distanceName = plan.focusName
            if let glide = plan.tourGlide { $0.tourGlide = glide }
            if let titles = plan.tourTitles { $0.tourTitles = titles }
            if let loop = plan.tourLoop { $0.tourLoop = loop }
        }
        selectedStop = plan.tour.first?.id; candidate = nil
    }
    func discardCandidate() { candidate = nil }

    func preparePreview() {
        guard canPrepare else { return }
        if sceneVideo != nil { scheduleRefit(force: true); return }
        do {
            let request = try request(preview: true), files = files!
            let access = resources()
            let (signal, generation) = begin(hasWCS ? "Loading images and finding stars…" : "Loading images, solving sky coordinates and finding stars…")
            let events = eventHandler(generation)
            task = Task {
                do {
                    let video = try await Task.detached(priority: .userInitiated) {
                        try withExtendedLifetime((files, access)) {
                            try ParallaxCore.prepare(request, cancellation: signal, events: events)
                        }
                    }.value
                    try signal.check()
                    guard !closed, generation == revision else { return }
                    sceneVideo = video; sceneResources = access
                    prepared = video; summary = video.summary; wcs = video.summary.wcs
                    status = "Preview ready. \(video.summary.withDistance) of \(video.summary.detectedStars) stars have catalog distances."
                    showsSource = false
                    finish(signal, error: nil); requestFrame()
                } catch { finish(signal, error: error) }
            }
        } catch { self.error = error.localizedDescription }
    }

    func requestFrame() {
        guard let video = prepared, !closed else { return }
        frameRevision += 1
        framePending = min(video.summary.frames - 1, max(0, Int(playhead * Double(video.summary.fps))))
        guard frameTask == nil else { return }
        frameTask = Task {
            while let index = framePending, let video = prepared, !closed {
                framePending = nil
                let revision = frameRevision
                do {
                    let image = try await Task.detached(priority: .userInitiated) { try video.frame(index) }.value
                    if revision == frameRevision { previewImage = image }
                } catch {
                    if revision == frameRevision { self.error = error.localizedDescription; stopPlayback() }
                    break
                }
            }
            frameTask = nil
        }
    }

    // One native refit at a time, with cancellation and a debounce between
    // edits. A late result can never replace a newer draft or scene.
    private func scheduleRefit(force: Bool = false) {
        guard sceneVideo != nil, !closed, !isBusy, automaticPreview || force else { return }
        refitRequested = true; refitSignal?.cancel()
        guard refitTask == nil else { return }
        isReconfiguring = true
        activity = ParallaxActivity(message: "Fitting camera to the prepared scene…")
        refitTask = Task {
            while refitRequested, !closed, !isBusy, sceneVideo != nil {
                try? await Task.sleep(for: .milliseconds(300))
                guard refitRequested, !closed, !isBusy, let scene = sceneVideo else { break }
                refitRequested = false
                if let message = composition.validationMessage { status = message; continue }
                let settings = composition.videoSettings(preview: true)
                let access = sceneResources
                let signal = ParallaxCancellation(); refitSignal = signal
                let generation = revision, events = eventHandler(revision)
                do {
                    let video = try await Task.detached(priority: .userInitiated) {
                        try withExtendedLifetime(access) {
                            try ParallaxCore.reconfigure(scene, settings: settings, cancellation: signal, events: events)
                        }
                    }.value
                    try signal.check()
                    guard !closed, !isBusy, generation == revision else { continue }
                    prepared = video; summary = video.summary
                    status = "Preview updated using the prepared scene."
                    requestFrame()
                } catch {
                    if !closed, generation == revision, !signal.isCancelled {
                        self.error = error.localizedDescription; status = "Could not refit preview."
                    }
                }
            }
            refitSignal = nil; refitTask = nil; isReconfiguring = false
            if !isBusy { activity.finishedAt = .now }
        }
    }

    func saveTour() {
        guard composition.validationMessage == nil else { error = composition.validationMessage; return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Tour.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let plan = ParallaxTourPlan(focus: composition.scene.distanceFocus ?? [Double(width - 1) / 2, Double(height - 1) / 2],
                focusName: composition.distanceName, seconds: composition.duration, tour: composition.stops,
                tourGlide: composition.tourGlide, tourTitles: composition.tourTitles, tourLoop: composition.tourLoop)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let access = ParallaxScopedURL(url)
            try withExtendedLifetime(access) { try encoder.encode(plan).write(to: url, options: .atomic) }
        } catch { self.error = error.localizedDescription }
    }

    func loadTour() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let access = ParallaxScopedURL(url)
            let plan = try withExtendedLifetime(access) { try JSONDecoder().decode(ParallaxTourPlan.self, from: Data(contentsOf: url)) }
            guard plan.schemaVersion == 1 else { throw SeizaCoreError.message("Unsupported tour schema.") }
            var draft = composition; draft.motion = .tour; draft.stops = plan.tour; draft.scene.distanceFocus = plan.focus
            if let glide = plan.tourGlide { draft.tourGlide = glide }
            if let titles = plan.tourTitles { draft.tourTitles = titles }
            if let loop = plan.tourLoop { draft.tourLoop = loop }
            if let message = draft.validationMessage { throw SeizaCoreError.message(message) }
            candidate = plan; status = "Tour loaded. Apply it to replace the current draft."
        } catch { self.error = error.localizedDescription }
    }

    func togglePlayback() {
        if isPlaying { stopPlayback(); return }
        guard prepared != nil else { return }
        if playhead >= composition.duration { playhead = 0 }
        showsSource = false; isPlaying = true
        playback = Task {
            let start = Date().timeIntervalSinceReferenceDate - playhead
            while !Task.isCancelled, isPlaying, prepared != nil, !closed {
                // Do not starve the latest-frame publication on slower CPUs.
                if frameTask == nil {
                    let elapsed = Date().timeIntervalSinceReferenceDate - start
                    let loops = composition.motion == .tour && composition.tourLoop
                    playhead = loops ? elapsed.truncatingRemainder(dividingBy: composition.duration) : min(composition.duration, elapsed)
                    requestFrame()
                    if playhead >= composition.duration { break }
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
            isPlaying = false
        }
    }
    func stopPlayback() { isPlaying = false; playback?.cancel(); playback = nil }

    func exportVideo() {
        guard canPrepare else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = (sourceName as NSString).deletingPathExtension + "-parallax.mp4"
        panel.title = "Export Parallax Video"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let request = try request(preview: false), files = files!, codec = codec
            let existing = sceneVideo
            let retainedAccess = existing == nil ? resources() : sceneResources
            let (signal, generation) = begin(existing == nil ? "Preparing full-resolution video…" : "Fitting full-resolution video…")
            let events = eventHandler(generation)
            task = Task {
                do {
                    let video = try await Task.detached(priority: .userInitiated) {
                        try withExtendedLifetime((files, retainedAccess)) {
                            if let existing {
                                return try ParallaxCore.reconfigure(existing, settings: request.video, cancellation: signal, events: events)
                            }
                            return try ParallaxCore.prepare(request, cancellation: signal, events: events)
                        }
                    }.value
                    try signal.check()
                    guard !closed else { return }
                    sceneVideo = video; sceneResources = retainedAccess
                    wcs = video.summary.wcs; summary = video.summary
                    status = "Encoding video…"
                    activity.networkPhase = nil
                    activity.receive(ParallaxEvent(kind: "note", message: status, fraction: nil))
                    try await NativeVideoExporter.write(to: destination, width: video.summary.width,
                        height: video.summary.height, fps: video.summary.fps, frames: video.summary.frames,
                        codec: codec, cancellation: signal, render: { try video.render($0, into: $1) },
                        progress: { [weak self = self] done, total in
                            Task { @MainActor in
                                guard let self, !self.closed, self.isBusy, self.cancellation != nil,
                                    !signal.isCancelled, self.revision == generation else { return }
                                self.progress = Double(done) / Double(total)
                                self.status = done == total ? "Finalizing video…" : "Encoding frame \(done) of \(total)…"
                            }
                        })
                    exportedURL = destination; status = "Video exported."
                    finish(signal, error: nil)
                } catch { finish(signal, error: error) }
            }
        } catch { self.error = error.localizedDescription }
    }

    func cancel() {
        cancellation?.cancel(); refitSignal?.cancel(); refitRequested = false
        activity.cancellationRequested = true
        status = isBusy ? "Stopping after the current native step…" : "Preview update cancelled."
    }
    func close() {
        closed = true; cancellation?.cancel(); refitSignal?.cancel(); refitRequested = false
        stopPlayback(); frameRevision += 1; framePending = nil
        prepared = nil; sceneVideo = nil; sceneResources = []
        // Native calls retain files, callbacks and handles until they return.
    }
}
