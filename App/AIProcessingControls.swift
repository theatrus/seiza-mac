import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Uses the same versioned interchange format as the Windows Processing panel.
struct ProcessingRecipe: Codable {
    let schema: String
    let version: Int
    let processing: FITSImageProcessingConfiguration

    init(_ processing: FITSImageProcessingConfiguration) {
        schema = "org.seiza.image-processing"
        version = 1
        self.processing = processing
    }

    static func decode(_ data: Data) throws -> FITSImageProcessingConfiguration {
        guard data.count <= 1_048_576 else { throw SeizaCoreError.message("The processing recipe is too large.") }
        let decoder = JSONDecoder()
        let result: FITSImageProcessingConfiguration
        if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["schema"] != nil {
            let recipe = try decoder.decode(Self.self, from: data)
            guard recipe.schema == "org.seiza.image-processing", recipe.version == 1 else {
                throw SeizaCoreError.message("This processing recipe version is unsupported.")
            }
            result = recipe.processing
        } else {
            result = try decoder.decode(FITSImageProcessingConfiguration.self, from: data)
        }
        return .init(stretchStack: result.stretchStack, backgroundConfiguration: result.backgroundConfiguration,
                     deconvolution: result.deconvolution, ai: result.ai)
    }

    static func url(for source: URL) -> URL { source.appendingPathExtension("seiza.json") }

    // A single Finder document grant can exclude its siblings. Remember a folder only
    // when the user selects it to save a recipe. Opening images never prompts.
    private static func folderKey(_ source: URL) -> String {
        "processingFolder:" + source.deletingLastPathComponent().standardizedFileURL.path
    }
    private static func rememberedFolder(for source: URL) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: folderKey(source)) else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }
    @MainActor static func grantSaveAccess(for source: URL) throws {
        let folder = source.deletingLastPathComponent()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = folder
        panel.prompt = "Allow Access"
        panel.message = "Choose the image’s folder to save its processing settings."
        guard panel.runModal() == .OK, let selected = panel.url else { throw CancellationError() }
        guard selected.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path else {
            throw SeizaCoreError.message("Choose the folder containing " + source.lastPathComponent + ".")
        }
        let data = try selected.bookmarkData(options: .withSecurityScope,
                                             includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: folderKey(source))
    }

    private final class Presenter: NSObject, NSFilePresenter {
        let primaryPresentedItemURL: URL?
        let presentedItemURL: URL?
        let presentedItemOperationQueue = OperationQueue()
        init(_ source: URL) {
            primaryPresentedItemURL = source
            presentedItemURL = ProcessingRecipe.url(for: source)
        }
    }
    private static func coordinate<T>(_ source: URL, write: Bool, access: (URL) throws -> T) throws -> T {
        let folder = rememberedFolder(for: source)
        let accessFolder = folder?.startAccessingSecurityScopedResource() == true
        defer { if accessFolder { folder?.stopAccessingSecurityScopedResource() } }
        let presenter = Presenter(source)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var error: NSError?
        var result: Result<T, Error>?
        let destination = url(for: source)
        let accessor: (URL) -> Void = { url in result = Result { try access(url) } }
        if write {
            coordinator.coordinate(writingItemAt: destination, options: .forReplacing, error: &error, byAccessor: accessor)
        } else {
            coordinator.coordinate(readingItemAt: destination, options: [], error: &error, byAccessor: accessor)
        }
        if let error { throw error }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    static func read(for source: URL) throws -> FITSImageProcessingConfiguration? {
        // Most images have no recipe. Probing never creates a file or opens a save panel.
        do {
            return try coordinate(source, write: false) { url in
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                return try decode(file.read(upToCount: 1_048_577) ?? Data())
            }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) {
            return nil
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            error.code == NSFileReadNoPermissionError && !FileManager.default.fileExists(atPath: url(for: source).path) {
            // A single-file grant can hide a nonexistent sibling, too.
            return nil
        }
    }

    func save(beside source: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try Self.coordinate(source, write: true) { try data.write(to: $0, options: .atomic) }
    }
}

/// AppKit owns the mouse sequence so the processing scroll view cannot take a rectangle drag.
struct AIRegionPicker: NSViewRepresentable {
    let width: Int
    let height: Int
    let selected: (AIRegion) -> Void

    func makeNSView(context: Context) -> Canvas { Canvas() }
    func updateNSView(_ view: Canvas, context: Context) {
        view.selected = { rect in
            let x = min(width - 1, max(0, Int(floor(rect.minX * CGFloat(width)))))
            let y = min(height - 1, max(0, Int(floor(rect.minY * CGFloat(height)))))
            let right = min(width, max(x + 1, Int(ceil(rect.maxX * CGFloat(width)))))
            let bottom = min(height, max(y + 1, Int(ceil(rect.maxY * CGFloat(height)))))
            selected(AIRegion(x: x, y: y, width: right - x, height: bottom - y))
        }
    }

    final class Canvas: NSView {
        override var isFlipped: Bool { true }
        var selected: ((CGRect) -> Void)?
        private var start: CGPoint?
        private var selection: CGRect? { didSet { needsDisplay = true } }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
        override func mouseDown(with event: NSEvent) {
            start = convert(event.locationInWindow, from: nil)
        }
        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let end = convert(event.locationInWindow, from: nil)
            selection = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                               width: abs(start.x - end.x), height: abs(start.y - end.y)).intersection(bounds)
        }
        override func mouseUp(with event: NSEvent) {
            mouseDragged(with: event)
            defer { start = nil; selection = nil }
            guard let r = selection, !r.isEmpty, bounds.width > 0, bounds.height > 0 else { return }
            selected?(CGRect(x: r.minX / bounds.width, y: r.minY / bounds.height,
                             width: r.width / bounds.width, height: r.height / bounds.height))
        }
        override func draw(_ dirtyRect: NSRect) {
            guard let selection else { return }
            NSColor.systemYellow.setStroke()
            NSBezierPath(rect: selection).stroke()
        }
    }
}

struct AIProcessingControls: View {
    @ObservedObject var model: ImageDocumentModel
    @Binding var settings: AIProcessing?
    @Binding var region: AIRegion?
    @Binding var fullPreview: Bool
    @Binding var showOutline: Bool
    @State private var retained = AIProcessing()
    @State private var expanded = true
    @State private var advanced = false
    @State private var models: [String] = []
    @State private var devices = ["cpu"]
    @State private var confirmRemove = false
    @State private var published: [String] = []
    @State private var busy = false
    @State private var message: String?

    private var parameters: Binding<AIProcessing> {
        Binding(get: { settings ?? retained }, set: { settings = $0; retained = $0 })
    }
    private var selection: Binding<Bool> {
        Binding(get: { settings != nil }, set: { on in
            if let settings { retained = settings }
            settings = on ? retained : nil
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("AI Noise Reduction", isOn: selection)
                .disabled(!AIRestoration.supported)
            if !AIRestoration.supported {
                Text("Requires Apple silicon.").font(.caption).foregroundStyle(.secondary)
            } else if settings != nil {
                DisclosureGroup("Noise reduction settings", isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 9) {
                        band("Grain", parameters.high)
                        band("Mottle", parameters.low)
                        HStack {
                            Text("Noise scale")
                            TextField("Pixels", value: parameters.scale, format: .number)
                                .frame(width: 60)
                            Text("px").foregroundStyle(.secondary)
                        }
                        Picker("Preview", selection: $fullPreview) {
                            Text("Selected Rectangle").tag(false)
                            Text("Full Image").tag(true)
                        }
                        if !fullPreview, let image = model.image, let metadata = model.metadata {
                            rectanglePicker(image, width: metadata.width, height: metadata.height)
                            Toggle("Show rectangle outline", isOn: $showOutline)
                        }
                        DisclosureGroup("Model and device", isExpanded: $advanced) {
                            modelControls.padding(.top, 6)
                        }
                        Button("Save Linear AI FITS…") { exportLinear() }
                        if busy { ProgressView().controlSize(.small) }
                        if let message { Text(message).font(.caption).textSelection(.enabled) }
                    }.padding(.top, 8)
                }
            }
        }.onChange(of: advanced) { _, open in
            if open {
                manage { try AIRestoration.shared.installed().map(\.name) }
                Task {
                    do { devices = try await Task.detached { try AIRestoration.shared.backends() }.value }
                    catch { message = error.localizedDescription }
                }
            }
        }
    }

    private func band(_ title: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(title).frame(width: 48, alignment: .leading)
            Slider(value: value, in: 0...1).accessibilityLabel(title)
            Text(value.wrappedValue, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                .frame(width: 42, alignment: .trailing)
        }
    }

    private func rectanglePicker(_ image: CGImage, width: Int, height: Int) -> some View {
        Image(decorative: image, scale: 1).resizable().aspectRatio(CGFloat(width) / CGFloat(max(1, height)), contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    let sx = geo.size.width / CGFloat(width), sy = geo.size.height / CGFloat(height)
                    let r = region ?? AIRegion.center(width: width, height: height)
                    if showOutline {
                        Rectangle().stroke(.yellow, lineWidth: 1.5)
                            .frame(width: CGFloat(r.width) * sx, height: CGFloat(r.height) * sy)
                            .position(x: (CGFloat(r.x) + CGFloat(r.width) / 2) * sx, y: (CGFloat(r.y) + CGFloat(r.height) / 2) * sy)
                    }
                    AIRegionPicker(width: width, height: height) { region = $0 }
                }
            }.frame(maxHeight: 160).help("Drag across the image to select a preview rectangle.")
            .accessibilityLabel("Preview rectangle")
    }
    private var modelControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Model", selection: parameters.model) {
                Text("Recommended").tag(nil as String?)
                ForEach(Set(models + published + [settings?.model].compactMap { $0 }).sorted(), id: \.self) { Text($0).tag(Optional($0)) }
            }
            HStack {
                Button("Check for Models") {
                    busy = true
                    Task {
                        do { published = try await Task.detached { try AIRestoration.shared.catalog().models.map(\.name) }.value }
                        catch { message = error.localizedDescription }
                        busy = false
                    }
                }
                Button("Download or Update") {
                    let name = settings?.model
                    manage { _ = try AIRestoration.shared.update(name); return try AIRestoration.shared.installed().map(\.name) }
                }
                Button("Import…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    manage {
                        let grant = url.startAccessingSecurityScopedResource()
                        defer { if grant { url.stopAccessingSecurityScopedResource() } }
                        _ = try AIRestoration.shared.importBundle(url)
                        return try AIRestoration.shared.installed().map(\.name)
                    }
                }
            }.controlSize(.small)
            Picker("Device", selection: parameters.backend) {
                Text("Automatic").tag(nil as String?)
                ForEach(devices, id: \.self) {
                    Text(["cpu": "CPU", "neural-engine": "Neural Engine", "coreml-gpu": "Core ML GPU",
                          "coreml-cpu": "Core ML CPU", "webgpu": "WebGPU"][$0] ?? $0).tag(Optional($0))
                }
            }
            Picker("Precision", selection: parameters.precision) {
                Text("Automatic").tag(nil as String?)
                Text("Float 32").tag(Optional("f32"))
                Text("Float 16").tag(Optional("f16"))
            }
            TextField("Tile size (automatic)", value: parameters.tile, format: .number)
            if let selected = settings?.model, models.contains(selected) {
                HStack {
                    Button("Verify Model") {
                        manage { try AIRestoration.shared.verify(selected); return try AIRestoration.shared.installed().map(\.name) }
                    }
                    Button("Remove…") { confirmRemove = true }
                }
                .confirmationDialog("Remove " + selected + "?", isPresented: $confirmRemove) {
                    Button("Remove Model", role: .destructive) {
                        // Disabling the step prevents a new preview from downloading the model again.
                        settings = nil
                        retained.model = nil
                        manage { try AIRestoration.shared.remove(selected); return try AIRestoration.shared.installed().map(\.name) }
                    }
                }
            }
        }.disabled(busy)
    }
    private func manage(_ work: @escaping () throws -> [String]) {
        busy = true
        message = nil
        Task {
            do { models = try await Task.detached { try work() }.value }
            catch { message = error.localizedDescription }
            busy = false
        }
    }

    private func exportLinear() {
        guard let settings else { return }
        let source = model.url
        let panel = NSSavePanel()
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + "-denoised.fits"
        panel.allowedContentTypes = [UTType(filenameExtension: "fits") ?? .data]
        guard panel.runModal() == .OK, let to = panel.url else { return }
        busy = true
        Task {
            do {
                try await Task.detached {
                    guard to.resolvingSymlinksInPath().standardizedFileURL != source.resolvingSymlinksInPath().standardizedFileURL else {
                        throw SeizaCoreError.message("Choose a different file to preserve the source image.")
                    }
                    let file = try AIRestoration.shared.prepare(source, settings: settings)
                    try withExtendedLifetime(file) {
                        let fm = FileManager.default
                        let stage = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: to, create: true)
                        defer { try? fm.removeItem(at: stage) }
                        let staged = stage.appendingPathComponent("linear.fits")
                        try fm.copyItem(at: file.url, to: staged)
                        if fm.fileExists(atPath: to.path) { _ = try fm.replaceItemAt(to, withItemAt: staged) }
                        else { try fm.moveItem(at: staged, to: to) }
                    }
                }.value
                message = "Saved " + to.lastPathComponent
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
}
