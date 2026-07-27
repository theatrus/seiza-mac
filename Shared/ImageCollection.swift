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
    }

    static func collect(from roots: [URL]) -> [URL] {
        scan(from: roots).images
    }

    static func scan(from roots: [URL]) -> Scan {
        var images: [URL] = []
        var includesDirectory = false

        for root in roots {
            let values = try? root.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                includesDirectory = true
                let contents = try? FileManager.default.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                images.append(contentsOf: (contents ?? []).filter { url in
                    isSupportedImage(url) && !url.hasDirectoryPath
                })
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
        return Scan(images: sortedImages, includesDirectory: includesDirectory)
    }

    static func isSupportedImage(_ url: URL) -> Bool {
        UTType.seizaSupportedImageExtensions.contains(url.pathExtension.lowercased())
    }

    static func isStackableImage(_ url: URL) -> Bool {
        ["fits", "fit", "fts", "xisf"].contains(url.pathExtension.lowercased())
    }
}
