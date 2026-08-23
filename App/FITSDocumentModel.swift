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
    let background: FITSBackgroundConfiguration?
    let deconvolution: FITSDeconvolutionConfiguration?
}

struct FITSLinearProcessingHistory: Equatable {
    private(set) var current: FITSLinearProcessingState
    private var undoStates = [FITSLinearProcessingState]()
    private var redoStates = [FITSLinearProcessingState]()

    init(
        background: FITSBackgroundConfiguration?,
        deconvolution: FITSDeconvolutionConfiguration?
    ) {
        current = FITSLinearProcessingState(
            background: background,
            deconvolution: deconvolution
        )
    }

    mutating func commit(
        background: FITSBackgroundConfiguration?,
        deconvolution: FITSDeconvolutionConfiguration?
    ) {
        undoStates.append(current)
        current = FITSLinearProcessingState(
            background: background,
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

    let url: URL
    @Published private(set) var loadState: LoadState = .loading
    @Published private(set) var solveState: SolveState = .idle
    @Published private(set) var starAnalysisState: StarAnalysisState = .idle
    @Published private(set) var previewImage: CGImage?
    @Published private(set) var image: CGImage?
    @Published private(set) var metadata: ImageMetadata?
    @Published private(set) var stretchHistory: FITSStretchHistory
    @Published private(set) var linearProcessingHistory: FITSLinearProcessingHistory
    @Published private(set) var isPreviewRendering = false
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
        processingConfiguration: FITSImageProcessingConfiguration = .default,
        stretchHistory carriedStretchHistory: FITSStretchHistory? = nil,
        linearProcessingHistory carriedLinearProcessingHistory: FITSLinearProcessingHistory? = nil
    ) {
        self.url = url
        let processingConfiguration = FITSImageProcessingConfiguration(
            stretchStack: processingConfiguration.stretchStack,
            backgroundConfiguration: processingConfiguration.backgroundConfiguration,
            deconvolution: processingConfiguration.deconvolution
        )
        if let carriedStretchHistory {
            precondition(
                carriedStretchHistory.stack == processingConfiguration.stretchStack,
                "Carried stretch history must match the current processing recipe"
            )
            stretchHistory = carriedStretchHistory
        } else {
            stretchHistory = FITSStretchHistory(stack: processingConfiguration.stretchStack)
        }
        if let carriedLinearProcessingHistory {
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
                deconvolution: processingConfiguration.deconvolution
            )
        }
        let processing = processingConfiguration
        previewImage = ImageThumbnailCache.memoryImage(
            for: url,
            processing: processing
        )
        if previewImage == nil {
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
            deconvolution: deconvolutionConfiguration
        )
    }

    private func recordProcessingChange(
        background: FITSBackgroundConfiguration?,
        deconvolution: FITSDeconvolutionConfiguration?
    ) {
        var history = linearProcessingHistory
        history.commit(background: background, deconvolution: deconvolution)
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
            deconvolution: deconvolution
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
            deconvolution: deconvolution
        )
        load()
    }

    func replaceStretchStack(
        with stack: FITSStretchStack,
        backgroundConfiguration: FITSBackgroundConfiguration?,
        deconvolution: FITSDeconvolutionConfiguration? = nil
    ) {
        guard
            stack.stages.allSatisfy({ $0.validationMessage == nil }),
            backgroundConfiguration?.validationMessage == nil,
            deconvolution?.validationMessage == nil
        else { return }
        let hasChanges = stretchHistory.stack != stack
            || self.backgroundConfiguration != backgroundConfiguration
            || deconvolutionConfiguration != deconvolution
        let requestedProcessing = FITSImageProcessingConfiguration(
            stretchStack: stack,
            backgroundConfiguration: backgroundConfiguration,
            deconvolution: deconvolution
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
            deconvolution: deconvolution
        )
        if let refinedPreview {
            loadGeneration &+= 1
            commit(refinedPreview)
        } else {
            load()
        }
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
        let requestedProcessing = FITSImageProcessingConfiguration(
            stretchStack: stretchStack,
            backgroundConfiguration: backgroundConfiguration,
            deconvolution: deconvolution
        )
        guard requestedProcessing != processingConfiguration else {
            cancelPreview()
            return
        }
        let responsiveProcessing = FITSImageProcessingConfiguration(
            stretchStack: stretchStack,
            backgroundConfiguration: backgroundConfiguration,
            deconvolution: deconvolution,
            interactivePreview: true
        )
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
        previewError = nil
        previewRenderer.render(
            url: url,
            responsiveProcessing: responsiveProcessing,
            fullResolutionProcessing: requestedProcessing,
            plan: renderPlan
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
                self.commit(rendered)
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
