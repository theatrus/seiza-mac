import Combine
import Sparkle
import SwiftUI

/// Chooses which copy of the signed feed Sparkle reads.
///
/// Both copies hold the same bytes: release CI publishes `appcast.xml` on the
/// GitHub release, and updates.seiza.fyi mirrors it. Sparkle reads one feed per
/// check, so the fallback is decided around each check rather than inside it.
/// A check the user starts probes our feed first and goes straight to GitHub
/// if it does not answer. A scheduled check that fails to fetch or verify our
/// feed is retried once against GitHub. Every check after that starts from our
/// feed again.
struct UpdateFeedSelection {
    static let primaryFeedURL = "https://updates.seiza.fyi/mac/appcast.xml"
    static let fallbackFeedURL =
        "https://github.com/theatrus/seiza-mac/releases/latest/download/appcast.xml"

    /// Sparkle's codes for a feed that could not be downloaded
    /// (`SUAppcastError`) or could not be parsed or verified
    /// (`SUAppcastParseError`, which also covers a bad feed signature).
    static let feedErrorCodes: Set<Int> = [1000, 1002]
    static let sparkleErrorDomain = SUSparkleErrorDomain

    private(set) var usesFallback = false
    private var cycleUsedFallback = false

    /// The feed for the check Sparkle is starting now.
    mutating func feedURLString() -> String {
        cycleUsedFallback = usesFallback
        return usesFallback ? Self.fallbackFeedURL : Self.primaryFeedURL
    }

    /// Called before a check the user started, with the result of the probe.
    mutating func prepareUserCheck(primaryReachable: Bool) {
        usesFallback = !primaryReachable
    }

    /// Called when Sparkle finishes a check. Returns true when the caller
    /// should run the scheduled check again against the fallback feed.
    mutating func finishCycle(scheduled: Bool, error: Error?) -> Bool {
        if cycleUsedFallback {
            usesFallback = false
            cycleUsedFallback = false
            return false
        }
        guard scheduled, let error = error as NSError?,
              error.domain == Self.sparkleErrorDomain,
              Self.feedErrorCodes.contains(error.code)
        else {
            return false
        }
        usesFallback = true
        return true
    }
}

@MainActor
final class UpdateController: NSObject, SPUUpdaterDelegate {
    private var updaterController: SPUStandardUpdaterController!
    private var feedSelection = UpdateFeedSelection()
    private var preparingUserCheck = false

    override init() {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    var updater: SPUUpdater {
        updaterController.updater
    }

    /// Checks the user asked for. Probes our feed first so that one click
    /// covers both copies; Sparkle itself would show an error and stop.
    func checkForUpdates() {
        guard !preparingUserCheck else { return }
        preparingUserCheck = true
        Task {
            let reachable = await Self.feedIsReachable(UpdateFeedSelection.primaryFeedURL)
            feedSelection.prepareUserCheck(primaryReachable: reachable)
            preparingUserCheck = false
            updater.checkForUpdates()
        }
    }

    /// A HEAD request, so the probe shows up apart from Sparkle's own GET in
    /// the server log.
    nonisolated static func feedIsReachable(
        _ urlString: String,
        session: URLSession = .shared
    ) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 5
        )
        request.httpMethod = "HEAD"
        guard let result = try? await session.data(for: request) else {
            return false
        }
        return (result.1 as? HTTPURLResponse)?.statusCode == 200
    }

    // Sparkle calls its delegate on the main thread.

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        MainActor.assumeIsolated {
            feedSelection.feedURLString()
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            let retry = feedSelection.finishCycle(
                scheduled: updateCheck == .updatesInBackground,
                error: error
            )
            if retry {
                // Let Sparkle finish tearing down this cycle first.
                DispatchQueue.main.async {
                    updater.checkForUpdatesInBackground()
                }
            }
        }
    }
}

@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var model: CheckForUpdatesViewModel
    private let controller: UpdateController

    init(controller: UpdateController) {
        self.controller = controller
        model = CheckForUpdatesViewModel(updater: controller.updater)
    }

    var body: some View {
        Button("Check for Updates…", action: controller.checkForUpdates)
            .disabled(!model.canCheckForUpdates)
    }
}

@MainActor
final class UpdateSettingsViewModel: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published var automaticallyChecksForUpdates: Bool
    @Published var automaticallyDownloadsUpdates: Bool

    private let updater: SPUUpdater
    private var cancellables: Set<AnyCancellable> = []

    init(updater: SPUUpdater) {
        self.updater = updater
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates

        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)

        updater.publisher(for: \.automaticallyChecksForUpdates)
            .removeDuplicates()
            .sink { [weak self] value in
                self?.automaticallyChecksForUpdates = value
            }
            .store(in: &cancellables)

        updater.publisher(for: \.automaticallyDownloadsUpdates)
            .removeDuplicates()
            .sink { [weak self] value in
                self?.automaticallyDownloadsUpdates = value
            }
            .store(in: &cancellables)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        updater.automaticallyDownloadsUpdates = enabled
    }
}

struct UpdateSettingsSection: View {
    @StateObject private var model: UpdateSettingsViewModel
    private let controller: UpdateController

    init(controller: UpdateController) {
        self.controller = controller
        _model = StateObject(
            wrappedValue: UpdateSettingsViewModel(updater: controller.updater)
        )
    }

    var body: some View {
        Section("Software updates") {
            Toggle(
                "Automatically check for updates",
                isOn: Binding(
                    get: { model.automaticallyChecksForUpdates },
                    set: model.setAutomaticallyChecksForUpdates
                )
            )

            Toggle(
                "Automatically download and install updates",
                isOn: Binding(
                    get: { model.automaticallyDownloadsUpdates },
                    set: model.setAutomaticallyDownloadsUpdates
                )
            )
            .disabled(!model.automaticallyChecksForUpdates)

            HStack {
                Text("Updates are signed and installed by Sparkle.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check Now", action: controller.checkForUpdates)
                    .disabled(!model.canCheckForUpdates)
            }
        }
    }
}
