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
    struct Scan: Sendable {
        let images: [URL]
        let includesDirectory: Bool
        let directories: [URL]
    }

    static func collect(from roots: [URL]) -> [URL] {
        scan(from: roots).images
    }

    static func scan(from roots: [URL]) -> Scan {
        var images: [URL] = []
        var directories: [URL] = []

        for root in roots {
            let values = try? root.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                directories.append(root.standardizedFileURL)
                guard let contents = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { _, _ in true }
                ) else { continue }
                for case let url as URL in contents {
                    guard !Task.isCancelled else { break }
                    if isSupportedImage(url),
                       (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                        images.append(url)
                    }
                }
            } else if isSupportedImage(root) {
                images.append(root)
            }
        }

        var seenImages = Set<URL>()
        let sortedImages = images
            .map(\.standardizedFileURL)
            .filter { seenImages.insert($0).inserted }
            .sorted {
                let nameOrder = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                return nameOrder == .orderedSame
                    ? $0.path.localizedStandardCompare($1.path) == .orderedAscending
                    : nameOrder == .orderedAscending
            }
        return Scan(
            images: sortedImages,
            includesDirectory: !directories.isEmpty,
            directories: directories
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
    case filter
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .path: "Folder Path"
        case .filter: "Filter"
        case .none: "None"
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
