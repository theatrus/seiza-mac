import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

private final class ImageThumbnailBox: NSObject {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}

enum ImageThumbnailCache {
    static let maximumDimension = 320

    private static let diskLimit = 256 * 1_024 * 1_024
    private static let diskTarget = 192 * 1_024 * 1_024
    private static let ioQueue = DispatchQueue(
        label: "fyi.seiza.mac.thumbnail-cache",
        qos: .utility
    )
    private static let memory: NSCache<NSString, ImageThumbnailBox> = {
        let cache = NSCache<NSString, ImageThumbnailBox>()
        cache.countLimit = 256
        cache.totalCostLimit = 128 * 1_024 * 1_024
        return cache
    }()
    private static let directoryURL: URL? = {
        guard let root = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let bundleDirectory = root.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "fyi.seiza.mac",
            isDirectory: true
        )
        let directory = bundleDirectory.appendingPathComponent(
            "Thumbnails",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }()

    static func memoryImage(
        for url: URL,
        processing: FITSImageProcessingConfiguration = .default
    ) -> CGImage? {
        memory.object(
            forKey: cacheKey(
                for: url,
                processing: processing
            ) as NSString
        )?.image
    }

    static func load(
        for url: URL,
        processing: FITSImageProcessingConfiguration = .default,
        completion: @escaping (CGImage?) -> Void
    ) {
        let key = cacheKey(for: url, processing: processing)
        if let image = memory.object(forKey: key as NSString)?.image {
            completion(image)
            return
        }
        guard let fileURL = cacheFileURL(forKey: key) else {
            completion(nil)
            return
        }

        ioQueue.async {
            guard
                let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                try? FileManager.default.removeItem(at: fileURL)
                completion(nil)
                return
            }
            memory.setObject(
                ImageThumbnailBox(image),
                forKey: key as NSString,
                cost: image.bytesPerRow * image.height
            )
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: fileURL.path
            )
            completion(image)
        }
    }

    static func render(
        for url: URL,
        processing: FITSImageProcessingConfiguration = .default,
        completion: @escaping (CGImage?) -> Void
    ) {
        ImageRenderQueue.renderThumbnail(
            url: url,
            processing: processing,
            completion: completion
        )
    }

    static func prefetch(
        _ urls: [URL],
        processing: FITSImageProcessingConfiguration = .default
    ) {
        for url in urls where memoryImage(
            for: url,
            processing: processing
        ) == nil {
            load(for: url, processing: processing) { cached in
                guard cached == nil else { return }
                render(for: url, processing: processing) { _ in }
            }
        }
    }

    @discardableResult
    static func storeThumbnail(
        from image: CGImage,
        for url: URL,
        processing: FITSImageProcessingConfiguration = .default
    ) -> CGImage {
        let thumbnail = resized(image, maximumDimension: maximumDimension)
        let key = cacheKey(for: url, processing: processing)
        memory.setObject(
            ImageThumbnailBox(thumbnail),
            forKey: key as NSString,
            cost: thumbnail.bytesPerRow * thumbnail.height
        )
        guard let fileURL = cacheFileURL(forKey: key) else { return thumbnail }

        ioQueue.async {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try? FileManager.default.setAttributes(
                    [.modificationDate: Date()],
                    ofItemAtPath: fileURL.path
                )
                return
            }

            let data = NSMutableData()
            guard
                let destination = CGImageDestinationCreateWithData(
                    data,
                    UTType.png.identifier as CFString,
                    1,
                    nil
                )
            else {
                return
            }
            CGImageDestinationAddImage(destination, thumbnail, nil)
            guard CGImageDestinationFinalize(destination) else { return }
            try? (data as Data).write(to: fileURL, options: .atomic)
            pruneDiskCache()
        }
        return thumbnail
    }

    private static func resized(
        _ image: CGImage,
        maximumDimension: Int
    ) -> CGImage {
        let longestSide = max(image.width, image.height)
        guard longestSide > maximumDimension else { return image }

        let scale = CGFloat(maximumDimension) / CGFloat(longestSide)
        let width = max(Int((CGFloat(image.width) * scale).rounded()), 1)
        let height = max(Int((CGFloat(image.height) * scale).rounded()), 1)
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return image
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private static func cacheKey(
        for url: URL,
        processing: FITSImageProcessingConfiguration
    ) -> String {
        let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
        let values = try? canonicalURL.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
        ])
        let signature = [
            url.standardizedFileURL.path,
            canonicalURL.path,
            String(values?.fileSize ?? 0),
            String(values?.contentModificationDate?.timeIntervalSince1970 ?? 0),
            "fits-processing:\(processing.cacheIdentifier)",
        ].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(signature.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func cacheFileURL(forKey key: String) -> URL? {
        directoryURL?
            .appendingPathComponent(key, isDirectory: false)
            .appendingPathExtension("png")
    }

    private static func pruneDiskCache() {
        guard let directoryURL else { return }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        var entries = files.compactMap { file -> (URL, Int, Date)? in
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else {
                return nil
            }
            return (
                file,
                values.fileSize ?? 0,
                values.contentModificationDate ?? .distantPast
            )
        }
        var totalSize = entries.reduce(0) { $0 + $1.1 }
        guard totalSize > diskLimit else { return }

        entries.sort { $0.2 < $1.2 }
        for entry in entries where totalSize > diskTarget {
            if (try? FileManager.default.removeItem(at: entry.0)) != nil {
                totalSize -= entry.1
            }
        }
    }
}

enum ImageRenderQueue {
    typealias ThumbnailCompletion = (CGImage?) -> Void
    typealias FullCompletion = (Result<RenderedImage, Error>) -> Void

    private enum JobKind {
        case thumbnail
        case full
    }

    private struct Job {
        var kind: JobKind
        var thumbnailCompletions: [ThumbnailCompletion] = []
        var fullCompletions: [FullCompletion] = []
    }

    private static let thumbnailOperations: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "fyi.seiza.mac.thumbnail-rendering"
        queue.qualityOfService = .utility
        // The default asks OperationQueue to adapt concurrency to current
        // system resources instead of baking a processor count into the app.
        queue.maxConcurrentOperationCount = OperationQueue.defaultMaxConcurrentOperationCount
        return queue
    }()
    private static let fullOperations: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "fyi.seiza.mac.full-rendering"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = OperationQueue.defaultMaxConcurrentOperationCount
        return queue
    }()
    private static let stateQueue = DispatchQueue(
        label: "fyi.seiza.mac.rendering.state"
    )
    private static var jobs: [String: Job] = [:]

    static func renderThumbnail(
        url: URL,
        processing: FITSImageProcessingConfiguration = .default,
        completion: @escaping ThumbnailCompletion
    ) {
        let key = jobKey(for: url, processing: processing)
        let shouldSchedule = stateQueue.sync {
            if var job = jobs[key] {
                job.thumbnailCompletions.append(completion)
                jobs[key] = job
                return false
            }
            jobs[key] = Job(
                kind: .thumbnail,
                thumbnailCompletions: [completion]
            )
            return true
        }
        guard shouldSchedule else { return }
        scheduleThumbnail(
            url: url,
            key: key,
            processing: processing
        )
    }

    static func renderFull(
        url: URL,
        processing: FITSImageProcessingConfiguration,
        completion: @escaping FullCompletion
    ) {
        let key = jobKey(for: url, processing: processing)
        let shouldSchedule = stateQueue.sync {
            if var job = jobs[key] {
                job.fullCompletions.append(completion)
                jobs[key] = job
                return false
            }
            jobs[key] = Job(
                kind: .full,
                fullCompletions: [completion]
            )
            return true
        }
        guard shouldSchedule else { return }
        scheduleFull(
            url: url,
            key: key,
            processing: processing
        )
    }

    private static func scheduleThumbnail(
        url: URL,
        key: String,
        processing: FITSImageProcessingConfiguration
    ) {
        thumbnailOperations.addOperation {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let thumbnail = try? SeizaCore.render(
                url: url,
                maxDimension: UInt32(ImageThumbnailCache.maximumDimension),
                processing: processing
            ).image
            if let thumbnail {
                ImageThumbnailCache.storeThumbnail(
                    from: thumbnail,
                    for: url,
                    processing: processing
                )
            }

            let outcome = stateQueue.sync { () -> ([ThumbnailCompletion], Bool) in
                guard var job = jobs[key] else { return ([], false) }
                let callbacks = job.thumbnailCompletions
                job.thumbnailCompletions = []
                if job.fullCompletions.isEmpty {
                    jobs.removeValue(forKey: key)
                    return (callbacks, false)
                }
                job.kind = .full
                jobs[key] = job
                return (callbacks, true)
            }
            OperationQueue.main.addOperation {
                outcome.0.forEach { $0(thumbnail) }
            }
            if outcome.1 {
                scheduleFull(
                    url: url,
                    key: key,
                    processing: processing
                )
            }
        }
    }

    private static func scheduleFull(
        url: URL,
        key: String,
        processing: FITSImageProcessingConfiguration
    ) {
        fullOperations.addOperation {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let result = Result {
                try SeizaCore.render(
                    url: url,
                    processing: processing
                )
            }
            let thumbnail: CGImage?
            switch result {
            case .success(let rendered):
                thumbnail = ImageThumbnailCache.storeThumbnail(
                    from: rendered.image,
                    for: url,
                    processing: processing
                )
            case .failure:
                thumbnail = nil
            }

            let callbacks = stateQueue.sync {
                let job = jobs.removeValue(forKey: key)
                return (
                    job?.thumbnailCompletions ?? [],
                    job?.fullCompletions ?? []
                )
            }
            OperationQueue.main.addOperation {
                callbacks.0.forEach { $0(thumbnail) }
                callbacks.1.forEach { $0(result) }
            }
        }
    }

    private static func jobKey(
        for url: URL,
        processing: FITSImageProcessingConfiguration
    ) -> String {
        "\(url.resolvingSymlinksInPath().standardizedFileURL.path)\n\(processing.cacheIdentifier)"
    }
}

/// A serial, latest-only queue for interactive controls. It delivers a bounded
/// responsive pass followed by a source-resolution pass. Pending work is
/// cancelled when a newer request arrives; an already-running C ABI call is
/// allowed to finish, but its obsolete result is discarded.
final class LatestImagePreviewRenderer {
    enum Pass: Equatable {
        case responsive
        case fullResolution
    }

    typealias Completion = (Pass, Result<RenderedImage, Error>) -> Void

    private let operations: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "fyi.seiza.mac.processing-preview"
        queue.qualityOfService = .userInteractive
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    func render(
        url: URL,
        responsiveProcessing: FITSImageProcessingConfiguration,
        fullResolutionProcessing: FITSImageProcessingConfiguration,
        plan: ImagePreviewRenderPlan,
        completion: @escaping Completion
    ) {
        operations.cancelAllOperations()

        if !plan.needsFullResolutionRefinement {
            operations.addOperation(
                ImagePreviewOperation(
                    url: url,
                    processing: fullResolutionProcessing,
                    maxDimension: 0,
                    pass: .fullResolution,
                    completion: completion
                )
            )
            return
        }

        operations.addOperation(
            ImagePreviewOperation(
                url: url,
                processing: responsiveProcessing,
                maxDimension: plan.responsiveMaxDimension,
                pass: .responsive,
                completion: completion
            )
        )
        operations.addOperation(
            ImagePreviewOperation(
                url: url,
                processing: fullResolutionProcessing,
                maxDimension: 0,
                pass: .fullResolution,
                completion: completion
            )
        )
    }

    func cancel() {
        operations.cancelAllOperations()
    }
}

private final class ImagePreviewOperation: Operation, @unchecked Sendable {
    private let url: URL
    private let processing: FITSImageProcessingConfiguration
    private let maxDimension: UInt32
    private let pass: LatestImagePreviewRenderer.Pass
    private let completion: LatestImagePreviewRenderer.Completion

    init(
        url: URL,
        processing: FITSImageProcessingConfiguration,
        maxDimension: UInt32,
        pass: LatestImagePreviewRenderer.Pass,
        completion: @escaping LatestImagePreviewRenderer.Completion
    ) {
        self.url = url
        self.processing = processing
        self.maxDimension = maxDimension
        self.pass = pass
        self.completion = completion
    }

    override func main() {
        guard !isCancelled else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let result = Result {
            try SeizaCore.render(
                url: url,
                maxDimension: maxDimension,
                processing: processing
            )
        }
        guard !isCancelled else { return }
        OperationQueue.main.addOperation { [self] in
            guard !isCancelled else { return }
            self.completion(pass, result)
        }
    }
}
