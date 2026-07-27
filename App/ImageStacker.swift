import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum StackNormalizationMode: String, CaseIterable, Identifiable, Sendable {
    case none
    case global
    case local

    var id: Self { self }

    var title: String {
        switch self {
        case .none: "None"
        case .global: "Global"
        case .local: "Local"
        }
    }
}

enum StackRejectionMode: String, CaseIterable, Identifiable, Sendable {
    case none
    case deltaSigma

    var id: Self { self }

    var title: String {
        switch self {
        case .none: "None"
        case .deltaSigma: "Delta Sigma"
        }
    }
}

struct ImageStackOptions: Equatable, Sendable {
    var normalization = StackNormalizationMode.global
    var localTileSize = 256
    var rejection = StackRejectionMode.deltaSigma
    var sigmaLow = 3.0
    var sigmaHigh = 3.0
    var rejectionWarmup = 5
    var maximumRegistrationRMS = 2.0
    var maximumDriftPixels = 256.0
    var maximumDriftFraction = 0.15
    var minimumOverlap = 0.60

    var validationMessage: String? {
        if normalization == .local, localTileSize < 16 {
            return "Local normalization tiles must be at least 16 pixels wide."
        }
        if rejection == .deltaSigma {
            guard sigmaLow.isFinite, sigmaLow > 0, sigmaHigh.isFinite, sigmaHigh > 0 else {
                return "Sigma thresholds must be positive numbers."
            }
            guard rejectionWarmup >= 2 else {
                return "Rejection warmup must include at least two frames."
            }
        }
        guard maximumRegistrationRMS.isFinite, maximumRegistrationRMS > 0 else {
            return "Maximum registration RMS must be positive."
        }
        guard maximumDriftPixels.isFinite, maximumDriftPixels > 0 else {
            return "Maximum drift must be positive."
        }
        guard maximumDriftFraction.isFinite, (0...1).contains(maximumDriftFraction) else {
            return "Maximum drift fraction must be between 0 and 1."
        }
        guard minimumOverlap.isFinite, (0...1).contains(minimumOverlap) else {
            return "Minimum overlap must be between 0 and 1."
        }
        return nil
    }

    var jsonData: Data {
        get throws {
            let payload = StackOptionsPayload(options: self)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(payload)
        }
    }
}

private struct StackOptionsPayload: Encodable {
    let registration: RegistrationPayload
    let normalization: NormalizationPayload
    let rejection: RejectionPayload
    let acceptance: AcceptancePayload

    init(options: ImageStackOptions) {
        registration = RegistrationPayload(
            maximumDriftPixels: options.maximumDriftPixels,
            maximumDriftFraction: options.maximumDriftFraction
        )
        normalization = NormalizationPayload(options: options)
        rejection = RejectionPayload(options: options)
        acceptance = AcceptancePayload(
            maximumRegistrationRMS: options.maximumRegistrationRMS,
            minimumOverlap: options.minimumOverlap
        )
    }

    struct RegistrationPayload: Encodable {
        let maximumDriftPixels: Double
        let maximumDriftFraction: Double

        enum CodingKeys: String, CodingKey {
            case maximumDriftPixels = "maximum_drift_pixels"
            case maximumDriftFraction = "maximum_drift_fraction"
        }
    }

    struct NormalizationPayload: Encodable {
        let mode: String
        let options: LocalOptions?

        init(options stackOptions: ImageStackOptions) {
            mode = stackOptions.normalization.rawValue
            options = stackOptions.normalization == .local
                ? LocalOptions(tileSize: stackOptions.localTileSize)
                : nil
        }

        struct LocalOptions: Encodable {
            let tileSize: Int

            enum CodingKeys: String, CodingKey {
                case tileSize = "tile_size"
            }
        }
    }

    struct RejectionPayload: Encodable {
        let mode: String
        let options: DeltaSigmaPayload?

        init(options stackOptions: ImageStackOptions) {
            switch stackOptions.rejection {
            case .none:
                mode = "none"
                options = nil
            case .deltaSigma:
                mode = "delta-sigma"
                options = DeltaSigmaPayload(
                    lowSigma: stackOptions.sigmaLow,
                    highSigma: stackOptions.sigmaHigh,
                    warmupSamples: stackOptions.rejectionWarmup,
                    minimumSigma: 1.0e-6
                )
            }
        }

        struct DeltaSigmaPayload: Encodable {
            let lowSigma: Double
            let highSigma: Double
            let warmupSamples: Int
            let minimumSigma: Double

            enum CodingKeys: String, CodingKey {
                case lowSigma = "low_sigma"
                case highSigma = "high_sigma"
                case warmupSamples = "warmup_samples"
                case minimumSigma = "minimum_sigma"
            }
        }
    }

    struct AcceptancePayload: Encodable {
        let maximumRegistrationRMS: Double
        let minimumOverlap: Double

        enum CodingKeys: String, CodingKey {
            case maximumRegistrationRMS = "maximum_registration_rms_pixels"
            case minimumOverlap = "minimum_overlap_fraction"
        }
    }
}

struct ImageStackCalibration: Equatable, Sendable {
    var bias: URL?
    var dark: URL?
    var flat: URL?
    var overridesDarkExposure = false
    var darkExposureSeconds = 300.0

    var validationMessage: String? {
        guard dark != nil || !overridesDarkExposure else {
            return "Choose a master dark before overriding its exposure."
        }
        if overridesDarkExposure,
           (!darkExposureSeconds.isFinite || darkExposureSeconds <= 0) {
            return "The master-dark exposure must be positive."
        }
        return nil
    }

    func validationMessage(for inputs: [URL]) -> String? {
        if let validationMessage { return validationMessage }
        let urls = inputs + [bias, dark, flat].compactMap { $0 }
        let paths = urls.map { $0.standardizedFileURL.path }
        guard Set(paths).count == paths.count else {
            return "Each light frame and calibration master must be a different file."
        }
        return nil
    }
}

struct ImageStackRequest: Sendable {
    let inputs: [URL]
    let output: URL
    let outputAccessURL: URL?
    let options: ImageStackOptions
    let calibration: ImageStackCalibration

    init(
        inputs: [URL],
        output: URL,
        outputAccessURL: URL? = nil,
        options: ImageStackOptions,
        calibration: ImageStackCalibration
    ) {
        self.inputs = inputs
        self.output = output
        self.outputAccessURL = outputAccessURL
        self.options = options
        self.calibration = calibration
    }
}

struct ImageStackGroup: Identifiable, Sendable {
    let id: String
    let filter: ImageFilenameFilter?
    let inputs: [URL]

    var title: String {
        filter?.title ?? (id == "all" ? "All frames" : "Other")
    }

    var filenameSuffix: String {
        filter?.filenameSuffix ?? "Other"
    }
}

enum ImageStackGrouping {
    static func hasMultipleDetectedFilters(in urls: [URL]) -> Bool {
        Set(urls.compactMap(ImageFilenameFilter.detect(in:))).count > 1
    }

    static func groups(for urls: [URL], splitByFilter: Bool) -> [ImageStackGroup] {
        guard splitByFilter, hasMultipleDetectedFilters(in: urls)
        else {
            return [ImageStackGroup(id: "all", filter: nil, inputs: urls)]
        }

        var order: [String] = []
        var groups: [String: ImageStackGroup] = [:]
        for url in urls {
            let filter = ImageFilenameFilter.detect(in: url)
            let key = filter?.rawValue ?? "other"
            if groups[key] == nil {
                order.append(key)
                groups[key] = ImageStackGroup(id: key, filter: filter, inputs: [])
            }
            let current = groups[key]!
            groups[key] = ImageStackGroup(
                id: key,
                filter: current.filter,
                inputs: current.inputs + [url]
            )
        }
        return order.compactMap { groups[$0] }
    }
}

struct ImageStackJob: Sendable {
    let group: ImageStackGroup
    let request: ImageStackRequest
}

struct ImageStackBatchRequest: Sendable {
    let jobs: [ImageStackJob]
}

struct ImageStackDisposition: Decodable, Sendable {
    let source: String?
    let accepted: Bool
    let reason: String?
}

struct ImageStackProgress: Sendable {
    enum Phase: Sendable {
        case preparing
        case stacking
        case writing
    }

    let phase: Phase
    let message: String
    let completedFrames: Int
    let totalFrames: Int
    let acceptedFrames: Int
    let rejectedFrames: Int

    var fractionCompleted: Double? {
        guard totalFrames > 0 else { return nil }
        return min(max(Double(completedFrames) / Double(totalFrames), 0), 1)
    }
}

struct ImageStackResult: Sendable {
    let output: URL
    let acceptedFrames: Int
    let rejectedFrames: Int
    let dispositions: [ImageStackDisposition]
}

struct ImageStackBatchResult: Sendable {
    let results: [ImageStackResult]
    let outputAccessURLs: [URL]

    var acceptedFrames: Int { results.reduce(0) { $0 + $1.acceptedFrames } }
    var rejectedFrames: Int { results.reduce(0) { $0 + $1.rejectedFrames } }
}

private struct ImageStackBatchCancellation: Error {
    let completedOutputs: [URL]
}

private struct ImageStackBatchFailure: LocalizedError {
    let underlying: Error
    let completedOutputs: [URL]

    var errorDescription: String? {
        let saved = completedOutputs.map(\.lastPathComponent).joined(separator: ", ")
        return "\(underlying.localizedDescription) Already saved: \(saved)."
    }
}

enum ImageStackError: LocalizedError {
    case invalidRequest(String)
    case core(String)
    case noAdditionalFrames([ImageStackDisposition])

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message), .core(let message):
            return message
        case .noAdditionalFrames(let dispositions):
            let reason = dispositions.compactMap(\.reason).first
            if let reason {
                return "No frame beyond the reference was accepted. \(reason)"
            } else {
                return "No frame beyond the reference was accepted."
            }
        }
    }
}

final class ImageStackCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.withLock { value }
    }

    func cancel() {
        lock.withLock { value = true }
    }
}

enum ImageStackEngine {
    static func stack(
        request: ImageStackRequest,
        cancellation: ImageStackCancellation,
        progress: @Sendable (ImageStackProgress) -> Void
    ) throws -> ImageStackResult {
        guard request.inputs.count >= 2 else {
            throw ImageStackError.invalidRequest("Choose at least two images to stack.")
        }
        if let message = request.options.validationMessage
            ?? request.calibration.validationMessage(for: request.inputs) {
            throw ImageStackError.invalidRequest(message)
        }
        let inputPaths = Set(
            (request.inputs + [
                request.calibration.bias,
                request.calibration.dark,
                request.calibration.flat,
            ].compactMap { $0 })
                .map { $0.standardizedFileURL.path }
        )
        guard !inputPaths.contains(request.output.standardizedFileURL.path) else {
            throw ImageStackError.invalidRequest(
                "Choose an output file that is not one of the input or calibration files."
            )
        }

        let accessURLs = Set(
            request.inputs + [
                request.calibration.bias,
                request.calibration.dark,
                request.calibration.flat,
                request.output,
                request.outputAccessURL,
            ].compactMap { $0 }
        )
        let accessedURLs = accessURLs.filter { $0.startAccessingSecurityScopedResource() }
        defer { accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }

        if cancellation.isCancelled { throw CancellationError() }
        progress(ImageStackProgress(
            phase: .preparing,
            message: "Opening reference image…",
            completedFrames: 0,
            totalFrames: request.inputs.count,
            acceptedFrames: 0,
            rejectedFrames: 0
        ))

        let optionsJSON = String(decoding: try request.options.jsonData, as: UTF8.self)
        var errorPointer: UnsafeMutablePointer<CChar>?
        var liveStacker: OpaquePointer? = withOptionalCString(request.calibration.bias?.path) { bias in
            withOptionalCString(request.calibration.dark?.path) { dark in
                withOptionalCString(request.calibration.flat?.path) { flat in
                    request.inputs[0].path.withCString { reference in
                        optionsJSON.withCString { options in
                            seiza_live_stacker_open_fits(
                                reference,
                                bias,
                                dark,
                                flat,
                                request.calibration.overridesDarkExposure
                                    ? request.calibration.darkExposureSeconds
                                    : 0,
                                options,
                                &errorPointer
                            )
                        }
                    }
                }
            }
        }
        guard liveStacker != nil else {
            throw ImageStackError.core(takeCABIError(&errorPointer))
        }
        defer {
            if let liveStacker {
                seiza_live_stacker_free(liveStacker)
            }
        }

        var dispositions: [ImageStackDisposition] = []
        var unreadableFrames = 0
        progress(ImageStackProgress(
            phase: .stacking,
            message: request.inputs[0].lastPathComponent,
            completedFrames: 1,
            totalFrames: request.inputs.count,
            acceptedFrames: 1,
            rejectedFrames: 0
        ))

        for (offset, url) in request.inputs.dropFirst().enumerated() {
            if cancellation.isCancelled { throw CancellationError() }
            errorPointer = nil
            let responsePointer = url.path.withCString { path in
                seiza_live_stacker_push_fits_json(liveStacker, path, &errorPointer)
            }
            if let responsePointer {
                defer { seiza_string_free(responsePointer) }
                let data = Data(bytes: responsePointer, count: strlen(responsePointer))
                dispositions.append(try JSONDecoder().decode(
                    ImageStackDisposition.self,
                    from: data
                ))
            } else {
                unreadableFrames += 1
                dispositions.append(ImageStackDisposition(
                    source: url.path,
                    accepted: false,
                    reason: takeCABIError(&errorPointer)
                ))
            }

            let accepted = Int(seiza_live_stacker_accepted_frames(liveStacker))
            let rejected = Int(seiza_live_stacker_rejected_frames(liveStacker))
                + unreadableFrames
            progress(ImageStackProgress(
                phase: .stacking,
                message: url.lastPathComponent,
                completedFrames: offset + 2,
                totalFrames: request.inputs.count,
                acceptedFrames: accepted,
                rejectedFrames: rejected
            ))
        }

        if cancellation.isCancelled { throw CancellationError() }
        guard seiza_live_stacker_accepted_frames(liveStacker) > 1 else {
            throw ImageStackError.noAdditionalFrames(dispositions)
        }
        progress(ImageStackProgress(
            phase: .writing,
            message: "Writing \(request.output.lastPathComponent)…",
            completedFrames: request.inputs.count,
            totalFrames: request.inputs.count,
            acceptedFrames: Int(seiza_live_stacker_accepted_frames(liveStacker)),
            rejectedFrames: Int(seiza_live_stacker_rejected_frames(liveStacker))
                + unreadableFrames
        ))

        errorPointer = nil
        let snapshot = seiza_live_stacker_finish(&liveStacker, &errorPointer)
        guard let snapshot else {
            throw ImageStackError.core(takeCABIError(&errorPointer))
        }
        defer { seiza_stack_snapshot_free(snapshot) }

        if cancellation.isCancelled { throw CancellationError() }
        errorPointer = nil
        let wroteOutput = request.output.path.withCString { path in
            seiza_stack_snapshot_write_fits(snapshot, path, &errorPointer)
        }
        guard wroteOutput else {
            throw ImageStackError.core(takeCABIError(&errorPointer))
        }
        return ImageStackResult(
            output: request.output,
            acceptedFrames: Int(seiza_stack_snapshot_accepted_frames(snapshot)),
            rejectedFrames: Int(seiza_stack_snapshot_rejected_frames(snapshot))
                + unreadableFrames,
            dispositions: dispositions
        )
    }

    private static func withOptionalCString<Result>(
        _ value: String?,
        body: (UnsafePointer<CChar>?) -> Result
    ) -> Result {
        guard let value else { return body(nil) }
        return value.withCString(body)
    }

    private static func takeCABIError(
        _ pointer: inout UnsafeMutablePointer<CChar>?
    ) -> String {
        guard let value = pointer else { return "Seiza returned an invalid stacking response." }
        pointer = nil
        let message = String(cString: value)
        seiza_string_free(value)
        return message
    }
}

enum ImageStackBatchEngine {
    static func stack(
        request: ImageStackBatchRequest,
        cancellation: ImageStackCancellation,
        progress: @Sendable (ImageStackProgress) -> Void
    ) throws -> ImageStackBatchResult {
        guard !request.jobs.isEmpty else {
            throw ImageStackError.invalidRequest("Choose at least one stack group.")
        }
        let totalFrames = request.jobs.reduce(0) { $0 + $1.request.inputs.count }
        var completedFrames = 0
        var acceptedFrames = 0
        var rejectedFrames = 0
        var results: [ImageStackResult] = []

        for job in request.jobs {
            if cancellation.isCancelled {
                throw ImageStackBatchCancellation(
                    completedOutputs: results.map(\.output)
                )
            }
            let prefix = request.jobs.count > 1 ? "\(job.group.title): " : ""
            let completedBeforeJob = completedFrames
            let acceptedBeforeJob = acceptedFrames
            let rejectedBeforeJob = rejectedFrames
            let result: ImageStackResult
            do {
                result = try ImageStackEngine.stack(
                    request: job.request,
                    cancellation: cancellation,
                    progress: { update in
                        progress(ImageStackProgress(
                            phase: update.phase,
                            message: prefix + update.message,
                            completedFrames: completedBeforeJob + update.completedFrames,
                            totalFrames: totalFrames,
                            acceptedFrames: acceptedBeforeJob + update.acceptedFrames,
                            rejectedFrames: rejectedBeforeJob + update.rejectedFrames
                        ))
                    }
                )
            } catch is CancellationError {
                throw ImageStackBatchCancellation(
                    completedOutputs: results.map(\.output)
                )
            } catch {
                guard !results.isEmpty else { throw error }
                throw ImageStackBatchFailure(
                    underlying: error,
                    completedOutputs: results.map(\.output)
                )
            }
            results.append(result)
            completedFrames += job.request.inputs.count
            acceptedFrames += result.acceptedFrames
            rejectedFrames += result.rejectedFrames
        }
        let outputAccessURLs = Array(Set(
            request.jobs.compactMap { $0.request.outputAccessURL }
        ))
        return ImageStackBatchResult(
            results: results,
            outputAccessURLs: outputAccessURLs
        )
    }
}

@MainActor
final class ImageStackCoordinator: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isCancelling = false
    @Published private(set) var progress: ImageStackProgress?
    @Published private(set) var errorMessage: String?
    @Published private(set) var cancellationMessage: String?

    private var cancellation: ImageStackCancellation?
    private var task: Task<Void, Never>?

    func start(
        request: ImageStackBatchRequest,
        onSuccess: @escaping @MainActor (ImageStackBatchResult) -> Void
    ) {
        guard !isRunning else { return }
        let cancellation = ImageStackCancellation()
        self.cancellation = cancellation
        isRunning = true
        isCancelling = false
        errorMessage = nil
        cancellationMessage = nil
        progress = ImageStackProgress(
            phase: .preparing,
            message: "Preparing stack…",
            completedFrames: 0,
            totalFrames: request.jobs.reduce(0) { $0 + $1.request.inputs.count },
            acceptedFrames: 0,
            rejectedFrames: 0
        )

        task = Task { [weak self] in
            let (updates, continuation) = AsyncStream.makeStream(of: ImageStackProgress.self)
            let progressTask = Task { @MainActor [weak self] in
                for await update in updates {
                    self?.progress = update
                }
            }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ImageStackBatchEngine.stack(
                        request: request,
                        cancellation: cancellation,
                        progress: { continuation.yield($0) }
                    )
                }.value
                continuation.finish()
                await progressTask.value
                guard let self else { return }
                self.isRunning = false
                self.cancellation = nil
                self.task = nil
                onSuccess(result)
            } catch let cancellation as ImageStackBatchCancellation {
                continuation.finish()
                await progressTask.value
                guard let self else { return }
                self.isRunning = false
                self.isCancelling = false
                self.cancellation = nil
                self.task = nil
                if cancellation.completedOutputs.isEmpty {
                    self.cancellationMessage = "Stacking was canceled. No output was written."
                } else {
                    let saved = cancellation.completedOutputs
                        .map(\.lastPathComponent)
                        .joined(separator: ", ")
                    self.cancellationMessage = "Stacking was canceled. Already saved: \(saved)."
                }
            } catch {
                continuation.finish()
                await progressTask.value
                guard let self else { return }
                self.isRunning = false
                self.isCancelling = false
                self.cancellation = nil
                self.task = nil
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func cancel() {
        guard isRunning, !isCancelling else { return }
        isCancelling = true
        cancellation?.cancel()
    }
}

struct ImageStackWorkflowView: View {
    let urls: [URL]
    let onComplete: (ImageStackBatchResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var coordinator = ImageStackCoordinator()
    @State private var selectedURLs: Set<URL>
    @State private var referenceURLs: [String: URL] = [:]
    @State private var options = ImageStackOptions()
    @State private var calibration = ImageStackCalibration()
    @State private var splitByFilenameFilter = true
    @State private var outputBaseName = "stacked"
    @State private var showsAdvancedOptions = false
    @State private var showsCalibration = false
    @State private var isChoosingFile = false

    init(urls: [URL], onComplete: @escaping (ImageStackBatchResult) -> Void) {
        precondition(!urls.isEmpty)
        self.urls = urls
        self.onComplete = onComplete
        _selectedURLs = State(initialValue: Set(urls))
    }

    var body: some View {
        VStack(spacing: 0) {
            if coordinator.isRunning {
                progressView
            } else {
                configurationView
            }
        }
        .frame(width: 620, height: 640)
        .interactiveDismissDisabled(coordinator.isRunning)
    }

    private var configurationView: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Stack Images")
                        .font(.title2.weight(.semibold))
                    Text("Align and combine linear FITS or XISF frames.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            Form {
                Section("Frames") {
                    HStack {
                        Text("\(selectedURLs.count) of \(urls.count) selected")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("All") {
                            selectedURLs = Set(urls)
                        }
                        Button("None") {
                            selectedURLs.removeAll()
                        }
                    }

                    List(urls, id: \.self) { url in
                        Toggle(isOn: selectedBinding(for: url)) {
                            Text(url.lastPathComponent)
                                .lineLimit(1)
                        }
                    }
                    .frame(height: 150)

                    if hasMultipleDetectedFilters {
                        Toggle("Split by filename filter", isOn: $splitByFilenameFilter)
                        Text("Recognizes L, R, G, B, Ha, OIII, SII, and H-beta names.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if splitsSelectedFramesByFilter {
                            TextField("Output base name", text: $outputBaseName)
                        }
                    }

                    ForEach(stackGroups) { group in
                        Picker(
                            stackGroups.count == 1 ? "Reference" : "\(group.title) reference",
                            selection: referenceBinding(for: group)
                        ) {
                            ForEach(group.inputs, id: \.self) { url in
                                Text(url.lastPathComponent).tag(url)
                            }
                        }
                        .disabled(group.inputs.isEmpty)
                    }

                    Text(groupSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Each reference sets its filter stack's bounds and alignment coordinates.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Stack") {
                    Picker("Normalization", selection: $options.normalization) {
                        ForEach(StackNormalizationMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    if options.normalization == .local {
                        Picker("Tile size", selection: $options.localTileSize) {
                            ForEach([64, 128, 256, 512], id: \.self) { size in
                                Text("\(size) px").tag(size)
                            }
                        }
                    }

                    Picker("Sample rejection", selection: $options.rejection) {
                        ForEach(StackRejectionMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    if options.rejection == .deltaSigma {
                        LabeledContent("Sigma limits") {
                            HStack {
                                TextField("Low", value: $options.sigmaLow, format: .number)
                                    .frame(width: 70)
                                Text("low")
                                    .foregroundStyle(.secondary)
                                TextField("High", value: $options.sigmaHigh, format: .number)
                                    .frame(width: 70)
                                Text("high")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Stepper(
                            "Warmup frames: \(options.rejectionWarmup)",
                            value: $options.rejectionWarmup,
                            in: 2...100
                        )
                    }
                }

                DisclosureGroup("Calibration Masters", isExpanded: $showsCalibration) {
                    calibrationRow("Bias", selection: $calibration.bias)
                    calibrationRow("Dark", selection: $calibration.dark)
                    calibrationRow("Flat", selection: $calibration.flat)
                    Toggle("Override dark exposure", isOn: $calibration.overridesDarkExposure)
                        .disabled(calibration.dark == nil)
                    if calibration.overridesDarkExposure {
                        TextField(
                            "Dark exposure (seconds)",
                            value: $calibration.darkExposureSeconds,
                            format: .number
                        )
                    }
                }

                DisclosureGroup("Registration Limits", isExpanded: $showsAdvancedOptions) {
                    TextField(
                        "Maximum RMS (pixels)",
                        value: $options.maximumRegistrationRMS,
                        format: .number
                    )
                    TextField(
                        "Drift floor (pixels)",
                        value: $options.maximumDriftPixels,
                        format: .number
                    )
                    TextField(
                        "Maximum drift fraction",
                        value: $options.maximumDriftFraction,
                        format: .number
                    )
                    TextField(
                        "Minimum overlap",
                        value: $options.minimumOverlap,
                        format: .number
                    )
                }

                if let message = setupValidationMessage {
                    Text(message)
                        .foregroundStyle(.red)
                        .font(.callout)
                } else if let message = coordinator.errorMessage {
                    Text(message)
                        .foregroundStyle(.red)
                        .font(.callout)
                } else if let message = coordinator.cancellationMessage {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Choose Output and Stack…") {
                    chooseOutputAndStart()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(setupValidationMessage != nil || isChoosingFile)
            }
            .padding(16)
        }
    }

    private var progressView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 42))
                .foregroundStyle(.tint)
            Text(coordinator.isCancelling ? "Stopping…" : "Stacking Images")
                .font(.title2.weight(.semibold))

            if let progress = coordinator.progress {
                if let fraction = progress.fractionCompleted {
                    ProgressView(value: fraction)
                        .frame(width: 360)
                } else {
                    ProgressView()
                        .controlSize(.large)
                }
                Text(progress.message)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 440)
                Text(
                    "\(progress.completedFrames) of \(progress.totalFrames) frames · "
                    + "\(progress.acceptedFrames) accepted · \(progress.rejectedFrames) rejected"
                )
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(coordinator.isCancelling ? "Stopping…" : "Cancel") {
                coordinator.cancel()
            }
            .disabled(coordinator.isCancelling)
            .keyboardShortcut(.cancelAction)
            .padding(.bottom, 20)
        }
        .padding(28)
    }

    private var selectedFrames: [URL] {
        urls.filter(selectedURLs.contains)
    }

    private var hasMultipleDetectedFilters: Bool {
        ImageStackGrouping.hasMultipleDetectedFilters(in: urls)
    }

    private var stackGroups: [ImageStackGroup] {
        ImageStackGrouping.groups(
            for: selectedFrames,
            splitByFilter: splitsSelectedFramesByFilter
        )
    }

    private var splitsSelectedFramesByFilter: Bool {
        splitByFilenameFilter
            && ImageStackGrouping.hasMultipleDetectedFilters(in: selectedFrames)
    }

    private var groupSummary: String {
        stackGroups.map { "\($0.title): \($0.inputs.count)" }.joined(separator: " · ")
    }

    private var setupValidationMessage: String? {
        guard selectedURLs.count >= 2 else { return "Choose at least two frames." }
        if let group = stackGroups.first(where: { $0.inputs.count < 2 }) {
            return "\(group.title) needs at least two selected frames."
        }
        if splitsSelectedFramesByFilter {
            let baseName = outputBaseName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !baseName.isEmpty, !baseName.contains("/"), !baseName.contains(":") else {
                return "Enter a valid output base name."
            }
        }
        return options.validationMessage ?? calibration.validationMessage(for: selectedFrames)
    }

    private func selectedBinding(for url: URL) -> Binding<Bool> {
        Binding(
            get: { selectedURLs.contains(url) },
            set: { selected in
                if selected {
                    selectedURLs.insert(url)
                } else {
                    selectedURLs.remove(url)
                }
            }
        )
    }

    private func referenceBinding(for group: ImageStackGroup) -> Binding<URL> {
        Binding(
            get: {
                if let reference = referenceURLs[group.id], group.inputs.contains(reference) {
                    return reference
                }
                return group.inputs.first ?? urls[0]
            },
            set: { referenceURLs[group.id] = $0 }
        )
    }

    private func orderedInputs(for group: ImageStackGroup) -> [URL] {
        let reference = referenceBinding(for: group).wrappedValue
        return [reference] + group.inputs.filter { $0 != reference }
    }

    @ViewBuilder
    private func calibrationRow(_ title: String, selection: Binding<URL?>) -> some View {
        LabeledContent(title) {
            HStack {
                Button(selection.wrappedValue?.lastPathComponent ?? "Choose…") {
                    chooseCalibration(selection: selection)
                }
                .lineLimit(1)
                if selection.wrappedValue != nil {
                    Button {
                        selection.wrappedValue = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove \(title.lowercased()) master")
                }
            }
        }
    }

    private func chooseCalibration(selection: Binding<URL?>) {
        isChoosingFile = true
        Task { @MainActor in
            selection.wrappedValue = await StackFilePanels.chooseCalibration(
                directory: urls.first?.deletingLastPathComponent()
            )
            isChoosingFile = false
        }
    }

    private func chooseOutputAndStart() {
        guard setupValidationMessage == nil else { return }
        isChoosingFile = true
        Task { @MainActor in
            let groups = stackGroups
            let outputSelection = await StackFilePanels.chooseOutputs(
                for: groups,
                splitByFilter: splitsSelectedFramesByFilter,
                baseName: outputBaseName.trimmingCharacters(in: .whitespacesAndNewlines),
                directory: urls.first?.deletingLastPathComponent()
            )
            isChoosingFile = false
            guard let outputSelection else { return }
            coordinator.start(
                request: ImageStackBatchRequest(
                    jobs: zip(groups, outputSelection.outputs).map { group, output in
                        ImageStackJob(
                            group: group,
                            request: ImageStackRequest(
                                inputs: orderedInputs(for: group),
                                output: output,
                                outputAccessURL: outputSelection.accessURL,
                                options: options,
                                calibration: calibration
                            )
                        )
                    }
                ),
                onSuccess: { result in
                    dismiss()
                    onComplete(result)
                }
            )
        }
    }
}

@MainActor
private enum StackFilePanels {
    struct OutputSelection {
        let outputs: [URL]
        let accessURL: URL
    }

    static func chooseOutputs(
        for groups: [ImageStackGroup],
        splitByFilter: Bool,
        baseName: String,
        directory: URL?
    ) async -> OutputSelection? {
        if splitByFilter {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.directoryURL = directory
            panel.message = "Choose a folder for the filter stacks."
            panel.prompt = "Choose"
            let outputDirectory: URL? = await withCheckedContinuation { continuation in
                panel.begin { response in
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
            }
            guard let outputDirectory else { return nil }
            let accessedDirectory = outputDirectory.startAccessingSecurityScopedResource()
            defer {
                if accessedDirectory {
                    outputDirectory.stopAccessingSecurityScopedResource()
                }
            }
            let outputs = groups.map { group in
                outputDirectory.appendingPathComponent(
                    "\(baseName)-\(group.filenameSuffix).fits"
                )
            }
            let existing = outputs.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard existing.isEmpty || confirmReplacing(existing) else { return nil }
            return OutputSelection(outputs: outputs, accessURL: outputDirectory)
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.fits]
        panel.canCreateDirectories = true
        panel.directoryURL = directory
        panel.nameFieldStringValue = "stacked.fits"
        panel.message = "Save the unstretched 32-bit floating-point FITS stack."
        panel.prompt = "Stack"
        let baseURL: URL? = await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
        guard let baseURL else { return nil }

        return OutputSelection(outputs: [baseURL], accessURL: baseURL)
    }

    private static func confirmReplacing(_ urls: [URL]) -> Bool {
        let alert = NSAlert()
        alert.messageText = urls.count == 1
            ? "Replace Existing Stack?"
            : "Replace Existing Stacks?"
        alert.informativeText = urls.map(\.lastPathComponent).joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func chooseCalibration(directory: URL?) async -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.fits, .xisf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = directory
        panel.message = "Choose an integrated calibration master."
        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
}
