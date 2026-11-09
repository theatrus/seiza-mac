import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum StackFrameImportKind {
    case images, folder, list
}

struct StackAddFramesMenu: View {
    let action: (StackFrameImportKind) -> Void

    var body: some View {
        Menu("Add Frames") {
            Button("Add Images…") { action(.images) }
            Button("Add Folder…") { action(.folder) }
            Button("Add Image List…") { action(.list) }
        }
        .fixedSize()
    }
}

/// SwiftUI's inferred label/value for grouped LabeledContent can retain
/// its first value when an empty setup is filled in place.
struct StackCountRow: View {
    let label: String
    let value: String

    var body: some View {
        LabeledContent(label, value: value)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value)
    }
}

/// Retain the folder/file grants for the lifetime of the setup window, not
/// just the scanner: matching and integration read the same files later.
@MainActor final class StackFrameImporter: ObservableObject {
    struct Result {
        let sources: [URL]
        var frames: StackInputSelection
    }

    private(set) var accessURLs: [URL] = []
    private var scopedURLs: [URL] = []

    deinit {
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
    }

    func retain(_ urls: [URL]) {
        // Keep each new grant even if its URL equals an earlier unscoped URL.
        scopedURLs += urls.filter { $0.startAccessingSecurityScopedResource() }
        accessURLs += urls.filter { !accessURLs.contains($0) }
    }

    func choose(_ kind: StackFrameImportKind, reportUnknownLights: Bool = true) async throws -> Result? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = kind == .folder
        panel.canChooseFiles = kind != .folder
        panel.allowsMultipleSelection = kind == .images
        panel.prompt = "Add"
        switch kind {
        case .images:
            panel.title = "Add Images"
            panel.allowedContentTypes = UTType.seizaAstronomyImageExtensions.sorted().compactMap {
                UTType(filenameExtension: $0)
            }
        case .folder:
            panel.title = "Add Folder"
        case .list:
            panel.title = "Add Image List"
            panel.allowedContentTypes = [.plainText, .commaSeparatedText]
        }
        guard await StackFilePanels.present(panel) == .OK else { return nil }
        let roots = panel.urls
        retain(roots)
        var scan = try await ImageCollection.scanInBackground(from: roots)
        if let denied = scan.issues.first(where: \.needsAccess) {
            let grant = NSOpenPanel()
            grant.title = "Allow Access to Listed Images"
            grant.message = "Choose the folders containing the listed images, or a shared parent folder."
            grant.prompt = "Allow Access"
            grant.canChooseFiles = false
            grant.canChooseDirectories = true
            grant.allowsMultipleSelection = true
            grant.directoryURL = denied.url.deletingLastPathComponent()
            if await StackFilePanels.present(grant) == .OK {
                retain(grant.urls)
                scan = try await ImageCollection.scanInBackground(from: roots)
            }
        }
        let images = scan.images
        let frames = try await classify(images, reportUnknownLights: reportUnknownLights)
        var result = Result(sources: images, frames: frames)
        result.frames.notes += scan.issues.map { issue in
            let source = issue.list.map { "\($0.lastPathComponent):\(issue.line ?? 0)" }
                ?? issue.url.lastPathComponent
            return "\(source): \(issue.message)"
        }
        let unsupported = images.filter { !ImageCollection.isStackableImage($0) }.count
        if unsupported > 0 { result.frames.notes.append("Skipped \(unsupported) images outside FITS and XISF.") }
        return result
    }

    func classify(_ images: [URL], reportUnknownLights: Bool = true) async throws -> StackInputSelection {
        let access = accessURLs
        let worker = Task.detached(priority: .userInitiated) {
            try StackInputService.classify(images, accessURLs: access, reportUnknownLights: reportUnknownLights)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

}

/// A standalone export uses the same integration and report checks as live
/// calibration preparation, with a separate destination chosen by the user.
enum CalibrationMasterExport {
    static func build(
        _ request: CalibrationMasterBuildRequest, output: URL, protectedSources: [URL]
    ) async throws -> CalibrationMasterBuildResult {
        let dependencies = [request.bias, request.dark].compactMap { $0 }
        let inputs = (request.inputs + dependencies).map { URL(fileURLWithPath: $0) }
        let sources = inputs + protectedSources
        let cancellation = try CalibrationCancelSignal()
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await runBlocking {
                let scoped = output.startAccessingSecurityScopedResource()
                defer { if scoped { output.stopAccessingSecurityScopedResource() } }
                try StackInputProtection.validate(output: output, sources: sources)
                let snapshots = try inputs.map { url in
                    guard let snapshot = StackFileIdentity.snapshot(forPath: url.path) else {
                        throw CalibrationServiceError.core("Could not read \(url.lastPathComponent).")
                    }
                    return snapshot
                }
                if cancellation.wasCancelled { throw CancellationError() }

                let manager = FileManager.default
                let staging = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                              appropriateFor: output, create: true)
                defer { try? manager.removeItem(at: staging) }
                let file = staging.appendingPathComponent("master.fits")
                var staged = request
                staged.output = file.path
                var result = try CalibrationService.buildMaster(
                    staged, cancellation: cancellation, isCancelled: { cancellation.wasCancelled })
                try CalibrationPreparationService.validateBuildResult(
                    result, request: staged, stagingOutput: file.path, minimum: 2)
                guard zip(inputs, snapshots).allSatisfy({ StackFileIdentity.snapshot(forPath: $0.path) == $1 }) else {
                    throw CalibrationServiceError.core("A calibration input changed during the build. Try again.")
                }
                try StackInputProtection.validate(output: output, sources: sources)
                if cancellation.wasCancelled { throw CancellationError() }
                if manager.fileExists(atPath: output.path) {
                    _ = try manager.replaceItemAt(output, withItemAt: file, options: .usingNewMetadataOnly)
                } else {
                    try manager.moveItem(at: file, to: output)
                }
                result.output = output.path
                return result
            }
        } onCancel: { cancellation.cancel() }
    }
}

@MainActor final class CalibrationMasterWindowController: NSObject, NSWindowDelegate {
    private static var current: CalibrationMasterWindowController?
    private let window: NSWindow
    private var busy = false

    static func present(urls: [URL] = [], accessURLs: [URL] = []) {
        let controller = current ?? CalibrationMasterWindowController(urls: urls, accessURLs: accessURLs)
        current = controller
        controller.window.makeKeyAndOrderFront(nil)
    }

    private init(urls: [URL], accessURLs: [URL]) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 620),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.contentViewController = NSHostingController(rootView: CalibrationMasterView(
            urls: urls, accessURLs: accessURLs,
            onClose: { [weak self] in self?.window.close() },
            onBusy: { [weak self] in self?.busy = $0 }
        ))
        window.title = "Build Calibration Masters"
        window.minSize = NSSize(width: 560, height: 440)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !busy }
    func windowWillClose(_ notification: Notification) { Self.current = nil }
}

private struct CalibrationMasterView: View {
    private enum Kind: String, CaseIterable, Identifiable {
        case bias = "bias", dark = "dark", darkFlat = "dark-flat", flat = "flat"
        var id: Self { self }
        var title: String { self == .darkFlat ? "Dark Flat" : rawValue.capitalized }
        var nativeKind: String { self == .darkFlat ? "dark" : rawValue }
    }

    let urls: [URL]
    let accessURLs: [URL]
    let onClose: () -> Void
    let onBusy: (Bool) -> Void
    @StateObject private var importer = StackFrameImporter()
    @State private var frames = StackInputSelection()
    @State private var protectedSources: [URL] = []
    @State private var selected: Set<URL> = []
    @State private var kind = Kind.bias
    @State private var bias: URL?
    @State private var darkFlat: URL?
    @State private var picking = false
    @State private var task: Task<Void, Never>?
    @State private var cancelling = false
    @State private var notice: String?
    @State private var failed = false
    @State private var showsNotes = false
    @State private var hasLoaded = false

    private var candidates: [URL] { frames.calibration.filter { frames.rawCalibrationRoles[$0] == kind.rawValue } }
    private var inputs: [URL] { candidates.filter(selected.contains) }
    private var busy: Bool { picking || task != nil }
    private var validation: String? {
        if inputs.count < 2 { return "Select at least two raw \(kind.title.lowercased()) frames." }
        if kind == .flat && bias == nil && darkFlat == nil { return "Choose a master bias or matching master dark flat." }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Source Frames") {
                    StackAddFramesMenu(action: add)
                    Picker("Master Type", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.title).tag($0) }
                    }
                    StackCountRow(label: "Selected Frames", value: "\(inputs.count) of \(candidates.count)")
                    if !candidates.isEmpty {
                        DisclosureGroup("Frames") {
                            ForEach(candidates, id: \.self) { url in
                                Toggle(url.lastPathComponent, isOn: Binding(
                                    get: { selected.contains(url) },
                                    set: { if $0 { selected.insert(url) } else { selected.remove(url) } }))
                                    .help(url.path)
                            }
                        }
                    }
                    if !frames.notes.isEmpty {
                        DisclosureGroup("Import Notes (\(frames.notes.count))", isExpanded: $showsNotes) {
                            ForEach(frames.notes, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                        }
                    }
                }
                if kind == .dark || kind == .flat {
                    Section("Calibration") {
                        dependency("Master Bias", url: $bias)
                        if kind == .flat { dependency("Master Dark Flat", url: $darkFlat) }
                    }
                }
            }
            .formStyle(.grouped)
            .toggleStyle(.checkbox)
            .disabled(busy)

            if let notice {
                Text(notice).foregroundStyle(failed ? Color.red : Color.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
            } else if let validation, task == nil {
                Text(validation).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
            }

            Divider().padding(.top, 8)
            HStack {
                if let task {
                    Button(cancelling ? "Cancelling…" : "Cancel Build") {
                        cancelling = true
                        task.cancel()
                    }.disabled(cancelling)
                    ProgressView().controlSize(.small)
                } else {
                    Button("Close", action: onClose).keyboardShortcut(.cancelAction).disabled(picking)
                }
                Spacer()
                Button("Build Master…", action: chooseOutput)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || validation != nil)
            }.padding()
        }
        .frame(minWidth: 540, minHeight: 390)
        .onChange(of: busy) { _, value in onBusy(value) }
        .onDisappear { task?.cancel() }
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            importer.retain(accessURLs + urls)
            guard !urls.isEmpty else { return }
            picking = true
            defer { picking = false }
            do {
                let initial = try await importer.classify(urls, reportUnknownLights: false)
                try Task.checkCancellation()
                append(initial, sources: urls)
            } catch is CancellationError { }
            catch { failed = true; notice = error.localizedDescription }
        }
    }

    private func append(_ incoming: StackInputSelection, sources: [URL]) {
        protectedSources += sources
        var incoming = incoming
        let skipped = incoming.lights.count + incoming.calibration.count - incoming.rawCalibrationRoles.count
        if skipped > 0 { incoming.notes.append("Skipped \(skipped) light frames or existing masters.") }
        let added = frames.append(incoming)
        selected.formUnion(added.rawCalibrationRoles.keys)
        if candidates.isEmpty, let first = Kind.allCases.first(where: { frames.rawCalibrationRoles.values.contains($0.rawValue) }) {
            kind = first
        }
        showsNotes = !incoming.notes.isEmpty
        failed = false
        notice = added.rawCalibrationRoles.isEmpty ? "No new raw calibration frames." : nil
    }

    private func add(_ choice: StackFrameImportKind) {
        picking = true
        Task { @MainActor in
            defer { picking = false }
            do {
                if let result = try await importer.choose(choice, reportUnknownLights: false) { append(result.frames, sources: result.sources) }
            } catch { failed = true; notice = error.localizedDescription }
        }
    }

    private func dependency(_ title: String, url: Binding<URL?>) -> some View {
        LabeledContent(title) {
            HStack {
                Button(url.wrappedValue?.lastPathComponent ?? "Choose…") {
                    picking = true
                    Task { @MainActor in
                        defer { picking = false }
                        if let chosen = await StackFilePanels.chooseCalibration(directory: candidates.first?.deletingLastPathComponent()) {
                            importer.retain([chosen])
                            url.wrappedValue = chosen
                        }
                    }
                }
                .help(url.wrappedValue?.path ?? "Choose an integrated calibration master")
                if url.wrappedValue != nil {
                    Button("Remove") { url.wrappedValue = nil }
                        .accessibilityLabel("Remove \(title.lowercased())")
                }
            }
        }
    }

    private func chooseOutput() {
        guard validation == nil, !busy else { return }
        let request = CalibrationMasterBuildRequest(
            kind: kind.nativeKind, inputs: inputs.map(\.path), output: "",
            bias: kind == .bias ? nil : bias?.path, dark: kind == .flat ? darkFlat?.path : nil,
            defectSuppression: kind == .flat ? CalibrationDefectSuppression() : nil)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.fits]
        panel.nameFieldStringValue = "master-\(kind.rawValue).fits"
        panel.directoryURL = inputs.first?.deletingLastPathComponent()
        panel.prompt = "Build"
        picking = true
        Task { @MainActor in
            defer { picking = false }
            guard await StackFilePanels.present(panel) == .OK, let output = panel.url else { return }
            let sources = protectedSources + importer.accessURLs
            failed = false
            notice = "Building calibration master…"
            task = Task { @MainActor in
                defer { task = nil; cancelling = false }
                do {
                    let report = try await CalibrationMasterExport.build(request, output: output, protectedSources: sources)
                    notice = "Saved \(output.lastPathComponent) using \(report.inputFrames) frames."
                    if !report.skippedInputs.isEmpty {
                        let details = report.skippedInputs.map { "\(URL(fileURLWithPath: $0.path).lastPathComponent): \($0.reason)" }
                        var known = Set(frames.notes)
                        frames.notes += details.filter { known.insert($0).inserted }
                        showsNotes = true
                    }
                } catch is CancellationError {
                    notice = "Master build cancelled."
                } catch {
                    failed = true
                    notice = error.localizedDescription
                }
            }
        }
    }
}
