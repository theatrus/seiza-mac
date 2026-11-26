import Foundation
import OSLog

/// Seiza up to 0.10 ran in the App Sandbox, which kept its preferences and
/// support files in `~/Library/Containers/fyi.seiza.mac`. The sandbox blocked
/// running the user's own `rc-astro`, so Seiza now runs outside it, and on
/// its first launch outside the sandbox it brings that data across once.
///
/// The container's preferences file stays where it is. Each moved folder
/// leaves a symbolic link behind, so absolute paths saved inside the
/// container (live stack calibration masters, for example) still resolve.
enum SandboxMigration {
    static let preferencesKey = "migratedPreferencesFromSandboxContainer"
    static let doneKey = "migratedFromSandboxContainer"
    /// Folders under Application Support that this app filled while
    /// sandboxed: its own, and the core's default catalogs. The parents are
    /// shared (other Seiza products use `Seiza`, and the `seiza` command-line
    /// tool uses `fyi.Seiza.seiza`), so they are never moved whole. Caches
    /// are left behind: they rebuild themselves.
    static let supportFolders = ["Seiza/CalibrationMasters", "Seiza/LiveStacks", "Seiza/Models",
                                 "fyi.Seiza.seiza/catalogs"]
    private static let stagingSuffix = ".moving-from-sandbox"

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
        // A development build shares the bundle identifier with the installed
        // release, so it leaves that release's data alone unless asked.
        guard environment["SEIZA_RUN_SANDBOX_MIGRATION"] != nil else { return }
        #endif
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = Paths(
            container: home.appendingPathComponent("Library/Containers/\(bundleIdentifier)/Data", isDirectory: true),
            applicationSupport: home.appendingPathComponent("Library/Application Support", isDirectory: true),
            bundleIdentifier: bundleIdentifier)
        do {
            try run(paths: paths, defaults: .standard)
        } catch {
            // Leave the flag unset so the next launch tries the folders again.
            Logger(subsystem: bundleIdentifier, category: "SandboxMigration")
                .error("Could not move data out of the sandbox container: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Copy the container's preferences into `defaults` once, its values
    /// winning, then move each support folder that is not already outside.
    /// A failed folder move is retried on the next call; the preferences are
    /// not copied again, so settings changed since are kept.
    static func run(paths: Paths, defaults: UserDefaults, fileManager: FileManager = .default) throws {
        guard !defaults.bool(forKey: doneKey) else { return }
        if !defaults.bool(forKey: preferencesKey) {
            let preferences = paths.container
                .appendingPathComponent("Library/Preferences/\(paths.bundleIdentifier).plist")
            if fileManager.fileExists(atPath: preferences.path) {
                let data = try Data(contentsOf: preferences)
                guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                    throw CocoaError(.propertyListReadCorrupt)
                }
                for (key, value) in values { defaults.set(value, forKey: key) }
            }
            defaults.set(true, forKey: preferencesKey)
        }
        let oldSupport = paths.container.appendingPathComponent("Library/Application Support", isDirectory: true)
        for folder in supportFolders {
            try move(oldSupport.appendingPathComponent(folder, isDirectory: true),
                     to: paths.applicationSupport.appendingPathComponent(folder, isDirectory: true),
                     fileManager: fileManager)
        }
        defaults.set(true, forKey: doneKey)
    }

    private static func move(_ source: URL, to destination: URL, fileManager: FileManager) throws {
        // Move under a temporary name first. Across volumes a move is a copy,
        // and one cut short must not later pass for a finished folder.
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(destination.lastPathComponent + stagingSuffix, isDirectory: true)
        guard let type = try? fileManager.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType else {
            // Nothing at the old path: never there, or a move that stopped
            // after leaving the container. Finish that one.
            if fileManager.fileExists(atPath: staging.path), !fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: staging, to: destination)
                link(source, to: destination, fileManager: fileManager)
            }
            return
        }
        // A link at the old path: already moved.
        guard type != .typeSymbolicLink else { return }
        // A folder already outside wins: the command-line tool may have
        // installed the same catalogs there.
        guard !fileManager.fileExists(atPath: destination.path) else { return }
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: source, to: staging)
        try fileManager.moveItem(at: staging, to: destination)
        link(source, to: destination, fileManager: fileManager)
    }

    /// Paths saved while sandboxed point into the container; a link there
    /// keeps them working. Without it only those saved paths go stale.
    private static func link(_ source: URL, to destination: URL, fileManager: FileManager) {
        try? fileManager.createSymbolicLink(at: source, withDestinationURL: destination)
    }
}
