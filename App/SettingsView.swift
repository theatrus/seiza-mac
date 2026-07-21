import AppKit
import SwiftUI

final class CatalogSetupController: ObservableObject {
    static let shared = CatalogSetupController()

    @Published private(set) var status: CatalogStatus?
    @Published private(set) var progress: CatalogSetupProgress?
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?

    private var statusGeneration = 0

    var isReadyForSolving: Bool {
        status?.readyForSolving == true
    }

    func refreshStatus() {
        statusGeneration &+= 1
        let generation = statusGeneration
        let catalogURL = CatalogAccess.resolve()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let accessing = catalogURL?.startAccessingSecurityScopedResource() ?? false
            defer {
                if accessing { catalogURL?.stopAccessingSecurityScopedResource() }
            }
            let result = Result { try SeizaCore.catalogStatus(catalogDirectory: catalogURL) }
            DispatchQueue.main.async {
                guard let self, self.statusGeneration == generation else { return }
                switch result {
                case .success(let status):
                    self.status = status
                    self.errorMessage = nil
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func install(_ preset: CatalogSetupPreset) {
        guard !isRunning else { return }
        let configuredPath = CatalogAccess.displayPath
        let catalogURL = CatalogAccess.resolve()
        guard configuredPath.isEmpty || catalogURL != nil else {
            errorMessage = "Seiza no longer has permission to write to the selected catalog directory. Choose it again."
            return
        }

        isRunning = true
        errorMessage = nil
        progress = nil
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let accessing = catalogURL?.startAccessingSecurityScopedResource() ?? false
            defer {
                if accessing { catalogURL?.stopAccessingSecurityScopedResource() }
            }
            let result = Result {
                try SeizaCore.setupCatalogs(
                    catalogDirectory: catalogURL,
                    preset: preset
                ) { progress in
                    DispatchQueue.main.async { [weak self] in
                        guard self?.isRunning == true else { return }
                        self?.progress = progress
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRunning = false
                switch result {
                case .success:
                    self.refreshStatus()
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private init() {}
}

struct SettingsView: View {
    @AppStorage("catalogDirectory") private var catalogDirectory = ""
    @StateObject private var setup = CatalogSetupController.shared
    @State private var preset = CatalogSetupPreset.standardBlind
    @State private var selectionError: String?

    var body: some View {
        Form {
            Section("Catalog location") {
                LabeledContent("Directory") {
                    HStack {
                        Text(displayPath)
                            .foregroundStyle(catalogDirectory.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button("Choose…", action: chooseCatalogDirectory)
                            .disabled(setup.isRunning)
                        if !catalogDirectory.isEmpty {
                            Button("Use Default") {
                                CatalogAccess.reset()
                                catalogDirectory = ""
                                selectionError = nil
                                setup.clearError()
                                setup.refreshStatus()
                            }
                            .disabled(setup.isRunning)
                        }
                    }
                }

                if let status = setup.status {
                    LabeledContent("Plate solving") {
                        readinessLabel(
                            ready: status.readyForSolving,
                            readyText: "Ready",
                            missingText: "Setup required"
                        )
                    }
                    LabeledContent("Catalog overlays") {
                        readinessLabel(
                            ready: status.readyForOverlays,
                            readyText: "Ready",
                            missingText: "Incomplete"
                        )
                    }
                } else {
                    LabeledContent("Status") {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Checking catalogs")
                    }
                }
            }

            Section("Catalog setup") {
                Picker("Package", selection: $preset) {
                    ForEach(CatalogSetupPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .disabled(setup.isRunning)

                Text(preset.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack {
                    Button(setup.isReadyForSolving ? "Verify or Repair Catalogs" : "Download and Install Catalogs") {
                        setup.install(preset)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(setup.isRunning)

                    if setup.isRunning {
                        Text("Setup continues if this window is closed.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if let progress = setup.progress {
                    progressView(progress)
                }

                Text("Downloads are SHA-256 verified and safe to retry. Seiza keeps immutable verified catalog files in its cache and installs them with hard links when possible, avoiding a second copy and hash pass. Cross-filesystem installs fall back to a verified copy.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let message = selectionError ?? setup.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(width: 700)
        .frame(minHeight: 500)
        .onAppear {
            setup.refreshStatus()
        }
    }

    private var displayPath: String {
        let path = catalogDirectory.isEmpty ? setup.status?.directory : catalogDirectory
        guard let path else { return "Seiza default" }
        return NSString(string: path).abbreviatingWithTildeInPath
    }

    @ViewBuilder
    private func readinessLabel(
        ready: Bool,
        readyText: String,
        missingText: String
    ) -> some View {
        Label(
            ready ? readyText : missingText,
            systemImage: ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
        )
        .foregroundStyle(ready ? .green : .orange)
    }

    @ViewBuilder
    private func progressView(_ progress: CatalogSetupProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if progress.phase == .complete {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if setup.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(progress.message)
                    .fontWeight(.medium)
                Spacer()
                if progress.filesTotal > 0 {
                    Text("\(progress.filesCompleted) of \(progress.filesTotal) files")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if let fraction = progress.fractionCompleted {
                ProgressView(value: fraction)
                HStack {
                    if let completed = progress.bytesCompleted,
                       let total = progress.bytesTotal {
                        Text("\(byteCount(completed)) of \(byteCount(total))")
                    }
                    Spacer()
                    Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if setup.isRunning {
                ProgressView()
            }

            if progress.phase == .verifying {
                Label(
                    "Verifying SHA-256 integrity for cached catalog data.",
                    systemImage: "checkmark.shield"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            } else if progress.phase == .downloading,
                      let written = progress.writtenBytes,
                      let downloaded = progress.bytesCompleted,
                      written > downloaded {
                Text("Unpacked \(byteCount(written)) while downloading.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(clamping: bytes),
            countStyle: .file
        )
    }

    private func chooseCatalogDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Catalog Directory"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try CatalogAccess.save(url)
                catalogDirectory = url.path
                selectionError = nil
                setup.clearError()
                setup.refreshStatus()
            } catch {
                selectionError = error.localizedDescription
            }
        }
    }
}
