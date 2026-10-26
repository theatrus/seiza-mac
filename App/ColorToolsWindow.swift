import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ColorToolsWindowController: NSObject, NSWindowDelegate {
    private static var windows: [UUID: ColorToolsWindowController] = [:]
    private let id = UUID()
    private let model = ColorToolsModel()
    private var window: NSWindow!
    static func present() {
        let controller = ColorToolsWindowController()
        windows[controller.id] = controller
        controller.window.makeKeyAndOrderFront(nil)
    }
    private override init() {
        super.init()
        window = NSWindow(contentViewController: NSHostingController(rootView: ColorToolsWorkspace(model: model)))
        window.title = "Color Tools"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1120, height: 820))
        window.minSize = NSSize(width: 680, height: 620)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
    }
    func windowWillClose(_ notification: Notification) {
        model.close()
        Self.windows[id] = nil
    }
}

@MainActor
final class ColorToolsModel: ObservableObject {
    @Published var recipe = ColorToolsRecipe() {
        didSet {
            guard !importing, recipe != oldValue else { return }
            invalidatePreview()
            // Confirmations do not alter photometry, so they do not invalidate a loaded plan.
            var old = oldValue; old.aligned = recipe.aligned; old.linearConfirmed = recipe.linearConfirmed
            if old != recipe { plan = nil; planURL = nil; report = nil; message = "Inputs or settings changed. Build a new preview." }
        }
    }
    @Published private(set) var busy = false
    @Published private(set) var image: CGImage?
    @Published private(set) var message = "Choose aligned prepared FITS or XISF images. Build a preview before saving."
    @Published private(set) var result: ColorToolsResult?
    @Published private(set) var report: Data?
    @Published private(set) var plan: Data?
    private(set) var planURL: URL?
    private var importing = false
    private var task: Task<Void, Never>?
    private var directories: [URL] = []
    private var scopes: [URL] = []
    private var closed = false
    var needsAnalysis: Bool { recipe.tool == .continuum && !recipe.manual && plan == nil }
    var protectedURLs: [URL] { recipe.protectedURLs + [planURL, result?.imageURL].compactMap { $0 } }

    func choose(_ binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "fits"), .init(filenameExtension: "xisf")].compactMap { $0 }
        if panel.runModal() == .OK, let url = panel.url {
            if url.startAccessingSecurityScopedResource() { scopes.append(url) }
            binding.wrappedValue = url.path
        }
    }
    private func invalidatePreview() {
        result = nil; image = nil
        if !busy { removePreviews() }
    }
    private func removePreviews() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
    }
    func cancel() { task?.cancel(); message = "Cancelling after the current native operation…" }
    func close() {
        closed = true; task?.cancel()
        // A running native call owns its sources and staging folder until it returns.
        if !busy { cleanup() }
    }
    private func cleanup() {
        removePreviews()
        for url in scopes { url.stopAccessingSecurityScopedResource() }
        scopes.removeAll()
    }
    func build() {
        guard !busy else { return }
        let snapshot = recipe; let analysis = needsAnalysis; let fit = plan
        do { try snapshot.validate(analyze: analysis, plan: fit) }
        catch { message = error.localizedDescription; return }
        invalidatePreview(); busy = true
        message = analysis ? "Analyzing stellar photometry…" : "Building float preview…"
        task = Task {
            do {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("seiza-color-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                directories.append(directory)
                let built = try await ColorToolsService.shared.run(recipe: snapshot, analyze: analysis, plan: fit, directory: directory)
                try Task.checkCancellation()
                let rendered: CGImage?
                if let url = built.imageURL, built.status == "success" {
                    rendered = try await Task.detached(priority: .userInitiated) { try SeizaCore.render(url: url, maxDimension: 1600).image }.value
                } else { rendered = nil }
                try Task.checkCancellation()
                guard !closed else { throw CancellationError() }
                report = built.report; message = built.summary
                if analysis { plan = built.status == "fitted" ? built.plan : nil }
                else if built.status == "success" { result = built; image = rendered }
            } catch is CancellationError { if !closed { message = "Cancelled. No result was saved." } }
            catch { if !closed { message = error.localizedDescription } }
            busy = false; task = nil
            if closed { cleanup() }
        }
    }
    func saveImage() {
        guard !busy, let result else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "fits"), .init(filenameExtension: "xisf")].compactMap { $0 }
        panel.nameFieldStringValue = "Seiza-color.fits"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let sources = protectedURLs
        busy = true
        task = Task {
            let scope = url.startAccessingSecurityScopedResource()
            defer { if scope { url.stopAccessingSecurityScopedResource() }; busy = false; task = nil; if closed { cleanup() } }
            do {
                try await ColorToolsService.shared.save(preview: result, to: url, sources: sources)
                if !closed { message = "Saved \(url.lastPathComponent) from the built float preview." }
            } catch is CancellationError { if !closed { message = "Cancelled. No result was saved." } }
            catch { if !closed { message = error.localizedDescription } }
        }
    }
    func saveReport() {
        guard !busy, let report else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Seiza-color-report.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let sources = protectedURLs
        busy = true
        task = Task {
            let scope = url.startAccessingSecurityScopedResource()
            defer { if scope { url.stopAccessingSecurityScopedResource() }; busy = false; task = nil; if closed { cleanup() } }
            do { try await ColorToolsService.shared.saveReport(report, to: url, sources: sources); if !closed { message = "Saved processing report and exact-source plan." } }
            catch { if !closed { message = error.localizedDescription } }
        }
    }
    func loadPlan() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if url.startAccessingSecurityScopedResource() { scopes.append(url) }
            let data = try Data(contentsOf: url)
            try importPlan(data, url: url)
        } catch { message = error.localizedDescription }
    }
    func importPlan(_ data: Data, url: URL) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ImageStackError.invalidRequest("Invalid continuum report.") }
        let p = root["plan"] as? [String: Any] ?? root
        guard let identities = p["sources"] as? [String: Any], let line = identities["narrowband"] as? [String: Any],
              let refs = identities["references"] as? [[String: Any]], (1...3).contains(refs.count), p["coefficients"] is [Double] else {
            throw ImageStackError.invalidRequest("Choose a continuum plan or fitted report with one to three references.")
        }
        var restored = ColorToolsRecipe(); restored.tool = .continuum; restored.referenceCount = refs.count
        let paths = root["sources"] as? [[String: Any]] ?? []
        let auxiliary = root["auxiliarySources"] as? [[String: Any]] ?? []
        for (i, source) in ([line] + refs).enumerated() {
            if paths.count == refs.count + 1 { restored.paths[i] = paths[i]["path"] as? String ?? "" }
            else { restored.paths[i] = recipe.paths[i] }
            restored.saturations[i] = source["saturation"] as? Double ?? 0
            if let revision = source["clippingRevision"] as? String {
                restored.masks[i] = auxiliary.first { $0["sha256"] as? String == revision }?["path"] as? String ?? ""
            }
        }
        let planData = try JSONSerialization.data(withJSONObject: p, options: [.sortedKeys])
        importing = true; recipe = restored; importing = false
        invalidatePreview(); plan = planData; planURL = url; report = data
        message = "Plan loaded with producer metadata. Confirm alignment and the original linear scale, then build. Exact source hashes and grid will be validated."
    }
}

@MainActor
struct ColorToolsWorkspace: View {
    @ObservedObject var model: ColorToolsModel
    @State private var processingExpanded = false
    @State private var fitExpanded = false
    @State private var reportExpanded = false
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if geometry.size.width >= 980 {
                    HStack(alignment: .top, spacing: 0) {
                        controls.frame(width: 470)
                        Divider()
                        preview.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    ScrollView {
                        controlsContent.padding()
                        preview.frame(minHeight: 240)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.message).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if model.busy { ProgressView().controlSize(.small); Button("Cancel", action: model.cancel) }
                        Spacer()
                        Button("Save report / plan…", action: model.saveReport).disabled(model.busy || model.report == nil)
                        Button(model.needsAnalysis ? "Analyze stars" : "Build preview", action: model.build).disabled(model.busy)
                        Button("Save built image…", action: model.saveImage).disabled(model.busy || model.result == nil).buttonStyle(.borderedProminent)
                    }
                }.padding(14)
            }
        }
    }
    private var controls: some View { ScrollView { controlsContent.padding() } }
    private var controlsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Color Tools").font(.title2.bold())
            Picker("Workflow", selection: $model.recipe.tool) { ForEach(ColorTool.allCases) { Text($0.title).tag($0) } }
            Text("Use aligned prepared images, rather than raw Bayer data. Source images are preserved.").font(.caption).foregroundStyle(.secondary)
            if model.recipe.tool == .narrowband {
                Picker("Palette", selection: $model.recipe.palette) { Text("HOO").tag("hoo"); Text("SHO").tag("sho") }.pickerStyle(.segmented)
                Toggle("Inputs are already display-referred (0–1)", isOn: $model.recipe.inputDisplay)
            }
            if model.recipe.tool == .continuum {
                Stepper("Continuum references: \(model.recipe.referenceCount)", value: $model.recipe.referenceCount, in: 1...3)
            }
            ForEach(Array(model.recipe.inputLabels.enumerated()), id: \.offset) { index, label in
                VStack(alignment: .leading, spacing: 6) {
                    pathPicker(label, path: $model.recipe.paths[index])
                    if model.recipe.tool == .continuum {
                        number("Producer saturation (0 = unknown)", value: $model.recipe.saturations[index])
                        DisclosureGroup("Optional producer clipping mask") { pathPicker("Mono 0 / 1 mask", path: $model.recipe.masks[index]) }
                    }
                }
            }
            if [.restoreStars, .restorePreparedStars].contains(model.recipe.tool) {
                Toggle("Nebula is already display-referred (0–1)", isOn: $model.recipe.nebulaDisplay)
            }
            Toggle("All inputs share the same aligned pixel grid", isOn: $model.recipe.aligned)
            if model.recipe.requiresLinearConfirmation {
                Toggle("Linear sources retain their original common photometric scale", isOn: $model.recipe.linearConfirmed)
            }
            if model.recipe.tool == .continuum { continuumSettings }
            else { processingSettings }
            if let data = model.report, let text = String(data: data, encoding: .utf8) {
                DisclosureGroup("Processing report / plan JSON", isExpanded: $reportExpanded) {
                    Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.disabled(model.busy)
    }
    private var continuumSettings: some View {
        DisclosureGroup("Fit settings / saved plans", isExpanded: $fitExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Automatic fitting requires a producer saturation ceiling or clipping mask for each input. Do not use the observed maximum. A skipped fit never falls back to manual subtraction.").font(.caption).foregroundStyle(.secondary)
                if model.plan == nil {
                    Toggle("Match Gaussian PSFs before fitting", isOn: $model.recipe.psfMatching)
                } else {
                    Text("PSF preparation comes from the reviewed exact-source plan.").font(.caption)
                }
                Toggle("Use explicit manual coefficients", isOn: $model.recipe.manual)
                if model.recipe.manual {
                    ForEach(0..<model.recipe.referenceCount, id: \.self) { i in number("Reference \(i + 1) coefficient", value: $model.recipe.coefficients[i]) }
                }
                Button("Load continuum plan / report…", action: model.loadPlan)
                if model.plan != nil { Text("Exact-source plan ready. Review the fit summary before building.").font(.caption) }
            }.padding(.top, 8)
        }
    }
    private var processingSettings: some View {
        DisclosureGroup("Optional processing", isExpanded: $processingExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                if model.recipe.tool == .narrowband {
                    Toggle("Balance channels", isOn: $model.recipe.balance)
                    if model.recipe.balance {
                        number("Shadow protection (0–1)", value: $model.recipe.shadowProtection)
                        number("O III boost", value: $model.recipe.oiiiBoost)
                        number("S II boost", value: $model.recipe.siiBoost)
                        Toggle("Exclude detected stars from balance", isOn: $model.recipe.excludeStars)
                    }
                    pathPicker("Optional display RGB structure", path: $model.recipe.structure)
                    number("Structure mix (0–1)", value: $model.recipe.structureAmount)
                }
                if (model.recipe.tool == .narrowband && !model.recipe.inputDisplay) || ([.restoreStars, .restorePreparedStars].contains(model.recipe.tool) && !model.recipe.nebulaDisplay) {
                    number("Linked display target median", value: $model.recipe.targetMedian)
                }
                if [.stretchStars, .restoreStars].contains(model.recipe.tool) { number("RGB star stretch amount (0–8)", value: $model.recipe.starAmount) }
                if [.restoreStars, .restorePreparedStars].contains(model.recipe.tool) { number("Linked star reduction (0–1)", value: $model.recipe.starReduction) }
                if model.recipe.tool != .stretchStars { number("Nebula green reduction (0–1)", value: $model.recipe.greenReduction) }
                if model.recipe.tool == .restorePreparedStars { Text("Prepared display stars are screened once, without another star stretch.").font(.caption) }
            }.padding(.top, 8)
        }
    }
    private var preview: some View {
        VStack {
            if let image = model.image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit).padding()
            } else {
                ContentUnavailableView("Preview", systemImage: "photo", description: Text("Build and review a preview before saving. Continuum fitting first reports coefficients and validation quality."))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.15))
    }
    private func pathPicker(_ title: String, path: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.medium))
            HStack { TextField("Choose FITS or XISF…", text: path).textFieldStyle(.roundedBorder); Button("Choose…") { model.choose(path) } }
        }
    }
    private func number(_ title: String, value: Binding<Double>) -> some View {
        HStack { Text(title); Spacer(); TextField(title, value: value, format: .number).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 110) }
    }
}
