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

    let url: URL
    @Published private(set) var loadState: LoadState = .loading
    @Published private(set) var solveState: SolveState = .idle
    @Published private(set) var previewImage: CGImage?
    @Published private(set) var image: CGImage?
    @Published private(set) var metadata: ImageMetadata?
    @Published private(set) var stretchHistory: FITSStretchHistory
    @Published private(set) var extractsBackground = false
    @Published private(set) var deconvolutionConfiguration: FITSDeconvolutionConfiguration?
    @Published private(set) var isPreviewRendering = false
    @Published private(set) var previewError: String?
    private var loadGeneration = 0
    private var previewGeneration = 0
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
        stretchHistory carriedStretchHistory: FITSStretchHistory? = nil
    ) {
        self.url = url
        let processingConfiguration = FITSImageProcessingConfiguration(
            stretchStack: processingConfiguration.stretchStack,
            extractsBackground: processingConfiguration.extractsBackground,
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
        extractsBackground = processingConfiguration.extractsBackground
        deconvolutionConfiguration = processingConfiguration.deconvolution
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

    var supportsFITSStretch: Bool {
        metadata?.format == "FITS"
    }

    var supportsColorStretch: Bool {
        guard let colorKind = metadata?.colorKind else { return false }
        return colorKind == "planar-rgb" || colorKind == "bayer"
    }

    var stretchConfiguration: FITSStretchConfiguration {
        stretchHistory.current
    }

    var processingConfiguration: FITSImageProcessingConfiguration {
        FITSImageProcessingConfiguration(
            stretchStack: stretchHistory.stack,
            extractsBackground: extractsBackground,
            deconvolution: deconvolutionConfiguration
        )
    }

    var exportImage: CGImage? {
        committedImage ?? image
    }

    var fullResolutionDisplayImage: CGImage? {
        fullResolutionPreview?.rendered.image ?? committedImage ?? image
    }

    func addStretch(
        _ configuration: FITSStretchConfiguration,
        extractsBackground: Bool,
        deconvolution: FITSDeconvolutionConfiguration? = nil
    ) {
        guard
            configuration.validationMessage == nil,
            deconvolution?.validationMessage == nil
        else { return }
        cancelPreview()
        var history = stretchHistory
        history.apply(configuration)
        stretchHistory = history
        self.extractsBackground = extractsBackground
        deconvolutionConfiguration = deconvolution
        load()
    }

    func updateCurrentStretch(
        _ configuration: FITSStretchConfiguration,
        extractsBackground: Bool,
        deconvolution: FITSDeconvolutionConfiguration? = nil
    ) {
        guard
            configuration.validationMessage == nil,
            deconvolution?.validationMessage == nil
        else { return }
        cancelPreview()
        var history = stretchHistory
        history.updateCurrent(configuration)
        stretchHistory = history
        self.extractsBackground = extractsBackground
        deconvolutionConfiguration = deconvolution
        load()
    }

    func replaceStretchStack(
        with stack: FITSStretchStack,
        extractsBackground: Bool,
        deconvolution: FITSDeconvolutionConfiguration? = nil
    ) {
        guard
            stack.stages.allSatisfy({ $0.validationMessage == nil }),
            deconvolution?.validationMessage == nil
        else { return }
        let hasChanges = stretchHistory.stack != stack
            || self.extractsBackground != extractsBackground
            || deconvolutionConfiguration != deconvolution
        let requestedProcessing = FITSImageProcessingConfiguration(
            stretchStack: stack,
            extractsBackground: extractsBackground,
            deconvolution: deconvolution
        )
        let refinedPreview = fullResolutionPreview.flatMap { preview in
            preview.processing == requestedProcessing ? preview.rendered : nil
        }
        cancelPreview()
        guard hasChanges else { return }
        var history = stretchHistory
        history.replaceStack(with: stack.stages)
        stretchHistory = history
        self.extractsBackground = extractsBackground
        deconvolutionConfiguration = deconvolution
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
        stretchHistory = history
        load()
    }

    func redoStretch() {
        cancelPreview()
        var history = stretchHistory
        guard history.redo() else { return }
        stretchHistory = history
        load()
    }

    func preview(
        stretchStack: FITSStretchStack,
        extractsBackground: Bool,
        deconvolution: FITSDeconvolutionConfiguration? = nil,
        zoom: Double = 1,
        displayScale: Double = 1
    ) {
        guard
            stretchStack.stages.allSatisfy({ $0.validationMessage == nil }),
            deconvolution?.validationMessage == nil
        else {
            cancelPreview()
            return
        }
        let requestedProcessing = FITSImageProcessingConfiguration(
            stretchStack: stretchStack,
            extractsBackground: extractsBackground,
            deconvolution: deconvolution
        )
        guard requestedProcessing != processingConfiguration else {
            cancelPreview()
            return
        }
        let responsiveProcessing = FITSImageProcessingConfiguration(
            stretchStack: stretchStack,
            extractsBackground: extractsBackground,
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
