import Foundation

enum CatalogAccess {
    private static let bookmarkKey = "catalogBookmark"
    private static let pathKey = "catalogDirectory"

    static var displayPath: String {
        UserDefaults.standard.string(forKey: pathKey) ?? ""
    }

    static func save(_ url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        UserDefaults.standard.set(url.path, forKey: pathKey)
    }

    static func resolve() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else {
            return nil
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        if isStale {
            try? save(url)
        }
        return url
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: pathKey)
    }
}
