import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum LiveStackCalibrationMode: String, CaseIterable, Identifiable {
    case none
    case masters
    case automatic

    var id: Self { self }

    var title: String {
        switch self {
        case .none: "None"
        case .masters: "Existing masters"
        case .automatic: "Build from calibration frames"
        }
    }
}

// MARK: - Window model

@MainActor
final class LiveStackWindowModel: ObservableObject {
    enum Mode {
        case configuration
        case running
    }

    // Configuration state.
    @Published var mode = Mode.configuration
    @Published var watchFolder: URL?
    @Published var includeSubdirectories = false
    @Published var resumeExisting = true
    @Published var options = ImageStackOptions()
    @Published var calibrationMode = LiveStackCalibrationMode.none
    @Published var manualCalibration = ImageStackCalibration()
    @Published var calibrationLibrary: URL?
    @Published var calibrationSummary = ""
    @Published var isPreparingCalibration = false
    @Published var calibrationProgress: Double?
    @Published var configurationNotice: String?
    @Published var pendingWarnings: [String]?

    // Running state.
    @Published var snapshot = LiveStackRunSnapshot()
    @Published var previewImage: CGImage?
    @Published var isBusy = false
    @Published var runError: String?
    @Published var snapshotNotice: String?
    @Published var showsDiscardButton = false

    var onOpenOutput: (URL) -> Void = { _ in }
    var requestClose: () -> Void = {}

    private var coordinator: LiveStackCoordinator?
    private var observationTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Error>?
    private var preparedCalibration: CalibrationPreparationResult?
    private var initialReferencePath: String?
    private var displayedPreviewRevision = -1
    private var warningContinuation: CheckedContinuation<Bool, Never>?
    private var closing = false

    init(initialFolder: URL?) {
        watchFolder = initialFolder
    }

    var isConfigured: Bool { mode == .running }

    var validationMessage: String? {
        guard let watchFolder,
            FileManager.default.fileExists(atPath: watchFolder.path)
        else {
            return "Choose an existing capture folder."
        }
        if calibrationMode == .automatic {
            guard let calibrationLibrary,
                FileManager.default.fileExists(atPath: calibrationLibrary.path)
            else {
                return "Choose a calibration library folder."
            }
        }
        if let message = options.validationMessage { return message }
        if calibrationMode == .masters,
            let message = manualCalibration.validationMessage(for: []) {
            return message
        }
        return nil
    }

    var canStart: Bool { !isBusy && validationMessage == nil }

    // MARK: Configuration actions

    func chooseWatchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = watchFolder
        panel.message = "Choose the folder where new exposures appear."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        watchFolder = url
        initialReferencePath = nil
        preparedCalibration?.release()
        preparedCalibration = nil
        calibrationSummary = ""
    }

    func chooseCalibrationLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = calibrationLibrary
        panel.message = "Choose a library containing raw bias, dark, dark-flat, "
            + "and flat frames."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        calibrationLibrary = url
        calibrationSummary =
            "Masters will be matched and built when the live stack starts."
    }

    func chooseMaster(_ keyPath: WritableKeyPath<ImageStackCalibration, URL?>) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.fits, .xisf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an integrated calibration master."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        manualCalibration[keyPath: keyPath] = url
    }

    // MARK: Start

    func start() {
        guard canStart, !isConfigured else { return }
        isBusy = true
        configurationNotice = nil
        preparationTask = Task {
            do {
                try await startLiveStack()
            } catch is CancellationError {
                configurationNotice = "Calibration preparation was cancelled."
            } catch {
                configurationNotice = error.localizedDescription
            }
            isPreparingCalibration = false
            calibrationProgress = nil
            isBusy = false
        }
    }

    private func startLiveStack() async throws {
        guard let watchFolder else { return }
        var calibration = ImageStackCalibration()
        initialReferencePath = nil

        switch calibrationMode {
        case .none:
            break
        case .masters:
            calibration = manualCalibration
        case .automatic:
            calibration = try await prepareAutomaticCalibration()
        }
        try Task.checkCancellation()

        let bookmark = try? watchFolder.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        var configuration = LiveStackRunConfiguration(
            watchFolder: watchFolder.path,
            watchFolderBookmark: bookmark,
            sessionRootDirectory: LiveStackSessionPaths.forWatchFolder(watchFolder.path))
        configuration.groupTitle = "Live stack — \(watchFolder.lastPathComponent)"
        configuration.includeSubdirectories = includeSubdirectories
        configuration.resumeExisting = resumeExisting
        configuration.applyCalibrationOnResume = calibrationMode != .none
        configuration.initialReferencePath = initialReferencePath
        configuration.options = options
        configuration.calibration = calibration

        let coordinator = try LiveStackCoordinator(configuration: configuration)
        self.coordinator = coordinator
        observationTask = Task { [weak self] in
            for await snapshot in await coordinator.snapshots() {
                guard let self else { return }
                self.apply(snapshot)
            }
        }
        mode = .running
        do {
            try await coordinator.start()
        } catch {
            runError = error.localizedDescription
        }
    }

    private func prepareAutomaticCalibration() async throws -> ImageStackCalibration {
        guard let watchFolder, let calibrationLibrary else {
            throw LiveStackRunError.invalidConfiguration(
                "Choose a calibration library folder.")
        }
        isPreparingCalibration = true
        calibrationProgress = nil
        calibrationSummary = "Finding a reference light…"

        let includeSubdirectories = includeSubdirectories
        let watchPath = watchFolder.path
        let reference = try await runBlocking {
            try Self.findReferenceLight(
                inFolder: watchPath,
                includeSubdirectories: includeSubdirectories)
        }
        guard let reference else {
            throw LiveStackRunError.invalidConfiguration(
                "Automatic calibration needs one completed light frame in the "
                    + "capture folder. Add a light first, or choose existing masters.")
        }
        initialReferencePath = reference.path

        let service = CalibrationPreparationService()
        let request = CalibrationPreparationRequest(
            reference: reference,
            sourcePaths: [calibrationLibrary.path],
            cacheDirectory: CalibrationCachePaths.forLibrary(calibrationLibrary.path))
        let prepared = try await service.prepare(request) { update in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.calibrationSummary = update.message
                self.calibrationProgress = update.total > 0
                    ? Double(update.completed) / Double(update.total)
                    : nil
            }
        }
        preparedCalibration?.release()
        preparedCalibration = prepared
        calibrationSummary = Self.describeCalibration(prepared)
        isPreparingCalibration = false
        calibrationProgress = nil

        if !prepared.warnings.isEmpty {
            let proceed = await confirmWarnings(prepared.warnings)
            guard proceed else {
                configurationNotice =
                    "Live stacking was cancelled before any light frames were "
                    + "processed."
                throw CancellationError()
            }
        }
        return prepared.calibration
    }

    nonisolated private static func findReferenceLight(
        inFolder folder: String,
        includeSubdirectories: Bool
    ) throws -> CalibrationFrameProbe? {
        var files: [(path: String, modified: Date)] = []
        let root = URL(fileURLWithPath: folder)
        func visit(_ directory: URL) {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                    .contentModificationDateKey,
                ])) ?? []
            for url in contents {
                let values = try? url.resourceValues(forKeys: [
                    .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                    .contentModificationDateKey,
                ])
                if values?.isSymbolicLink == true { continue }
                if values?.isDirectory == true {
                    if includeSubdirectories { visit(url) }
                    continue
                }
                guard ImageCollection.isStackableImage(url),
                    (values?.fileSize ?? 0) > 0
                else { continue }
                files.append((
                    url.path, values?.contentModificationDate ?? .distantPast))
            }
        }
        visit(root)
        files.sort {
            $0.modified == $1.modified
                ? $0.path.caseInsensitiveCompare($1.path) == .orderedAscending
                : $0.modified < $1.modified
        }
        for file in files {
            guard let probe = try? CalibrationService.probe(path: file.path) else {
                continue
            }
            if probe.role == CalibrationFrameRole.light {
                return probe
            }
        }
        return nil
    }

    static func describeCalibration(_ result: CalibrationPreparationResult) -> String {
        let prepared = result.summaries
            .filter { $0.masterPath != nil }
            .map { "\($0.kind) (\($0.cacheReused ? "reused" : "built"))" }
        var text = prepared.isEmpty
            ? "No compatible masters could be prepared."
            : "Prepared \(prepared.joined(separator: ", "))."
        if !result.warnings.isEmpty {
            text += " " + result.warnings.joined(separator: " ")
        }
        return text
    }

    private func confirmWarnings(_ warnings: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            warningContinuation = continuation
            pendingWarnings = warnings
        }
    }

    func resolveWarnings(proceed: Bool) {
        pendingWarnings = nil
        warningContinuation?.resume(returning: proceed)
        warningContinuation = nil
    }

    // MARK: Snapshot application

    private func apply(_ snapshot: LiveStackRunSnapshot) {
        self.snapshot = snapshot
        if snapshot.previewRevision != displayedPreviewRevision,
            let preview = snapshot.preview {
            displayedPreviewRevision = snapshot.previewRevision
            previewImage = preview.makeCGImage()
        }
    }

    // MARK: Running actions

    var pauseButtonTitle: String {
        if snapshot.requiresReopenToResume { return "Reopen Required" }
        if snapshot.state == .paused { return "Resume" }
        if snapshot.state == .needsAttention { return "Retry Checkpoint" }
        return "Pause and Save"
    }

    var pauseButtonEnabled: Bool {
        !snapshot.requiresReopenToResume && !isBusy
            && (snapshot.state.isRunning
                || snapshot.state == .paused
                || snapshot.state == .needsAttention)
    }

    var snapshotButtonEnabled: Bool {
        !snapshot.requiresReopenToResume && !isBusy && snapshot.hasStack
    }

    var finishButtonEnabled: Bool {
        !snapshot.requiresReopenToResume && !isBusy && snapshot.hasStack
    }

    func pauseOrResume() {
        guard let coordinator else { return }
        isBusy = true
        runError = nil
        Task {
            do {
                if snapshot.state == .paused || snapshot.state == .needsAttention {
                    try await coordinator.start()
                } else {
                    try await coordinator.pauseAndSave()
                }
            } catch {
                runError = error.localizedDescription
            }
            isBusy = false
        }
    }

    func saveSnapshot() {
        guard let coordinator, snapshotButtonEnabled else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.fits]
        panel.nameFieldStringValue = "live-stack-snapshot.fits"
        panel.message = "Save a non-destructive snapshot of the live stack."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isBusy = true
        runError = nil
        snapshotNotice = nil
        Task {
            do {
                let result = try await coordinator.saveSnapshot(to: url.path)
                snapshotNotice = "Saved \(url.lastPathComponent) with "
                    + "\(result.acceptedFrames) accepted frame(s)."
            } catch {
                runError = error.localizedDescription
            }
            isBusy = false
        }
    }

    func finish() {
        guard let coordinator, finishButtonEnabled else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.fits]
        panel.nameFieldStringValue = "live-stack.fits"
        panel.message = "Save the completed unstretched 32-bit floating-point "
            + "FITS stack."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isBusy = true
        runError = nil
        Task {
            do {
                let result = try await coordinator.finish(to: url.path)
                let output = URL(fileURLWithPath: result.outputPath)
                await teardown(save: false)
                isBusy = false
                onOpenOutput(output)
                requestClose()
            } catch {
                runError = error.localizedDescription
                isBusy = false
            }
        }
    }

    // MARK: Closing

    /// True when the window may close right away; otherwise a checkpointing
    /// close is started and `requestClose` fires when it is safe.
    func canCloseImmediately() -> Bool {
        if closing { return true }
        preparationTask?.cancel()
        resolveWarnings(proceed: false)
        guard coordinator != nil else { return true }
        beginClose()
        return false
    }

    private func beginClose() {
        guard !closing else { return }
        isBusy = true
        Task {
            let save = !snapshot.requiresReopenToResume
            if save, let coordinator {
                do {
                    try await coordinator.pauseAndSave()
                } catch {
                    isBusy = false
                    runError = "The final checkpoint failed: "
                        + error.localizedDescription
                    showsDiscardButton = true
                    return
                }
            }
            await teardown(save: false)
            closing = true
            isBusy = false
            requestClose()
        }
    }

    func discardAndClose() {
        Task {
            await teardown(save: false)
            closing = true
            requestClose()
        }
    }

    private func teardown(save: Bool) async {
        observationTask?.cancel()
        observationTask = nil
        if let coordinator {
            await coordinator.dispose()
        }
        coordinator = nil
        preparedCalibration?.release()
        preparedCalibration = nil
    }
}

// MARK: - Views

struct LiveStackWindowView: View {
    @ObservedObject var model: LiveStackWindowModel

    var body: some View {
        VStack(spacing: 0) {
            if model.isConfigured {
                LiveStackRunningView(model: model)
            } else {
                LiveStackConfigurationView(model: model)
            }
            Divider()
            commandBar
        }
        .frame(minWidth: 760, minHeight: 560)
        .sheet(isPresented: warningSheetBinding) {
            CalibrationWarningsSheet(
                warnings: model.pendingWarnings ?? [],
                primaryTitle: "Start Live Stacking",
                onPrimary: { model.resolveWarnings(proceed: true) },
                onCancel: { model.resolveWarnings(proceed: false) })
        }
    }

    private var warningSheetBinding: Binding<Bool> {
        Binding(
            get: { model.pendingWarnings != nil },
            set: { presented in
                if !presented, model.pendingWarnings != nil {
                    model.resolveWarnings(proceed: false)
                }
            })
    }

    private var commandBar: some View {
        HStack(spacing: 10) {
            Text(footerHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            if model.isConfigured {
                if model.showsDiscardButton {
                    Button("Discard Unsaved Changes and Close") {
                        model.discardAndClose()
                    }
                }
                Button(model.pauseButtonTitle) {
                    model.pauseOrResume()
                }
                .disabled(!model.pauseButtonEnabled)
                Button("Save Snapshot…") {
                    model.saveSnapshot()
                }
                .disabled(!model.snapshotButtonEnabled)
                Button("Finish and Save…") {
                    model.finish()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.finishButtonEnabled)
            } else {
                Button("Start Live Stack") {
                    model.start()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canStart)
            }
        }
        .padding(14)
    }

    private var footerHint: String {
        model.isConfigured
            ? "Closing pauses and checkpoints the session so it can resume later."
            : "The folder is only read; checkpoints and outputs are stored separately."
    }
}

private struct LiveStackConfigurationView: View {
    @ObservedObject var model: LiveStackWindowModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Live Folder Stacking")
                        .font(.title2.weight(.semibold))
                    Text("Seiza waits for complete FITS or XISF files, registers "
                        + "each compatible light, checkpoints the exact accumulator, "
                        + "and measures how image depth improves.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            Form {
                Section("Capture Folder") {
                    LabeledContent("Folder") {
                        HStack {
                            Text(model.watchFolder?.path
                                ?? "Choose the folder where new exposures appear")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(
                                    model.watchFolder == nil ? .secondary : .primary)
                            Button("Choose…") { model.chooseWatchFolder() }
                        }
                    }
                    Toggle("Include subfolders", isOn: $model.includeSubdirectories)
                    Toggle(
                        "Resume the most recent compatible session",
                        isOn: $model.resumeExisting)
                    Text("The first compatible light locks image dimensions and "
                        + "filter for this window. Files for other filters are "
                        + "ignored; use a separate capture folder for each "
                        + "simultaneous filter stack.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Stacking") {
                    Picker("Normalization", selection: $model.options.normalization) {
                        ForEach(StackNormalizationMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    if model.options.normalization == .local {
                        Picker("Tile size", selection: $model.options.localTileSize) {
                            ForEach([64, 128, 256, 512], id: \.self) { size in
                                Text("\(size) px").tag(size)
                            }
                        }
                    }
                    Picker("Sample rejection", selection: $model.options.rejection) {
                        ForEach(StackRejectionMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    if model.options.rejection == .deltaSigma {
                        LabeledContent("Sigma limits") {
                            HStack {
                                TextField(
                                    "Low", value: $model.options.sigmaLow,
                                    format: .number)
                                    .frame(width: 70)
                                Text("low").foregroundStyle(.secondary)
                                TextField(
                                    "High", value: $model.options.sigmaHigh,
                                    format: .number)
                                    .frame(width: 70)
                                Text("high").foregroundStyle(.secondary)
                            }
                        }
                        Stepper(
                            "Warmup frames: \(model.options.rejectionWarmup)",
                            value: $model.options.rejectionWarmup,
                            in: 2...100)
                    }
                    DisclosureGroup("Advanced registration limits") {
                        TextField(
                            "Maximum RMS (pixels)",
                            value: $model.options.maximumRegistrationRMS,
                            format: .number)
                        TextField(
                            "Drift floor (pixels)",
                            value: $model.options.maximumDriftPixels,
                            format: .number)
                        TextField(
                            "Maximum drift fraction",
                            value: $model.options.maximumDriftFraction,
                            format: .number)
                        TextField(
                            "Minimum overlap",
                            value: $model.options.minimumOverlap,
                            format: .number)
                    }
                }

                Section("Calibration") {
                    Picker("Source", selection: $model.calibrationMode) {
                        ForEach(LiveStackCalibrationMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Text("When resuming, None preserves the checkpoint's "
                        + "calibration. Existing or automatic masters are applied "
                        + "atomically as a new calibration epoch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if model.calibrationMode == .masters {
                        masterRow("Master bias", \.bias)
                        masterRow("Master dark", \.dark)
                        masterRow("Master flat", \.flat)
                        Toggle(
                            "Override master-dark exposure",
                            isOn: $model.manualCalibration.overridesDarkExposure)
                            .disabled(model.manualCalibration.dark == nil)
                        if model.manualCalibration.overridesDarkExposure {
                            TextField(
                                "Master-dark exposure (seconds)",
                                value: $model.manualCalibration.darkExposureSeconds,
                                format: .number)
                        }
                    }

                    if model.calibrationMode == .automatic {
                        Text("Choose a library containing raw bias, dark, "
                            + "dark-flat, and flat frames. Seiza matches metadata, "
                            + "builds reusable masters in dependency order, and "
                            + "will not apply an unsafe flat.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        LabeledContent("Library") {
                            HStack {
                                Text(model.calibrationLibrary?.path
                                    ?? "Calibration library folder")
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(
                                        model.calibrationLibrary == nil
                                            ? .secondary : .primary)
                                Button("Choose…") { model.chooseCalibrationLibrary() }
                            }
                        }
                        if model.isPreparingCalibration {
                            if let progress = model.calibrationProgress {
                                ProgressView(value: progress)
                            } else {
                                ProgressView()
                            }
                        }
                        if !model.calibrationSummary.isEmpty {
                            Text(model.calibrationSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let message = model.validationMessage {
                    Text(message)
                        .foregroundStyle(.red)
                        .font(.callout)
                } else if let notice = model.configurationNotice {
                    Text(notice)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder
    private func masterRow(
        _ title: String,
        _ keyPath: WritableKeyPath<ImageStackCalibration, URL?>
    ) -> some View {
        LabeledContent(title) {
            HStack {
                Button(
                    model.manualCalibration[keyPath: keyPath]?.lastPathComponent
                        ?? "Choose…"
                ) {
                    model.chooseMaster(keyPath)
                }
                .lineLimit(1)
                if model.manualCalibration[keyPath: keyPath] != nil {
                    Button {
                        model.manualCalibration[keyPath: keyPath] = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }
}

private struct LiveStackRunningView: View {
    @ObservedObject var model: LiveStackWindowModel

    var body: some View {
        HSplitView {
            previewPane
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            detailsPane
                .frame(minWidth: 340, idealWidth: 400, maxWidth: 460)
        }
        .padding(14)
    }

    private var previewPane: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.035, green: 0.04, blue: 0.047))
            if let image = model.previewImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(6)
            } else {
                VStack(spacing: 10) {
                    if model.snapshot.state.isRunning {
                        ProgressView()
                    }
                    Text("Waiting for the first complete light frame…")
                        .foregroundStyle(.white)
                }
            }
        }
        .accessibilityLabel("Live stack preview")
    }

    private var detailsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                statusCard
                depthCard
                if let notice = model.snapshotNotice {
                    Text(notice)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let error = model.runError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                attentionCard
            }
            .padding(.leading, 12)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.snapshot.state.title)
                .font(.title3.weight(.semibold))
            Text(model.snapshot.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
            if !model.snapshot.currentFileName.isEmpty {
                Text(model.snapshot.currentFileName)
                    .font(.callout.monospacedDigit())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 0) {
                counter(model.snapshot.acceptedFrames, "Accepted")
                counter(model.snapshot.rejectedFrames, "Rejected")
                counter(model.snapshot.skippedFrames, "Skipped")
            }
            .padding(.vertical, 4)
            Group {
                Text(filterText)
                Text(calibrationText)
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(checkpointText)
                }
                Text("Folder monitor: \(model.snapshot.monitorStatus)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(cardBackground)
    }

    private var depthCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stack Depth")
                .font(.headline)
            StackSnrChartView(points: model.snapshot.snrPlot)
                .frame(minHeight: 170)
            Text(snrSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(cardBackground)
    }

    @ViewBuilder
    private var attentionCard: some View {
        let messages = LiveStackAttentionPresentation.recentMessages(
            model.snapshot.attention)
        if !messages.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Needs Attention")
                    .font(.headline)
                ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(cardBackground)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .controlBackgroundColor))
    }

    private func counter(_ value: Int, _ caption: String) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title2.monospacedDigit().weight(.semibold))
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var filterText: String {
        guard let filter = model.snapshot.filter else {
            return "Filter: waiting for first light"
        }
        return "Filter: \(filter.displayName) (\(filter.source.rawValue))"
    }

    private var calibrationText: String {
        guard let epoch = model.snapshot.calibrationHistory.last else {
            return "Calibration: none"
        }
        func name(_ path: String?) -> String {
            path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "none"
        }
        var text: String
        if !epoch.hasAnyMasters {
            text = "Calibration: none"
        } else {
            text = "Calibration: bias \(name(epoch.biasPath)), "
                + "dark \(name(epoch.darkPath)), flat \(name(epoch.flatPath))"
        }
        let epochs = model.snapshot.calibrationHistory.count
        if epochs > 1 {
            text += " · \(epochs) epochs"
        }
        return text
    }

    private var checkpointText: String {
        guard let generation = model.snapshot.checkpointGeneration else {
            return "Checkpoint: not saved yet"
        }
        let age: String
        if let at = model.snapshot.lastCheckpointAtUTC {
            let seconds = max(0, Date().timeIntervalSince(at))
            if seconds < 10 {
                age = "just now"
            } else if seconds < 60 {
                age = "\(Int(seconds)) seconds ago"
            } else {
                age = "\(Int(seconds / 60)) minutes ago"
            }
        } else {
            age = "just now"
        }
        return "Checkpoint \(generation): \(age)"
    }

    private var snrSummary: String {
        let plot = model.snapshot.snrPlot
        guard let plotted = plot.last else {
            return "Noise and signal are measured at 1, 2, 4, 8… accepted frames."
        }
        guard let sample = model.snapshot.snrSamples.last(where: {
            $0.acceptedFrames == Int(plotted.frames)
        }) else {
            return String(
                format: "Relative SNR %.2f at %d accepted frame(s).",
                plotted.snr, plotted.frames)
        }
        let background = sample.background.isFinite
            ? String(format: "%.5f", sample.background)
            : "unavailable"
        var text = String(
            format: "Relative SNR %.2f at %d frame(s) · noise %.5f · background %@",
            plotted.snr, plotted.frames, sample.noise, background)
        if let exposure = sample.cumulativeExposureSeconds,
            exposure.isFinite, exposure > 0 {
            text += " · \(Self.formatDuration(exposure)) exposure at measurement"
        }
        return text
    }

    static func formatDuration(_ seconds: Double) -> String {
        if seconds >= 3600 {
            return String(format: "%.1f h", seconds / 3600)
        }
        if seconds >= 60 {
            return String(format: "%.1f min", seconds / 60)
        }
        return String(format: "%.0f s", seconds)
    }
}

/// The "Calibration needs attention" confirmation shown before any light
/// frame is processed when preparation produced warnings.
struct CalibrationWarningsSheet: View {
    let warnings: [String]
    let primaryTitle: String
    let onPrimary: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Calibration Needs Attention")
                .font(.title3.weight(.semibold))
            ScrollView {
                Text(CalibrationPreparationWarningText.format(warnings))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 320)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(primaryTitle, action: onPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

// MARK: - Window controller

@MainActor
final class LiveStackWindowController: NSObject, NSWindowDelegate {
    private static var active: LiveStackWindowController?

    private let model: LiveStackWindowModel
    private var window: NSWindow?

    static func present(initialFolder: URL?, onOpenOutput: @escaping (URL) -> Void) {
        if let active, let window = active.window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = LiveStackWindowController(
            initialFolder: initialFolder, onOpenOutput: onOpenOutput)
        active = controller
        controller.show()
    }

    private init(initialFolder: URL?, onOpenOutput: @escaping (URL) -> Void) {
        model = LiveStackWindowModel(initialFolder: initialFolder)
        super.init()
        model.onOpenOutput = onOpenOutput
        model.requestClose = { [weak self] in
            self?.forceClose()
        }
    }

    private func show() {
        let hosting = NSHostingController(rootView: LiveStackWindowView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Live Stack"
        window.setContentSize(NSSize(width: 1080, height: 700))
        window.styleMask.insert([.resizable, .closable, .miniaturizable])
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    private var allowClose = false

    private func forceClose() {
        allowClose = true
        window?.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowClose { return true }
        return model.canCloseImmediately()
    }

    func windowWillClose(_ notification: Notification) {
        if Self.active === self {
            Self.active = nil
        }
        window?.delegate = nil
        window = nil
    }
}
