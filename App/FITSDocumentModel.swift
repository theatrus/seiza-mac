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
    @Published private(set) var rgbStretchMode: RGBStretchMode
    private var loadGeneration = 0

    init(url: URL, rgbStretchMode: RGBStretchMode = .auto) {
        self.url = url
        self.rgbStretchMode = rgbStretchMode
        previewImage = ImageThumbnailCache.memoryImage(
            for: url,
            rgbStretchMode: rgbStretchMode
        )
        if previewImage == nil {
            ImageThumbnailCache.load(
                for: url,
                rgbStretchMode: rgbStretchMode
            ) { [weak self] image in
                guard let image else { return }
                DispatchQueue.main.async {
                    guard
                        let self,
                        self.image == nil,
                        self.rgbStretchMode == rgbStretchMode
                    else { return }
                    self.previewImage = image
                }
            }
        }
        load()
    }

    var supportsRGBStretch: Bool {
        guard let colorKind = metadata?.colorKind else { return false }
        return colorKind == "planar-rgb" || colorKind == "bayer"
    }

    func setRGBStretchMode(_ mode: RGBStretchMode) {
        guard mode != rgbStretchMode else { return }
        rgbStretchMode = mode
        load()
    }

    func load(targetMedian: Double = 0.2) {
        loadGeneration &+= 1
        let generation = loadGeneration
        loadState = .loading
        let url = url
        let rgbStretchMode = rgbStretchMode
        ImageRenderQueue.renderFull(
            url: url,
            targetMedian: targetMedian,
            rgbStretchMode: rgbStretchMode
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
            let result = Result { try SeizaCore.solve(url: url, catalogDirectory: catalogDirectory) }
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
