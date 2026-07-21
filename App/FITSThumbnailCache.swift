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

    static func memoryImage(for url: URL) -> CGImage? {
        memory.object(forKey: cacheKey(for: url) as NSString)?.image
    }

    static func load(
        for url: URL,
        completion: @escaping (CGImage?) -> Void
    ) {
        let key = cacheKey(for: url)
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
        completion: @escaping (CGImage?) -> Void
    ) {
        ImageRenderQueue.renderThumbnail(url: url, completion: completion)
    }

    static func prefetch(_ urls: [URL]) {
        for url in urls where memoryImage(for: url) == nil {
            load(for: url) { cached in
                guard cached == nil else { return }
                render(for: url) { _ in }
            }
        }
    }

    @discardableResult
    static func storeThumbnail(from image: CGImage, for url: URL) -> CGImage {
        let thumbnail = resized(image, maximumDimension: maximumDimension)
        let key = cacheKey(for: url)
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

    private static func cacheKey(for url: URL) -> String {
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
        var targetMedian = 0.2
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
        completion: @escaping ThumbnailCompletion
    ) {
        let key = jobKey(for: url)
        let shouldSchedule = stateQueue.sync {
            if var job = jobs[key] {
                job.thumbnailCompletions.append(completion)
                jobs[key] = job
                return false
            }
            jobs[key] = Job(kind: .thumbnail, thumbnailCompletions: [completion])
            return true
        }
        guard shouldSchedule else { return }
        scheduleThumbnail(url: url, key: key)
    }

    static func renderFull(
        url: URL,
        targetMedian: Double,
        completion: @escaping FullCompletion
    ) {
        let key = jobKey(for: url)
        let shouldSchedule = stateQueue.sync {
            if var job = jobs[key] {
                job.fullCompletions.append(completion)
                job.targetMedian = targetMedian
                jobs[key] = job
                return false
            }
            jobs[key] = Job(
                kind: .full,
                fullCompletions: [completion],
                targetMedian: targetMedian
            )
            return true
        }
        guard shouldSchedule else { return }
        scheduleFull(url: url, key: key, targetMedian: targetMedian)
    }

    private static func scheduleThumbnail(url: URL, key: String) {
        thumbnailOperations.addOperation {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let thumbnail = try? SeizaCore.render(
                url: url,
                maxDimension: UInt32(ImageThumbnailCache.maximumDimension)
            ).image
            if let thumbnail {
                ImageThumbnailCache.storeThumbnail(from: thumbnail, for: url)
            }

            let outcome = stateQueue.sync { () -> ([ThumbnailCompletion], Double?) in
                guard var job = jobs[key] else { return ([], nil) }
                let callbacks = job.thumbnailCompletions
                job.thumbnailCompletions = []
                if job.fullCompletions.isEmpty {
                    jobs.removeValue(forKey: key)
                    return (callbacks, nil)
                }
                job.kind = .full
                jobs[key] = job
                return (callbacks, job.targetMedian)
            }
            OperationQueue.main.addOperation {
                outcome.0.forEach { $0(thumbnail) }
            }
            if let targetMedian = outcome.1 {
                scheduleFull(url: url, key: key, targetMedian: targetMedian)
            }
        }
    }

    private static func scheduleFull(
        url: URL,
        key: String,
        targetMedian: Double
    ) {
        fullOperations.addOperation {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let result = Result {
                try SeizaCore.render(url: url, targetMedian: targetMedian)
            }
            let thumbnail: CGImage?
            switch result {
            case .success(let rendered):
                thumbnail = ImageThumbnailCache.storeThumbnail(
                    from: rendered.image,
                    for: url
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

    private static func jobKey(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
