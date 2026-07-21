import AppKit
import SwiftUI

struct SettingsView: View {
    @AppStorage("catalogDirectory") private var catalogDirectory = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            LabeledContent("Seiza catalogs") {
                HStack {
                    Text(catalogDirectory.isEmpty ? "Use Seiza default" : catalogDirectory)
                        .foregroundStyle(catalogDirectory.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                    Button("Choose…", action: chooseCatalogDirectory)
                    if !catalogDirectory.isEmpty {
                        Button("Reset") {
                            CatalogAccess.reset()
                            catalogDirectory = ""
                        }
                    }
                }
            }
            Text("Use a complete directory installed by `seiza setup` or `seiza download-data prebuilt`. Solving uses the star catalog and blind index; deep-sky overlays use `objects.bin` from the same directory.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(width: 620)
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
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
