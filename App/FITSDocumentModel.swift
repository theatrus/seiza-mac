import CoreGraphics
import Foundation

struct ImagePreviewRenderPlan: Equatable {
    static let baselineMaxDimension = 2_048

    let responsiveMaxDimension: UInt32
    let needsFullResolutionRefinement: Bool

    static func make(
        sourceWidth: Int?,
        sourceHeight: Int?,
        zoom: Double,
        displayScale: Double
    ) -> Self {
        guard
            let sourceWidth,
            let sourceHeight,
            sourceWidth > 0,
            sourceHeight > 0
        else {
            return Self(
                responsiveMaxDimension: UInt32(baselineMaxDimension),
                needsFullResolutionRefinement: true
            )
        }

        let sourceMaxDimension = min(max(sourceWidth, sourceHeight), Int(UInt32.max))
        let visiblePixels = Double(sourceMaxDimension)
            * max(zoom, 0)
            * max(displayScale, 1)
        let requestedDimension = max(
            baselineMaxDimension,
            Int(ceil(visiblePixels.isFinite ? visiblePixels : 0))
        )

        guard requestedDimension < sourceMaxDimension else {
            return Self(
                responsiveMaxDimension: 0,
                needsFullResolutionRefinement: false
            )
        }

        return Self(
            responsiveMaxDimension: UInt32(
                min(requestedDimension, Int(UInt32.max))
            ),
            needsFullResolutionRefinement: true
        )
    }
}

struct FITSLinearProcessingState: Equatable {
    var ai: AIProcessing? = nil
    let background: FITSBackgroundConfiguration?
    let deconvolution: FITSDeconvolutionConfiguration?
}

struct FITSLinearProcessingHistory: Equatable {
    private(set) var current: FITSLinearProcessingState
    private var undoStates = [FITSLinearProcessingState]()
    private var redoStates = [FITSLinearProcessingState]()

    init(
        background: FITSBackgroundConfiguration?,
        deconvolution: FITSDeconvolutionConfiguration?,
        ai: AIProcessing? = nil
    ) {
        current = FITSLinearProcessingState(
            ai: ai, background: background,
            deconvolution: deconvolution
        )
    }

    mutating func commit(
        background: FITSBackgroundConfiguration?,
        deconvolution: FITSDeconvolutionConfiguration?,
        ai: AIProcessing? = nil
    ) {
        undoStates.append(current)
        current = FITSLinearProcessingState(
            ai: ai, background: background,
            deconvolution: deconvolution
        )
        redoStates.removeAll()
    }

    mutating func undoAligned() {
        let previous = undoStates.popLast() ?? current
        redoStates.append(current)
        current = previous
    }

    mutating func redoAligned() {
        let next = redoStates.popLast() ?? current
        undoStates.append(current)
        current = next
    }
}

final class ImageDocumentModel: ObservableObject {
    enum LoadState {
        case loading
        case loaded
        case failed(String)
    }

    enum SolveState {
        case idle
        case solving
        case solved(SolveResult)
        case failed(String)
    }

    enum StarAnalysisState {
        case idle
        case analyzing
        case analyzed(StarAnalysisOverlayModel)
        case failed(String)

        var overlayModel: StarAnalysisOverlayModel? {
            if case .analyzed(let model) = self { return model }
            return nil
        }
    }

    enum FlatInspectionState {
        case idle, inspecting
        case inspected(FlatInspection)
        case failed(String)
    }

    let url: URL
    @Published var processingNotice: String?
    private var restoringRecipe = false
    @Published private(set) var frameProbe: CalibrationFrameProbe?
    @Published private(set) var flatInspectionState: FlatInspectionState = .idle
    @Published var flatInspectionOptions: FlatQualityOptions = {
        var options = FlatQualityOptions(); options.enabled = true; return options
    }()
    var flatIsInspecting: Bool {
        if case .inspecting = flatInspectionState { return true }
        return false
    }
    private var flatInspectionGeneration = 0
    @Published private(set) var loadState: LoadState = .loading
    @Published private(set) var solveState: SolveState = .idle
    @Published private(set) var starAnalysisState: StarAnalysisState = .idle
    @Published private(set) var previewImage: CGImage?
    @Published private(set) var image: CGImage?
    @Published private(set) var metadata: ImageMetadata?
    @Published private(set) var stretchHistory: FITSStretchHistory
    @Published private(set) var linearProcessingHistory: FITSLinearProcessingHistory
    @Published private(set) var isPreviewRendering = false
    @Published private(set) var previewProgress: String?
    @Published private(set) var previewError: String?
    private var loadGeneration = 0
    private var previewGeneration = 0
    private var starAnalysisGeneration = 0
    private var committedImage: CGImage?
    private var committedMetadata: ImageMetadata?
    private var fullResolutionPreview: (
        processing: FITSImageProcessingConfiguration,
        rendered: RenderedImage
    )?
    private let previewRenderer = LatestImagePreviewRenderer()

    init(
        url: URL,
        processingConfiguration: FITSImageProcessingConfiguration? = nil,
        stretchHistory carriedStretchHistory: FITSStretchHistory? = nil,
        linearProcessingHistory carriedLinearProcessingHistory: FITSLinearProcessingHistory? = nil
    ) {
        self.url = url
        var saved: FITSImageProcessingConfiguration?
        var readError: String?
        if ImageCollection.isStackableImage(url) {
            do {
                saved = try ProcessingRecipe.read(for: url)
                if saved?.ai != nil && !AIRestoration.supported {
                    throw SeizaCoreError.message("AI noise reduction requires Apple silicon.")
                }
            } catch {
                saved = nil
                readError = error.localizedDescription
            }
        }
        let processingConfiguration = saved ?? (readError == nil ? processingConfiguration : nil)
            ?? SeizaCore.initialProcessing(for: url)
        if let carriedStretchHistory, saved == nil, readError == nil {
            precondition(
                carriedStretchHistory.stack == processingConfiguration.stretchStack,
                "Carried stretch history must match the current processing recipe"
            )
            stretchHistory = carriedStretchHistory
        } else {
            stretchHistory = FITSStretchHistory(stack: processingConfiguration.stretchStack)
        }
        if let carriedLinearProcessingHistory, saved == nil, readError == nil {
            precondition(
                carriedLinearProcessingHistory.current.background
                    == processingConfiguration.backgroundConfiguration
                    && carriedLinearProcessingHistory.current.deconvolution
                    == processingConfiguration.deconvolution,
                "Carried linear processing history must match the current processing recipe"
            )
            linearProcessingHistory = carriedLinearProcessingHistory
        } else {
            linearProcessingHistory = FITSLinearProcessingHistory(
                background: processingConfiguration.backgroundConfiguration,
                deconvolution: processingConfiguration.deconvolution, ai: processingConfiguration.ai
            )
        }
        restoringRecipe = saved != nil
        processingNotice = readError.map { "Opened with default processing. " + $0 }
        let processing = processingConfiguration
        previewImage = ImageThumbnailCache.memoryImage(
            for: url,
            processing: processing
        )
        if previewImage == nil, processing.ai == nil {
            ImageThumbnailCache.load(
                for: url,
                processing: processing
            ) { [weak self] image in
                guard let image else { return }
                DispatchQueue.main.async {
                    guard
                        let self,
                        self.image == nil,
                        self.processingConfiguration == processing
                    else { return }
                    self.previewImage = image
                }
            }
        }
        load()
        loadFrameProbe()
    }

    private func loadFrameProbe() {
        guard ImageCollection.isStackableImage(url) else { return }
        let url = url
        Task { @MainActor [weak self] in
            let probe = await Task.detached(priority: .utility) {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                return try? CalibrationService.probe(path: url.path)
            }.value
            self?.frameProbe = probe
        }
    }

    /// Measure the linear file, independent of stretch and other viewer edits.
    func inspectFlat(options: FlatQualityOptions) {
        flatInspectionGeneration &+= 1
        let generation = flatInspectionGeneration
        flatInspectionState = .inspecting
        let url = url
        Task { @MainActor [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try FlatInspectionService.inspect(url, options: options) }
            }.value
            guard let self, self.flatInspectionGeneration == generation else { return }
            switch outcome {
            case .success(let result): self.flatInspectionState = .inspected(result)
            case .failure(let error): self.flatInspectionState = .failed(error.localizedDescription)
            }
        }
    }

    var supportsAstronomyProcessing: Bool {
        guard let format = metadata?.format else { return false }
        return format == "FITS" || format == "XISF"
    }

    var supportsColorStretch: Bool {
        guard let colorKind = metadata?.colorKind else { return false }
        return colorKind == "planar-rgb" || colorKind == "bayer"
    }

    var stretchConfiguration: FITSStretchConfiguration {
        stretchHistory.current
    }

    var extractsBackground: Bool {
        backgroundConfiguration != nil
    }

    var backgroundConfiguration: FITSBackgroundConfiguration? {
        linearProcessingHistory.current.background
    }

    var deconvolutionConfiguration: FITSDeconvolutionConfiguration? {
        linearProcessingHistory.current.deconvolution
    }

    var processingConfiguration: FITSImageProcessingConfiguration {
        FITSImageProcessingConfiguration(
            stretchStack: stretchHistory.stack,
            backgroundConfiguration: backgroundConfiguration,
            deconvolution: deconvolutionConfiguration, ai: linearProcessingHistory.current.ai
        )
    }

    private func recordProcessingChange(
        background: FITSBackgroundConfiguration?,
        deconvolution: FITSDeconvolutionConfiguration?, ai: AIProcessing?
    ) {
        var history = linearProcessingHistory
        history.commit(background: background, deconvolution: deconvolution, ai: ai)
        linearProcessingHistory = history
    }

    var exportImage: CGImage? {
        committedImage ?? image
    }

    var fullResolutionDisplayImage: CGImage? {
        fullResolutionPreview?.rendered.image ?? committedImage ?? image
    }

    func addStretch(
        _ configuration: FITSStretchConfiguration,
        backgroundConfiguration: FITSBackgroundConfiguration?,
        deconvolution: FITSDeconvolutionConfiguration? = nil
    ) {
        guard
            configuration.validationMessage == nil,
            backgroundConfiguration?.validationMessage == nil,
            deconvolution?.validationMessage == nil
        else { return }
        cancelPreview()
        var history = stretchHistory
        history.apply(configuration)
        stretchHistory = history
        recordProcessingChange(
            background: backgroundConfiguration,
            deconvolution: deconvolution, ai: linearProcessingHistory.current.ai
        )
        load()
    }

    func updateCurrentStretch(
        _ configuration: FITSStretchConfiguration,
        backgroundConfiguration: FITSBackgroundConfiguration?,
        deconvolution: FITSDeconvolutionConfiguration? = nil
    ) {
        guard
            configuration.validationMessage == nil,
            backgroundConfiguration?.validationMessage == nil,
            deconvolution?.validationMessage == nil
        else { return }
        cancelPreview()
        var history = stretchHistory
        history.updateCurrent(configuration)
        stretchHistory = history
        recordProcessingChange(
            background: backgroundConfiguration,
            deconvolution: deconvolution, ai: linearProcessingHistory.current.ai
        )
        load()
    }

    func replaceStretchStack(
        with stack: FITSStretchStack,
        backgroundConfiguration: FITSBackgroundConfiguration?,
        deconvolution: FITSDeconvolutionConfiguration? = nil,
        ai: AIProcessing? = nil
    ) {
        guard
            stack.stages.allSatisfy({ $0.validationMessage == nil }),
            backgroundConfiguration?.validationMessage == nil,
            deconvolution?.validationMessage == nil
        else { return }
        let hasChanges = stretchHistory.stack != stack || linearProcessingHistory.current.ai != ai
            || self.backgroundConfiguration != backgroundConfiguration
            || deconvolutionConfiguration != deconvolution
        let requestedProcessing = FITSImageProcessingConfiguration(
            stretchStack: stack,
            backgroundConfiguration: backgroundConfiguration,
            deconvolution: deconvolution, ai: ai
        )
        let refinedPreview = fullResolutionPreview.flatMap { preview in
            preview.processing == requestedProcessing ? preview.rendered : nil
        }
        cancelPreview()
        guard hasChanges else { return }
        var history = stretchHistory
        if history.stack == stack {
            history.checkpoint()
        } else {
            history.replaceStack(with: stack.stages)
        }
        stretchHistory = history
        recordProcessingChange(
            background: backgroundConfiguration,
            deconvolution: deconvolution, ai: ai
        )
        if let refinedPreview {
            loadGeneration &+= 1
            commit(refinedPreview)
        } else {
            load()
        }
    }

    @MainActor
    func applyAndSave(_ recipe: FITSImageProcessingConfiguration) async throws {
        // Validate the full image before replacing a previously usable sidecar.
        // Rectangle previews are never eligible for promotion to the committed image.
        if recipe.ai != nil, fullResolutionPreview?.processing != recipe {
            cancelPreview()
            let signal = AICancellation()
            let source = url
            let rendered = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try SeizaCore.render(url: source, processing: recipe, cancel: signal)
                }.value
            } onCancel: { signal.cancel() }
            try Task.checkCancellation()
            fullResolutionPreview = (recipe, rendered)
        }
        replaceStretchStack(with: recipe.stretchStack, backgroundConfiguration: recipe.backgroundConfiguration,
                            deconvolution: recipe.deconvolution, ai: recipe.ai)
        saveProcessing()
    }

    /// The only document action that creates or replaces a processing sidecar.
    @MainActor func saveProcessing() {
        do { try ProcessingRecipe(processingConfiguration).save(beside: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(error.code) {
            do {
                try ProcessingRecipe.grantSaveAccess(for: url)
                try ProcessingRecipe(processingConfiguration).save(beside: url)
            } catch {
                processingNotice = "The settings are applied in this window, but could not be saved. " + error.localizedDescription
            }
        }
        catch { processingNotice = "The settings are applied in this window, but could not be saved. " + error.localizedDescription }
    }

    func undoStretch() {
        cancelPreview()
        var history = stretchHistory
        guard history.undo() else { return }
        var processingHistory = linearProcessingHistory
        processingHistory.undoAligned()
        stretchHistory = history
        linearProcessingHistory = processingHistory
        load()
    }

    func redoStretch() {
        cancelPreview()
        var history = stretchHistory
        guard history.redo() else { return }
        var processingHistory = linearProcessingHistory
        processingHistory.redoAligned()
        stretchHistory = history
        linearProcessingHistory = processingHistory
        load()
    }

    func preview(
        stretchStack: FITSStretchStack,
        backgroundConfiguration: FITSBackgroundConfiguration?,
        deconvolution: FITSDeconvolutionConfiguration? = nil,
        ai: AIProcessing? = nil, region: AIRegion? = nil,
        zoom: Double = 1,
        displayScale: Double = 1
    ) {
        guard
            stretchStack.stages.allSatisfy({ $0.validationMessage == nil }),
            backgroundConfiguration?.validationMessage == nil,
            deconvolution?.validationMessage == nil
        else {
            cancelPreview()
            return
        }
        var requestedProcessing = FITSImageProcessingConfiguration(
            stretchStack: stretchStack,
            backgroundConfiguration: backgroundConfiguration,
            deconvolution: deconvolution, ai: ai
        )
        requestedProcessing.previewRegion = ai == nil ? nil : region
        guard requestedProcessing != processingConfiguration else {
            cancelPreview()
            return
        }
        var responsiveProcessing = FITSImageProcessingConfiguration(
            stretchStack: stretchStack,
            backgroundConfiguration: backgroundConfiguration,
            deconvolution: deconvolution,
            ai: ai, interactivePreview: true
        )
        responsiveProcessing.previewRegion = requestedProcessing.previewRegion
        let renderPlan = ImagePreviewRenderPlan.make(
            sourceWidth: metadata?.width,
            sourceHeight: metadata?.height,
            zoom: zoom,
            displayScale: displayScale
        )

        previewGeneration &+= 1
        let generation = previewGeneration
        fullResolutionPreview = nil
        isPreviewRendering = true
        previewProgress = nil
        previewError = nil
        previewRenderer.render(
            url: url,
            responsiveProcessing: responsiveProcessing,
            fullResolutionProcessing: requestedProcessing,
            plan: renderPlan,
            progress: { [weak self] message in
                DispatchQueue.main.async {
                    guard let self, self.previewGeneration == generation, self.isPreviewRendering else { return }
                    self.previewProgress = message
                }
            }
        ) { [weak self] pass, result in
            guard let self, self.previewGeneration == generation else { return }
            if pass == .fullResolution {
                self.isPreviewRendering = false
            }
            switch result {
            case .success(let rendered):
                self.previewError = nil
                self.image = rendered.image
                self.metadata = rendered.metadata
                self.loadState = .loaded
                if pass == .fullResolution {
                    self.fullResolutionPreview = (requestedProcessing, rendered)
                }
            case .failure(let error):
                self.previewError = error.localizedDescription
            }
        }
    }

    func cancelPreview() {
        previewGeneration &+= 1
        previewRenderer.cancel()
        fullResolutionPreview = nil
        isPreviewRendering = false
        previewProgress = nil
        previewError = nil
        if let committedImage {
            image = committedImage
            metadata = committedMetadata
            loadState = .loaded
        }
    }

    func load() {
        previewGeneration &+= 1
        previewRenderer.cancel()
        fullResolutionPreview = nil
        isPreviewRendering = false
        previewProgress = nil
        previewError = nil
        loadGeneration &+= 1
        let generation = loadGeneration
        loadState = .loading
        let url = url
        let processing = processingConfiguration
        ImageRenderQueue.renderFull(
            url: url,
            processing: processing
        ) { [weak self] result in
            guard let self, self.loadGeneration == generation else { return }
            switch result {
            case .success(let rendered):
                self.restoringRecipe = false
                self.commit(rendered)
            case .failure(let error) where self.restoringRecipe:
                self.restoringRecipe = false
                self.processingNotice = "Opened with default processing. " + error.localizedDescription
                let fallback = SeizaCore.initialProcessing(for: url)
                self.stretchHistory = FITSStretchHistory(stack: fallback.stretchStack)
                self.linearProcessingHistory = FITSLinearProcessingHistory(background: nil, deconvolution: nil)
                self.load()
            case .failure(let error):
                self.loadState = .failed(error.localizedDescription)
            }
        }
    }

    private func commit(_ rendered: RenderedImage) {
        image = rendered.image
        committedImage = rendered.image
        previewImage = nil
        metadata = rendered.metadata
        committedMetadata = rendered.metadata
        loadState = .loaded
    }

    /// Measures stars and sensor tilt in the linear source image. Explicit
    /// only; a stale result from an earlier request or an edited document is
    /// discarded by the generation guard.
    func analyzeStars() {
        starAnalysisGeneration &+= 1
        let generation = starAnalysisGeneration
        starAnalysisState = .analyzing
        let url = url
        let expectedWidth = metadata?.width
        let expectedHeight = metadata?.height
        Task { @MainActor [weak self] in
            let accessingFile = url.startAccessingSecurityScopedResource()
            defer {
                if accessingFile { url.stopAccessingSecurityScopedResource() }
            }
            let outcome: Result<StarAnalysisResult, Error>
            do {
                let result = try await StarAnalysisService.shared.analyze(
                    path: url.path,
                    options: .interactiveDefault)
                outcome = .success(result)
            } catch {
                outcome = .failure(error)
            }
            guard let self, self.starAnalysisGeneration == generation else { return }
            switch outcome {
            case .success(let result):
                if let expectedWidth, let expectedHeight,
                    result.width != expectedWidth || result.height != expectedHeight {
                    self.starAnalysisState = .failed(
                        "Star analysis returned \(result.width) × \(result.height) "
                            + "for a \(expectedWidth) × \(expectedHeight) source image.")
                } else {
                    self.starAnalysisState = .analyzed(
                        StarAnalysisOverlayModel(result: result))
                }
            case .failure(is CancellationError):
                if case .analyzing = self.starAnalysisState {
                    self.starAnalysisState = .idle
                }
            case .failure(let error):
                self.starAnalysisState = .failed(error.localizedDescription)
            }
        }
    }

    func adoptParallaxSolution(_ solution: SolveResult) {
        // A solve requested in the viewer keeps precedence over a background
        // solve from a video window for the same original file.
        switch solveState {
        case .solving, .solved: return
        default: solveState = .solved(solution)
        }
    }

    func solve(catalogDirectory: URL?) {
        solveState = .solving
        let url = url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let accessingFile = url.startAccessingSecurityScopedResource()
            let accessingCatalog = catalogDirectory?.startAccessingSecurityScopedResource() ?? false
            defer {
                if accessingFile { url.stopAccessingSecurityScopedResource() }
                if accessingCatalog { catalogDirectory?.stopAccessingSecurityScopedResource() }
            }
            let result = Result {
                let catalogStatus = try SeizaCore.catalogStatus(
                    catalogDirectory: catalogDirectory
                )
                guard catalogStatus.readyForSolving else {
                    throw SeizaCoreError.message(
                        "Catalog setup is required before plate solving. Open Catalog Settings to download and verify the standard blind-solving package in \(catalogStatus.directory)."
                    )
                }
                return try SeizaCore.solve(
                    url: url,
                    catalogDirectory: catalogDirectory
                )
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let solution): self.solveState = .solved(solution)
                case .failure(let error): self.solveState = .failed(error.localizedDescription)
                }
            }
        }
    }
}
