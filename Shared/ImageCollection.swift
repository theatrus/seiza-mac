import Foundation
import UniformTypeIdentifiers

enum ImageFilenameFilter: String, CaseIterable, Identifiable, Sendable {
    case luminance
    case red
    case green
    case blue
    case hydrogenAlpha
    case oxygenIII
    case sulfurII
    case hydrogenBeta

    var id: Self { self }

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
        }
    }

    static func detect(in url: URL) -> Self? {
        let normalized = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "α", with: "alpha")
            .replacingOccurrences(of: "β", with: "beta")
            .lowercased()
        let tokens = normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init)

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
            case "sii", "s2", "sulfurii", "sulphurii": return .sulfurII
            case "hb", "hbeta", "hydrogenbeta": return .hydrogenBeta
            case "l", "lum", "luminance": return .luminance
            case "r", "red": return .red
            case "g", "green": return .green
            case "b", "blue": return .blue
            default: break
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
