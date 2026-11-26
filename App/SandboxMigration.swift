import Foundation
import OSLog

/// Seiza up to 0.10 ran in the App Sandbox, which kept its preferences and
/// support files in `~/Library/Containers/fyi.seiza.mac`. The sandbox blocked
/// running the user's own `rc-astro`, so Seiza now runs outside it, and on
/// its first launch outside the sandbox it brings that data across once.
///
/// The container itself is left in place, so a user who goes back to a
/// sandboxed release still finds their preferences there.
enum SandboxMigration {
    static let doneKey = "migratedFromSandboxContainer"
    /// Folders under Application Support that this app filled while
    /// sandboxed: its own, and the core's default catalogs and AI models. The
    /// parents are shared (other Seiza products use `Seiza`, and the `seiza`
    /// command-line tool uses `fyi.Seiza.seiza`), so they are never moved whole.
    /// Caches are left behind: they rebuild themselves.
    static let supportFolders = ["Seiza/CalibrationMasters", "Seiza/LiveStacks",
                                 "fyi.Seiza.seiza/catalogs", "fyi.Seiza.seiza/models"]

    struct Paths {
        /// `~/Library/Containers/<bundle id>/Data`.
        var container: URL
        /// The unsandboxed `~/Library/Application Support`.
        var applicationSupport: URL
        var bundleIdentifier: String
    }

    /// Run once, as early as possible: before anything reads preferences.
    static func runIfNeeded() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["APP_SANDBOX_CONTAINER_ID"] == nil,
              environment["XCTestConfigurationFilePath"] == nil,
              let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        #if DEBUG
        // Lets a development build run outside the sandbox without taking
        // the data of the installed release.
        if environment["SEIZA_SKIP_SANDBOX_MIGRATION"] != nil { return }
        #endif
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = Paths(
            container: home.appendingPathComponent("Library/Containers/\(bundleIdentifier)/Data", isDirectory: true),
            applicationSupport: home.appendingPathComponent("Library/Application Support", isDirectory: true),
            bundleIdentifier: bundleIdentifier)
        do {
            try run(paths: paths, defaults: .standard)
        } catch {
            // Leave the flag unset so the next launch tries again.
            Logger(subsystem: bundleIdentifier, category: "SandboxMigration")
                .error("Could not move data out of the sandbox container: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Copy the container's preferences into `defaults`, its values winning,
    /// and move each support folder that is not already outside it.
    static func run(paths: Paths, defaults: UserDefaults, fileManager: FileManager = .default) throws {
        guard !defaults.bool(forKey: doneKey) else { return }
        let preferences = paths.container
            .appendingPathComponent("Library/Preferences/\(paths.bundleIdentifier).plist")
        if fileManager.fileExists(atPath: preferences.path) {
            let data = try Data(contentsOf: preferences)
            guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            for (key, value) in values { defaults.set(value, forKey: key) }
        }
        let oldSupport = paths.container.appendingPathComponent("Library/Application Support", isDirectory: true)
        for folder in supportFolders {
            let source = oldSupport.appendingPathComponent(folder, isDirectory: true)
            let destination = paths.applicationSupport.appendingPathComponent(folder, isDirectory: true)
            // A folder already outside wins: the command-line tool may have
            // installed the same catalogs there.
            guard fileManager.fileExists(atPath: source.path),
                  !fileManager.fileExists(atPath: destination.path) else { continue }
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: source, to: destination)
        }
        defaults.set(true, forKey: doneKey)
    }
}
