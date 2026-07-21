import Foundation
import UniformTypeIdentifiers

enum ImageCollection {
    static func collect(from roots: [URL]) -> [URL] {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isHiddenKey,
        ]
        var images: [URL] = []

        for root in roots {
            let values = try? root.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                let contents = try? FileManager.default.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles]
                )
                images.append(contentsOf: (contents ?? []).filter { url in
                    let values = try? url.resourceValues(forKeys: Set(keys))
                    return (values?.isRegularFile == true || values?.isSymbolicLink == true)
                        && values?.isHidden != true
                        && isSupportedImage(url)
                })
            } else if isSupportedImage(root) {
                images.append(root)
            }
        }

        var seenImages = Set<URL>()
        return images
            .map(\.standardizedFileURL)
            .filter { seenImages.insert($0).inserted }
            .sorted {
                let nameOrder = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                return nameOrder == .orderedSame
                    ? $0.path.localizedStandardCompare($1.path) == .orderedAscending
                    : nameOrder == .orderedAscending
            }
    }

    static func isSupportedImage(_ url: URL) -> Bool {
        UTType.seizaSupportedImageExtensions.contains(url.pathExtension.lowercased())
    }
}
