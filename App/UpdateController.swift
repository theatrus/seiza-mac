import Combine
import Sparkle
import SwiftUI

@MainActor
final class UpdateController {
    let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var updater: SPUUpdater {
        updaterController.updater
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
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        model = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
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
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        _model = StateObject(
            wrappedValue: UpdateSettingsViewModel(updater: updater)
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
                Button("Check Now", action: updater.checkForUpdates)
                    .disabled(!model.canCheckForUpdates)
            }
        }
    }
}
