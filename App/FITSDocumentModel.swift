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
    @Published private(set) var stretchConfiguration: FITSStretchConfiguration
    private var loadGeneration = 0

    init(
        url: URL,
        stretchConfiguration: FITSStretchConfiguration = .default
    ) {
        self.url = url
        self.stretchConfiguration = stretchConfiguration
        previewImage = ImageThumbnailCache.memoryImage(
            for: url,
            stretchConfiguration: stretchConfiguration
        )
        if previewImage == nil {
            ImageThumbnailCache.load(
                for: url,
                stretchConfiguration: stretchConfiguration
            ) { [weak self] image in
                guard let image else { return }
                DispatchQueue.main.async {
                    guard
                        let self,
                        self.image == nil,
                        self.stretchConfiguration == stretchConfiguration
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

    func setStretchConfiguration(_ configuration: FITSStretchConfiguration) {
        guard configuration.validationMessage == nil,
              configuration != stretchConfiguration else { return }
        stretchConfiguration = configuration
        load()
    }

    func load() {
        loadGeneration &+= 1
        let generation = loadGeneration
        loadState = .loading
        let url = url
        let stretchConfiguration = stretchConfiguration
        ImageRenderQueue.renderFull(
            url: url,
            stretchConfiguration: stretchConfiguration
        ) { [weak self] result in
            guard let self, self.loadGeneration == generation else { return }
            switch result {
            case .success(let rendered):
                self.image = rendered.image
                self.previewImage = nil
                self.metadata = rendered.metadata
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
