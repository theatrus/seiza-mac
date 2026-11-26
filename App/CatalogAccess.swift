import Foundation
import Combine

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

/// Persist the user-selected executable without losing sandbox access across launches.
@MainActor
final class RcAstroSettings: ObservableObject {
    static let shared = RcAstroSettings()
    @Published private(set) var revision = 0
    private let defaults: UserDefaults
    private let makeBookmark: (URL) throws -> Data
    private let readBookmark: (Data) throws -> (URL, Bool)
    private let isExecutable: (String) -> Bool
    private let bookmarkKey = "rcAstroExecutableBookmark"
    private let pathKey = "rcAstroExecutablePath"

    init(defaults: UserDefaults = .standard,
         makeBookmark: @escaping (URL) throws -> Data = {
             try $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
         },
         readBookmark: @escaping (Data) throws -> (URL, Bool) = {
             var stale = false
             let url = try URL(resolvingBookmarkData: $0, options: [.withSecurityScope, .withoutUI],
                               relativeTo: nil, bookmarkDataIsStale: &stale)
             return (url, stale)
         },
         isExecutable: @escaping (String) -> Bool = RcAstroSettings.isRunnableFile) {
        self.defaults = defaults; self.makeBookmark = makeBookmark
        self.readBookmark = readBookmark; self.isExecutable = isExecutable
    }

    /// A regular file this user may run. `access(X_OK)` alone, like
    /// `FileManager.isExecutableFile`, also accepts a folder such as an
    /// `.app` bundle, which cannot be started as a command.
    nonisolated static func isRunnableFile(atPath path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
        return access(path, X_OK) == 0
    }

    var displayPath: String { defaults.string(forKey: pathKey) ?? "" }

    func save(_ url: URL) throws {
        let scope = ParallaxScopedURL(url)
        try withExtendedLifetime(scope) {
            guard isExecutable(url.path) else {
                throw SeizaCoreError.message("Choose the rc-astro command itself, not a folder or app. It must be marked executable.")
            }
            let data = try makeBookmark(url)
            defaults.set(data, forKey: bookmarkKey)
            defaults.set(url.path, forKey: pathKey)
        }
        revision &+= 1
    }

    func resolve() -> URL? {
        guard let data = defaults.data(forKey: bookmarkKey),
              let (url, stale) = try? readBookmark(data) else { return nil }
        let scope = ParallaxScopedURL(url)
        return withExtendedLifetime(scope) {
            guard isExecutable(url.path) else { return nil }
            // Renew quietly: publishing during a read would recurse through subscribers.
            if stale, let renewed = try? makeBookmark(url) {
                defaults.set(renewed, forKey: bookmarkKey)
                defaults.set(url.path, forKey: pathKey)
            }
            return url
        }
    }

    func clear() {
        defaults.removeObject(forKey: bookmarkKey); defaults.removeObject(forKey: pathKey)
        revision &+= 1
    }
}
