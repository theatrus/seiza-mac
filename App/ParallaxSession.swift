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
    @Published var layersAligned = true { didSet { invalidate(scene: true) } }
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
    /// Whether the candidate was planned on the prepared scene, whose
    /// distance it keeps.
    private var candidateOnScene = false
    private var candidateFrame: String?
    @Published private(set) var exportedURL: URL?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var summary: ParallaxSummary?
    /// The depth planes of the last scene prepared. They stay listed after a
    /// scene edit, so distances can be given for several before preparing.
    @Published private(set) var planes: [ParallaxPlane]?
    let sourceName: String
    private(set) var width = 0
    private(set) var height = 0
    private var files: ParallaxFiles?
    private var starless: URL?
    private var stars: URL?
    private var sourceIsStarless = false
    private var wcs: WCSResult?
    private let originalSource: ParallaxScopedURL
    private weak var document: ImageDocumentModel?
    private var prepared: ParallaxVideo?
    private var sceneVideo: ParallaxVideo?
    // Catalogue labels are loaded lazily on the first overlay reconfiguration.
    // Keep security scopes for as long as any scene/refit needs those files.
    private var sceneResources: [ParallaxScopedURL] = []
    private var selectedInputs: [InputFile: ParallaxScopedURL] = [:]
    // Retain previous selections too: undo may restore a removed/replaced mask.
    // Native tasks capture these scopes before leaving the main actor.
    private var maskFiles: [String: ParallaxScopedURL] = [:]
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
        document = model
    }

    init(sourceURL: URL, processing: FITSImageProcessingConfiguration, wcs: WCSResult?, preview: CGImage? = nil) {
        sourceName = sourceURL.lastPathComponent
        sourceImage = preview; self.wcs = wcs
        let source = ParallaxScopedURL(sourceURL)
        originalSource = source
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
                composition.sourceWidth = width; composition.sourceHeight = height
                // Keep a stable scene reference when manually editing a tour.
                composition.scene.distanceFocus = composition.imageCenter
                sourceReady = true
                status = "Choose aligned starless and unscreened stars images."
            } catch { self.error = error.localizedDescription; status = "Source snapshot failed." }
            isBusy = false
            activity.finishedAt = .now
        }
    }

    var hasWCS: Bool {
        if let document, case .solved = document.solveState { return true }
        return wcs != nil
    }
    var solvingDescription: String {
        if hasWCS { return "Sky coordinates available" }
        if sourceIsStarless {
            return tourSolveIssue ?? "The source is starless. The aligned stars layer will be plate solved directly; the starless image will not be solved."
        }
        return "The original file is solved first using its astrometric headers, followed by the snapshot and an aligned stars layer when needed."
    }
    var hasPreview: Bool { prepared != nil }
    var hasScene: Bool { sceneVideo != nil }
    var selectedIndex: Int? { composition.stops.firstIndex { $0.id == selectedStop } }
    var preparationIssue: String? {
        guard sourceReady else { return "Wait for the source snapshot to finish loading." }
        guard !CatalogSetupController.shared.isRunning else { return "Wait for catalogue setup to finish." }
        if automaticSeparation {
            guard selectedInputs[.separator] != nil else { return "Choose the StarXTerminator executable in Source." }
        } else {
            guard starless != nil, stars != nil else { return "Choose both Starless and Stars images in Source." }
            guard layersAligned else { return "Enable Layers match source alignment and stretch in Source to prepare the selected pair." }
        }
        return composition.validationMessage
    }
    var canPrepare: Bool { !isBusy && preparationIssue == nil }
    var tourSolveIssue: String? {
        guard !hasWCS, sourceIsStarless else { return nil }
        guard stars != nil else { return "The opened image is starless. Choose an aligned Stars image in Source before solving." }
        guard layersAligned else { return "The opened image is starless. Enable Layers match source alignment and stretch to solve the selected stars layer." }
        return nil
    }

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

    func editStopFraming(_ body: (inout ParallaxStop) -> Void) {
        editStop { stop in
            body(&stop)
            stop.pullBackToWholeImage = true
        }
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
        if candidateOnScene && (scene || candidateFrame != composition.frameKey) { discardCandidate() }
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

    /// Images laid over the video: a logo with the credit, opening and closing
    /// title cards, and a stop's card. Each chosen file stays readable for
    /// the rest of the session, so undo can bring it back.
    enum OverlayImage: Equatable { case logo, intro, outro, stop(UUID) }
    private var overlayFiles: [String: ParallaxScopedURL] = [:]

    func chooseOverlayImage(_ slot: OverlayImage) {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.message = slot == .logo
            ? "Choose a logo, a PNG or TIFF with transparency."
            : "Choose a title card, a PNG or TIFF with transparency, the size of the video's frame for sharp lettering."
        panel.allowedContentTypes = [.png, .tiff]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        overlayFiles[url.path] = ParallaxScopedURL(url)
        setOverlayImage(url.path, for: slot)
    }
    func clearOverlayImage(_ slot: OverlayImage) { setOverlayImage(nil, for: slot) }
    private func setOverlayImage(_ path: String?, for slot: OverlayImage) {
        edit { composition in
            switch slot {
            case .logo: composition.logoPath = path
            case .intro: composition.introCard = path
            case .outro: composition.outroCard = path
            case .stop(let id):
                if let index = composition.stops.firstIndex(where: { $0.id == id }) { composition.stops[index].card = path }
            }
        }
    }

    // Dust maps. A prepared scene takes a new map without being prepared
    // again: only its dust changes, and the result becomes the scene that
    // refits and exports start from, so the map stays with them.
    var canReloadDustMap: Bool {
        selectedInputs[.dustMap] != nil && sceneVideo != nil && !isBusy && composition.scene.dust
    }
    var canExportDustMap: Bool { (prepared ?? sceneVideo) != nil && !isBusy }
    var dustDescription: String {
        guard composition.scene.dust else { return "Dust dimming is off." }
        guard let summary else {
            return selectedInputs[.dustMap] != nil ? "The dust map applies when the scene is prepared." :
                "Dust is counted from the stars when the scene is prepared."
        }
        if summary.dustGiven == true {
            return "Dust from the map: \(summary.starsInFrontOfDust ?? 0) stars seen through opaque dust fly in front of the nebula."
        }
        return "Dust counted from the stars."
    }
    func chooseDustMap(_ map: ParallaxScopedURL) {
        guard !closed, !isBusy else { return }
        guard composition.scene.dust else { error = "Turn on dust dimming to use a dust map."; return }
        guard sceneVideo != nil else {
            selectedInputs[.dustMap] = map; inputNames[.dustMap] = map.url.lastPathComponent
            invalidate(scene: true); return
        }
        swapDust(map, message: "Applying the dust map…", select: true)
    }
    private func clearDustMap() {
        guard !closed, !isBusy else { return }
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
        guard let source = prepared ?? sceneVideo else { return }
        if let message = composition.validationMessage { error = message; return }
        // Camera edits clear `prepared` before their refit finishes (or while
        // automatic preview is off). Refit the new dust to that current draft,
        // rather than publishing the older camera held by `sceneVideo`.
        let settings = prepared == nil ? composition.videoSettings(preview: true) : nil
        let access = sceneResources
        let (signal, generation) = begin(message)
        let events = eventHandler(generation)
        let path = map?.url.path
        let crop = composition.scene.crop, sourceWidth = width, sourceHeight = height, files = files
        task = Task {
            do {
                let video = try await Task.detached(priority: .userInitiated) {
                    try withExtendedLifetime((map, access, files)) {
                        var mappedPath = path
                        if let crop, let path, let files {
                            let cropped = files.directory.appendingPathComponent(UUID().uuidString + ".fits")
                            try ParallaxCore.transformDustMap(path: path, to: cropped,
                                sourceWidth: sourceWidth, sourceHeight: sourceHeight, crop: crop, expand: false)
                            mappedPath = cropped.path
                        }
                        try signal.check()
                        let painted = try ParallaxCore.withDustMap(source, path: mappedPath, cancellation: signal, events: events)
                        if let settings {
                            return try ParallaxCore.reconfigure(painted, settings: settings, cancellation: signal, events: events)
                        }
                        return painted
                    }
                }.value
                try signal.check()
                guard !closed, generation == revision else { return }
                if candidateOnScene { discardCandidate() }
                sceneVideo = video; prepared = video; summary = video.summary; planes = video.summary.planes
                if select { selectedInputs[.dustMap] = map; inputNames[.dustMap] = map?.url.lastPathComponent }
                status = dustDescription
                finish(signal, error: nil); requestFrame()
            } catch { finish(signal, error: error) }
        }
    }
    func exportDustMap() {
        guard canExportDustMap else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .tiff, .fits, .xisf]
        panel.nameFieldStringValue = (sourceName as NSString).deletingPathExtension + "-dust.png"
        panel.title = "Export Dust Map"
        panel.message = "White where the dust is opaque: 16-bit PNG or TIFF, or 32-bit FITS or XISF. Paint over it and choose it again."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exportDustMap(to: destination)
    }
    func exportDustMap(to destination: URL) {
        guard !closed, canExportDustMap, let video = prepared ?? sceneVideo else { return }
        let access = ParallaxScopedURL(destination)
        let crop = composition.scene.crop, sourceWidth = width, sourceHeight = height
        let files = files, baseMap = selectedInputs[.dustMap]
        let (signal, generation) = begin("Writing dust map…")
        task = Task {
            do {
                let written = try await Task.detached(priority: .userInitiated) {
                    try withExtendedLifetime((access, files, baseMap)) {
                        try signal.check()
                        if let crop, let files {
                            let cropped = files.directory.appendingPathComponent(UUID().uuidString + ".fits")
                            guard try video.writeDustMap(to: cropped) else { return false }
                            try signal.check()
                            try ParallaxCore.transformDustMap(path: cropped.path, to: access.url,
                                sourceWidth: sourceWidth, sourceHeight: sourceHeight, crop: crop,
                                expand: true, base: baseMap?.url.path)
                            return true
                        }
                        return try video.writeDustMap(to: access.url)
                    }
                }.value
                try signal.check()
                guard !closed, generation == revision else { return }
                status = written ? "Dust map written to \(destination.lastPathComponent)." :
                    "This scene has no dust to export: dust dimming is off, or too few stars show to map it."
                finish(signal, error: nil)
                if prepared == nil { scheduleRefit() }
            } catch { finish(signal, error: error) }
        }
    }
    // Depth planes. Their distances are scene settings: a distance given for
    // a plane's catalogued object needs the scene prepared again.
    var planesAreCurrent: Bool { sceneVideo != nil }
    var planesDescription: String? {
        guard composition.scene.autoPlanes else { return nil }
        let found = planes?.isEmpty == false
        if planesAreCurrent { return found ? nil : "No catalogued nebula or dust cloud lies at a distance of its own." }
        return found ? "From the last preparation. Prepare the scene again to apply changes." :
            "Depth planes are found when the scene is prepared."
    }
    /// The planes to list: none while automatic planes are off.
    var listedPlanes: [ParallaxPlane] { composition.scene.autoPlanes ? planes ?? [] : [] }
    /// Distances given for objects that place no listed plane, so they can
    /// still be removed.
    var unlistedDistances: [ParallaxDistanceOverride] {
        let listed = Set(listedPlanes.compactMap(\.object))
        return composition.scene.distanceOverrides.filter { !listed.contains($0.object) }
    }
    func setDistance(_ parsecs: Double, for object: String) { edit { $0.scene.setDistance(parsecs, for: object) } }
    func clearDistance(for object: String) { edit { $0.scene.clearDistance(for: object) } }

    @discardableResult
    func addDistanceOverride(object: String, parsecs: Double) -> Bool {
        guard !closed, !isBusy else { return false }
        guard !object.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              parsecs.isFinite, parsecs > 0 else {
            error = "Enter a catalogue object name and a positive, finite distance in parsecs."
            return false
        }
        error = nil
        setDistance(parsecs, for: object)
        return true
    }

    func choosePlaneMask(replacing id: UUID? = nil) {
        guard sourceReady, !closed, !isBusy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .fits, .xisf]
        panel.message = "Choose a mask: white lifts a region onto this plane, black leaves it behind. Use the source image's aspect ratio; floating-point samples must be between 0 and 1."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectPlaneMask(ParallaxScopedURL(url), replacing: id)
    }
    func selectPlaneMask(_ access: ParallaxScopedURL, replacing id: UUID? = nil) {
        guard sourceReady, !closed, !isBusy else { return }
        if let id, !composition.scene.planes.contains(where: { $0.id == id }) { return }
        maskFiles[access.url.path] = access
        let previous = composition
        let distance = summary?.backgroundDistanceParsecs ?? composition.scene.distanceParsecs ?? 1000
        edit { draft in
            if let id, let index = draft.scene.planes.firstIndex(where: { $0.id == id }) {
                draft.scene.planes[index].mask = access.url.path
            } else {
                draft.scene.planes.append(ParallaxMaskPlane(mask: access.url.path, distanceParsecs: distance,
                    name: access.url.deletingPathExtension().lastPathComponent))
            }
        }
        // Choosing the same path again also reloads an externally edited mask.
        if composition == previous { invalidate(scene: true) }
    }
    func editPlane(_ id: UUID, _ body: (inout ParallaxMaskPlane) -> Void) {
        edit { draft in
            if let index = draft.scene.planes.firstIndex(where: { $0.id == id }) { body(&draft.scene.planes[index]) }
        }
    }
    func removePlane(_ id: UUID) { edit { $0.scene.planes.removeAll { $0.id == id } } }
    func reloadPlane(_ id: UUID) {
        guard !closed, !isBusy, composition.scene.planes.contains(where: { $0.id == id }) else { return }
        invalidate(scene: true)
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
                if isStarless {
                    starless = imported; starlessName = url.lastPathComponent
                    // The source itself is immutable; replacing a layer cannot
                    // make a previously identified starless source solvable.
                    sourceIsStarless = sourceIsStarless || url.standardizedFileURL == originalSource.url.standardizedFileURL
                }
                else { stars = imported; starsName = url.lastPathComponent }
                invalidate(scene: true)
            } catch { self.error = error.localizedDescription }
            isBusy = false
            status = preparationIssue ?? "Layers ready. Prepare Preview or generate a tour."
        }
    }

    func addStop(whole: Bool = false) {
        var stop = ParallaxStop(name: whole ? "Whole Image" : "Custom Point",
            focus: whole ? nil : composition.imageCenter, dolly: 0)
        if !whole { stop.pullBackToWholeImage = true }
        stop.rotateDegrees = selectedIndex.map { composition.stops[$0].rotateDegrees } ?? 0
        let index = selectedIndex.map { $0 + 1 } ?? composition.stops.count
        edit { $0.stops.insert(stop, at: index) }
        selectStop(stop.id)
    }
    func duplicateStop() {
        guard let index = selectedIndex else { return }
        var stop = composition.stops[index]; stop.id = UUID()
        edit { $0.stops.insert(stop, at: index + 1) }; selectStop(stop.id)
    }
    func moveStop(_ offset: Int) {
        guard let index = selectedIndex, composition.stops.indices.contains(index + offset) else { return }
        edit { let stop = $0.stops.remove(at: index); $0.stops.insert(stop, at: index + offset) }
        if let selectedStop { selectStop(selectedStop) }
    }
    func removeStop() {
        guard let index = selectedIndex, composition.stops.count > 2 else { return }
        edit { $0.stops.remove(at: index) }
        selectStop(composition.stops[min(index, composition.stops.count - 1)].id)
    }
    func pullBack() {
        editStopFraming { $0.dolly = 0; $0.zoom = 1; $0.pan = 0; $0.push = 0 }
        if let selectedStop { selectStop(selectedStop) }
    }
    func selectStop(_ id: UUID) {
        selectedStop = id
        guard let index = selectedIndex else { return }
        playhead = composition.arrival(at: index)
        requestFrame()
    }
    func pick(x: Double, y: Double) {
        guard composition.filmedBounds.contains(CGPoint(x: x, y: y)) else { return }
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
        return ParallaxRequest(inputs: inputs, scene: composition.sceneSettings(), video: composition.videoSettings(preview: preview))
    }

    private func resources() -> [ParallaxScopedURL] {
        [originalSource] + Array(selectedInputs.values) + Array(maskFiles.values) + [CatalogAccess.resolve().map(ParallaxScopedURL.init)].compactMap { $0 }
    }

    private func synchronizeDocumentSolution() {
        guard let document, case .solved(let solution) = document.solveState, solution.wcs != wcs else { return }
        wcs = solution.wcs
        invalidate(scene: true)
    }

    private func solutionHandler(_ generation: Int, cancellation: ParallaxCancellation) -> (SolveResult) -> Void {
        { [weak self] solution in
            Task { @MainActor in
                guard let self, !self.closed, self.revision == generation,
                      !cancellation.isCancelled else { return }
                self.wcs = solution.wcs
                self.document?.adoptParallaxSolution(solution)
            }
        }
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
        guard !closed, sourceReady, !isBusy, !CatalogSetupController.shared.isRunning else { return }
        synchronizeDocumentSolution()
        if let issue = tourSolveIssue { error = issue; return }
        guard tourOptions.hold.isFinite, tourOptions.hold >= 0,
              tourOptions.motion.isFinite, tourOptions.motion >= 0 else {
            error = "Tour hold and motion must be finite, nonnegative numbers."; return
        }
        // With a prepared scene, plan on it: stops on depth planes are framed
        // at their planes' depths, as an automatic tour of the scene would be.
        if let scene = sceneVideo {
            let size = composition.outputSize
            let settings = ParallaxScenePlanSettings(size: "\(size.width)x\(size.height)", framing: composition.framing, autoTour: tourOptions)
            let frameKey = composition.frameKey, crop = composition.scene.crop
            let access = sceneResources, files = files
            let (signal, generation) = begin("Planning tour on the prepared scene…")
            task = Task {
                do {
                    var plan = try await Task.detached(priority: .userInitiated) {
                        try withExtendedLifetime((files, access)) {
                            try ParallaxCore.planOnScene(scene, settings: settings, cancellation: signal)
                        }
                    }.value
                    try signal.check()
                    guard !closed, generation == revision else { return }
                    plan.crop = crop
                    candidate = plan; candidateOnScene = true; candidateFrame = frameKey
                    status = "Generated \(plan.tour.count) stops on the prepared scene. Apply the tour or keep your draft."
                    finish(signal, error: nil)
                } catch { finish(signal, error: error) }
            }
            return
        }
        do {
            var request = try request(preview: false)
            request.autoTour = tourOptions
            request.video.tour = []
            let files = files!
            let access = resources()
            let allowStarsFallback = layersAligned, sourceIsStarless = sourceIsStarless
            let (signal, generation) = begin(hasWCS ? "Planning tour…" : "Solving image and planning tour…")
            let events = eventHandler(generation)
            let originalURL = originalSource.url, didSolve = solutionHandler(generation, cancellation: signal)
            task = Task {
                do {
                    let result = try await Task.detached(priority: .userInitiated) { () -> (ParallaxTourPlan, WCSResult?) in
                        try withExtendedLifetime((files, access)) {
                            let request = try ParallaxCore.resolvingWCS(request, allowStarsFallback: allowStarsFallback,
                                originalURL: originalURL, sourceIsStarless: sourceIsStarless, didSolve: didSolve,
                                cancellation: signal, events: events)
                            try signal.check()
                            var plan = try ParallaxCore.plan(request, cancellation: signal, events: events)
                            plan.crop = request.scene.crop
                            return (plan, request.inputs.wcs)
                        }
                    }.value
                    try signal.check()
                    guard !closed, generation == revision else { return }
                    wcs = result.1; candidate = result.0; candidateOnScene = false; candidateFrame = nil
                    status = "Generated \(result.0.tour.count) stops. Apply the tour or keep your draft."
                    finish(signal, error: nil)
                } catch { finish(signal, error: error) }
            }
        } catch { self.error = error.localizedDescription }
    }

    func applyCandidate() {
        guard !closed, !isBusy, let plan = candidate else { return }
        // A plan made on the prepared scene keeps the scene's distance; taking
        // the plan's focus would prepare the scene again.
        let onScene = candidateOnScene
        edit { $0.applyTour(plan, onScene: onScene) }
        selectedStop = plan.tour.first?.id; discardCandidate()
    }
    func discardCandidate() { candidate = nil; candidateOnScene = false; candidateFrame = nil }

    func preparePreview() {
        guard canPrepare else { return }
        synchronizeDocumentSolution()
        if sceneVideo != nil { scheduleRefit(force: true); return }
        do {
            let request = try request(preview: true), files = files!
            let access = resources()
            let (signal, generation) = begin(hasWCS ? "Loading images and finding stars…" : "Loading images, solving sky coordinates and finding stars…")
            let events = eventHandler(generation)
            let originalURL = originalSource.url, didSolve = solutionHandler(generation, cancellation: signal)
            let sourceIsStarless = sourceIsStarless
            task = Task {
                do {
                    let video = try await Task.detached(priority: .userInitiated) {
                        try withExtendedLifetime((files, access)) {
                            try ParallaxCore.prepare(request, originalURL: originalURL, sourceIsStarless: sourceIsStarless, didSolve: didSolve,
                                cancellation: signal, events: events)
                        }
                    }.value
                    try signal.check()
                    guard !closed, generation == revision else { return }
                    sceneVideo = video; sceneResources = access
                    prepared = video; summary = video.summary; wcs = video.summary.wcs; planes = video.summary.planes
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
            var stops = composition.stops
            for index in stops.indices { stops[index].focus = stops[index].focus.map(composition.videoPoint) }
            let plan = ParallaxTourPlan(focus: composition.videoPoint(composition.scene.distanceFocus ?? composition.imageCenter),
                focusName: composition.distanceName, seconds: composition.duration, tour: stops,
                tourGlide: composition.tourGlide, tourTitles: composition.tourTitles, tourLoop: composition.tourLoop,
                crop: composition.scene.crop)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let access = ParallaxScopedURL(url)
            try withExtendedLifetime(access) { try encoder.encode(plan).write(to: url, options: .atomic) }
        } catch { self.error = error.localizedDescription }
    }

    func loadTour() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadTour(from: url)
    }

    func loadTour(from url: URL) {
        guard !closed, !isBusy else { return }
        do {
            let access = ParallaxScopedURL(url)
            let plan = try withExtendedLifetime(access) { try JSONDecoder().decode(ParallaxTourPlan.self, from: Data(contentsOf: url)) }
            guard plan.schemaVersion == 1 else { throw SeizaCoreError.message("Unsupported tour schema.") }
            var draft = composition; draft.applyTour(plan, onScene: false)
            if let message = draft.validationMessage { throw SeizaCoreError.message(message) }
            candidate = plan; candidateOnScene = false; candidateFrame = nil; status = "Tour loaded. Apply it to replace the current draft."
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
        synchronizeDocumentSolution()
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
            let originalURL = originalSource.url, didSolve = solutionHandler(generation, cancellation: signal)
            let sourceIsStarless = sourceIsStarless
            task = Task {
                do {
                    let video = try await Task.detached(priority: .userInitiated) {
                        try withExtendedLifetime((files, retainedAccess)) {
                            if let existing {
                                return try ParallaxCore.reconfigure(existing, settings: request.video, cancellation: signal, events: events)
                            }
                            return try ParallaxCore.prepare(request, originalURL: originalURL, sourceIsStarless: sourceIsStarless, didSolve: didSolve,
                                cancellation: signal, events: events)
                        }
                    }.value
                    try signal.check()
                    guard !closed else { return }
                    sceneVideo = video; sceneResources = retainedAccess
                    wcs = video.summary.wcs; summary = video.summary; planes = video.summary.planes
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
        discardCandidate()
        stopPlayback(); frameRevision += 1; framePending = nil
        prepared = nil; sceneVideo = nil; sceneResources = []
        // Native calls retain files, callbacks and handles until they return.
    }
}
