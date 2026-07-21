import CoreGraphics
import Foundation

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
    @Published private(set) var isPreviewRendering = false
    @Published private(set) var previewError: String?
    private var loadGeneration = 0
    private var previewGeneration = 0
    private var committedImage: CGImage?
    private var committedMetadata: ImageMetadata?
    private let previewRenderer = LatestImagePreviewRenderer()

    init(
        url: URL,
        stretchConfiguration: FITSStretchConfiguration = .default
    ) {
        self.url = url
        stretchHistory = FITSStretchHistory(base: stretchConfiguration)
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
            extractsBackground: extractsBackground
        )
    }

    var exportImage: CGImage? {
        committedImage ?? image
    }

    func addStretch(
        _ configuration: FITSStretchConfiguration,
        extractsBackground: Bool
    ) {
        guard configuration.validationMessage == nil else { return }
        cancelPreview()
        var history = stretchHistory
        history.apply(configuration)
        stretchHistory = history
        self.extractsBackground = extractsBackground
        load()
    }

    func updateCurrentStretch(
        _ configuration: FITSStretchConfiguration,
        extractsBackground: Bool
    ) {
        guard configuration.validationMessage == nil else { return }
        cancelPreview()
        var history = stretchHistory
        history.updateCurrent(configuration)
        stretchHistory = history
        self.extractsBackground = extractsBackground
        load()
    }

    func replaceStretchStack(
        with configuration: FITSStretchConfiguration,
        extractsBackground: Bool
    ) {
        guard configuration.validationMessage == nil else { return }
        cancelPreview()
        var history = stretchHistory
        history.replace(with: configuration)
        stretchHistory = history
        self.extractsBackground = extractsBackground
        load()
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
        extractsBackground: Bool
    ) {
        guard stretchStack.stages.allSatisfy({ $0.validationMessage == nil }) else {
            cancelPreview()
            return
        }
        let requestedProcessing = FITSImageProcessingConfiguration(
            stretchStack: stretchStack,
            extractsBackground: extractsBackground
        )
        guard requestedProcessing != processingConfiguration else {
            cancelPreview()
            return
        }
        let processing = FITSImageProcessingConfiguration(
            stretchStack: stretchStack,
            extractsBackground: extractsBackground,
            interactivePreview: true
        )

        previewGeneration &+= 1
        let generation = previewGeneration
        isPreviewRendering = true
        previewError = nil
        previewRenderer.render(
            url: url,
            processing: processing,
            maxDimension: 2_048
        ) { [weak self] result in
            guard let self, self.previewGeneration == generation else { return }
            self.isPreviewRendering = false
            switch result {
            case .success(let rendered):
                self.image = rendered.image
                self.metadata = rendered.metadata
                self.loadState = .loaded
            case .failure(let error):
                self.previewError = error.localizedDescription
            }
        }
    }

    func cancelPreview() {
        previewGeneration &+= 1
        previewRenderer.cancel()
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
                self.image = rendered.image
                self.committedImage = rendered.image
                self.previewImage = nil
                self.metadata = rendered.metadata
                self.committedMetadata = rendered.metadata
                self.loadState = .loaded
            case .failure(let error):
                self.loadState = .failed(error.localizedDescription)
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
