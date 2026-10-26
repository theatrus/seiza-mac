import Foundation
import UniformTypeIdentifiers

enum ImageFilenameFilter: Hashable, Identifiable, Sendable {
    case luminance
    case red
    case green
    case blue
    case hydrogenAlpha
    case oxygenIII
    case sulfurII
    case hydrogenBeta
    case named(String)

    var id: String {
        switch self {
        case .luminance: "luminance"
        case .red: "red"
        case .green: "green"
        case .blue: "blue"
        case .hydrogenAlpha: "hydrogen-alpha"
        case .oxygenIII: "oxygen-iii"
        case .sulfurII: "sulfur-ii"
        case .hydrogenBeta: "hydrogen-beta"
        case .named(let name): "named:\(name.lowercased())"
        }
    }

    var title: String {
        switch self {
        case .luminance: "Luminance"
        case .red: "Red"
        case .green: "Green"
        case .blue: "Blue"
        case .hydrogenAlpha: "H-alpha"
        case .oxygenIII: "OIII"
        case .sulfurII: "SII"
        case .hydrogenBeta: "H-beta"
        case .named(let name): name
        }
    }

    var filenameSuffix: String {
        switch self {
        case .luminance: "L"
        case .red: "R"
        case .green: "G"
        case .blue: "B"
        case .hydrogenAlpha: "Ha"
        case .oxygenIII: "OIII"
        case .sulfurII: "SII"
        case .hydrogenBeta: "Hb"
        case .named(let name): name
        }
    }

    static func detect(in url: URL) -> Self? {
        let filename = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "α", with: "alpha")
            .replacingOccurrences(of: "β", with: "beta")
        let originalTokens = filename.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let tokens = originalTokens.map { $0.lowercased() }

        for pair in zip(tokens, tokens.dropFirst()) {
            switch pair {
            case ("h", "alpha"), ("hydrogen", "alpha"):
                return .hydrogenAlpha
            case ("o", "iii"), ("oxygen", "iii"):
                return .oxygenIII
            case ("s", "ii"), ("sulfur", "ii"), ("sulphur", "ii"):
                return .sulfurII
            case ("h", "beta"), ("hydrogen", "beta"):
                return .hydrogenBeta
            default:
                break
            }
        }

        for token in tokens {
            switch token {
            case "ha", "halpha", "hydrogenalpha": return .hydrogenAlpha
            case "oiii", "o3", "oxygeniii": return .oxygenIII
            case "s", "sii", "s2", "sulfurii", "sulphurii": return .sulfurII
            case "hb", "hbeta", "hydrogenbeta": return .hydrogenBeta
            case "l", "lum", "luminance": return .luminance
            case "r", "red": return .red
            case "g", "green": return .green
            case "b", "blue": return .blue
            default: break
            }
        }
        if let filterMarker = tokens.firstIndex(of: "filter"),
           originalTokens.indices.contains(filterMarker + 1) {
            return .named(originalTokens[filterMarker + 1])
        }
        for token in originalTokens.dropFirst().reversed()
        where token.allSatisfy(\.isLetter) {
            let isSingleLetter = token.count == 1
            let isUppercaseName = token == token.uppercased() && token != token.lowercased()
            if isSingleLetter || isUppercaseName {
                return .named(token)
            }
        }
        return nil
    }
}

enum ImageCollection {
    struct ScanIssue: Identifiable, Equatable, Sendable {
        let url: URL
        let message: String

        var id: URL { url }
    }

    struct Scan: Sendable {
        let images: [URL]
        let directories: [URL]
        let issues: [ScanIssue]

        var includesDirectory: Bool { !directories.isEmpty }
    }

    static func collect(from roots: [URL]) throws -> [URL] {
        try scan(from: roots).images
    }

    static func scanInBackground(
        from roots: [URL],
        scanner: @escaping @Sendable ([URL]) throws -> Scan = { try scan(from: $0) }
    ) async throws -> Scan {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let result = try scanner(roots)
            try Task.checkCancellation()
            return result
        }
        let result = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        return result
    }

    static func scan(from roots: [URL]) throws -> Scan {
        var images: [URL] = []
        var directories: [URL] = []
        var issues: [ScanIssue] = []
        var seenImages = Set<URL>()
        var seenIssues = Set<URL>()

        func recordIssue(at url: URL, message: String) {
            // Canonicalize the parent while preserving the name of a broken file link.
            let url = url.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(url.lastPathComponent, isDirectory: false)
            if seenIssues.insert(url).inserted {
                issues.append(ScanIssue(url: url, message: message))
            }
        }

        func appendImage(at url: URL) {
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey])
                var image = url.standardizedFileURL
                if values.isAliasFile == true, values.isSymbolicLink != true {
                    image = try URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting]).standardizedFileURL
                }
                guard isSupportedImage(image) else { return }
                let target = image.resolvingSymlinksInPath()
                let targetValues = try target.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                if targetValues.isDirectory == true { return }
                guard targetValues.isRegularFile == true else {
                    recordIssue(at: url, message: "The linked image does not point to a regular file.")
                    return
                }
                if seenImages.insert(target).inserted { images.append(image) }
            } catch {
                recordIssue(at: url, message: error.localizedDescription)
            }
        }

        for root in roots {
            try Task.checkCancellation()
            let values: URLResourceValues
            do {
                values = try root.resourceValues(forKeys: [.isDirectoryKey])
            } catch {
                recordIssue(at: root, message: error.localizedDescription)
                continue
            }
            if values.isDirectory == true {
                directories.append(root.standardizedFileURL)
                guard let contents = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { url, error in
                        recordIssue(at: url, message: error.localizedDescription)
                        return !Task.isCancelled
                    }
                ) else {
                    recordIssue(at: root, message: "The folder could not be read.")
                    continue
                }
                for case let url as URL in contents {
                    try Task.checkCancellation()
                    appendImage(at: url)
                }
            } else {
                appendImage(at: root)
            }
        }

        try Task.checkCancellation()
        let sortedImages = try images.sorted {
            try Task.checkCancellation()
            let nameOrder = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
            return nameOrder == .orderedSame
                ? $0.path.localizedStandardCompare($1.path) == .orderedAscending
                : nameOrder == .orderedAscending
        }
        try Task.checkCancellation()
        return Scan(
            images: sortedImages,
            directories: directories,
            issues: try issues.sorted {
                try Task.checkCancellation()
                return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
            }
        )
    }

    static func isSupportedImage(_ url: URL) -> Bool {
        UTType.seizaSupportedImageExtensions.contains(url.pathExtension.lowercased())
    }

    static func isStackableImage(_ url: URL) -> Bool {
        ["fits", "fit", "fts", "xisf"].contains(url.pathExtension.lowercased())
    }
}

enum ImageBrowserGrouping: String, CaseIterable, Identifiable {
    case path
    case fileType
    case filter
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .path: "Folder Path"
        case .fileType: "File Type"
        case .filter: "Filter"
        case .none: "None"
        }
    }

    var systemImage: String {
        switch self {
        case .path: "folder"
        case .fileType: "doc"
        case .filter: "camera.filters"
        case .none: "photo.on.rectangle"
        }
    }
}

enum ImageFileType: String, CaseIterable, Identifiable {
    case fits
    case xisf
    case jpeg
    case png
    case tiff

    var id: String { rawValue }
    var title: String { rawValue.uppercased() }

    static func detect(in url: URL) -> Self? {
        switch url.pathExtension.lowercased() {
        case "fits", "fit", "fts": .fits
        case "xisf": .xisf
        case "jpg", "jpeg", "jfif": .jpeg
        case "png": .png
        case "tif", "tiff": .tiff
        default: nil
        }
    }
}

struct ImageBrowserGroup: Identifiable {
    let id: String
    let title: String
    let imageIndices: [Int]
}

/// Keeps original image indices stable while presenting different browsing orders.
struct ImageBrowserCollection {
    let urls: [URL]
    let parentPaths: [String]
    private let pathGroups: [ImageBrowserGroup]
    private let fileTypeGroups: [ImageBrowserGroup]
    private let filterGroups: [ImageBrowserGroup]

    init(urls: [URL], directories: [URL] = []) {
        self.urls = urls
        let parents = urls.map { $0.standardizedFileURL.deletingLastPathComponent() }
        let roots = directories.isEmpty
            ? Self.commonDirectory(of: parents).map { [$0] } ?? []
            : Array(Set(directories.map(\.standardizedFileURL)))
        let rootNames = Dictionary(grouping: roots, by: \.lastPathComponent)
        let parentPaths = parents.map { parent in
            let components = parent.pathComponents
            let root = roots.filter { components.starts(with: $0.pathComponents) }
                .max { $0.pathComponents.count < $1.pathComponents.count }
            guard let root else { return parent.path }
            let relative = components.dropFirst(root.pathComponents.count).joined(separator: "/")
            let rootTitle = rootNames[root.lastPathComponent]?.count == 1
                ? root.lastPathComponent : root.path
            if roots.count == 1 && !relative.isEmpty { return relative }
            return relative.isEmpty ? rootTitle : rootTitle + "/" + relative
        }
        self.parentPaths = parentPaths

        let indicesByParent = Dictionary(grouping: urls.indices, by: { parents[$0] })
        pathGroups = indicesByParent.map { parent, indices in
            ImageBrowserGroup(
                id: "path:" + parent.path,
                title: parentPaths[indices[0]],
                imageIndices: Self.sortedIndices(indices, urls: urls)
            )
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }

        let fileTypes = urls.map(ImageFileType.detect)
        let indicesByFileType = Dictionary(grouping: urls.indices) { fileTypes[$0] }
        fileTypeGroups = indicesByFileType.map { fileType, indices in
            ImageBrowserGroup(
                id: "type:" + (fileType?.rawValue ?? "other"),
                title: fileType?.title ?? "Other",
                imageIndices: Self.sortedIndices(indices, urls: urls)
            )
        }.sorted {
            if $0.id == "type:other" { return false }
            if $1.id == "type:other" { return true }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }

        let filters = urls.map(ImageFilenameFilter.detect)
        let indicesByFilter = Dictionary(grouping: urls.indices) {
            filters[$0]?.id ?? "other"
        }
        filterGroups = indicesByFilter.map { filterID, indices in
            ImageBrowserGroup(
                id: "filter:" + filterID,
                title: filters[indices[0]]?.title ?? "Other",
                imageIndices: Self.sortedIndices(indices, urls: urls)
            )
        }.sorted {
            if $0.id == "filter:other" { return false }
            if $1.id == "filter:other" { return true }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    func groups(for grouping: ImageBrowserGrouping) -> [ImageBrowserGroup] {
        switch grouping {
        case .path: pathGroups
        case .fileType: fileTypeGroups
        case .filter: filterGroups
        case .none: [ImageBrowserGroup(id: "all", title: "Images", imageIndices: Array(urls.indices))]
        }
    }

    private static func commonDirectory(of parents: [URL]) -> URL? {
        guard let first = parents.first else { return nil }
        var components = first.pathComponents
        for parent in parents.dropFirst() {
            while !parent.pathComponents.starts(with: components) {
                components.removeLast()
            }
        }
        return URL(fileURLWithPath: NSString.path(withComponents: components), isDirectory: true)
    }

    private static func sortedIndices(_ indices: [Int], urls: [URL]) -> [Int] {
        indices.sorted {
            let nameOrder = urls[$0].lastPathComponent.localizedStandardCompare(urls[$1].lastPathComponent)
            return nameOrder == .orderedSame
                ? urls[$0].path.localizedStandardCompare(urls[$1].path) == .orderedAscending
                : nameOrder == .orderedAscending
        }
    }
}
