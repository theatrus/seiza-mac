import AppKit
import SwiftUI

struct WelcomeView: View {
    let openPanel: () -> Void
    let openURLs: ([URL]) -> Void

    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(red: 7 / 255, green: 16 / 255, blue: 24 / 255))
                Image("SeizaMark")
                    .resizable()
                    .scaledToFit()
                    .padding(10)
            }
            .frame(width: 92, height: 92)
            .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
            .accessibilityHidden(true)
            Text("Seiza")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
            Text("A fast native home for astronomy images")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button("Open Images or Folder…") {
                openPanel()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text("Drop FITS, JPEG, PNG, TIFF, or a folder here")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [8]))
                .padding(20)
                .opacity(isDropTarget ? 1 : 0)
        }
        .dropDestination(for: URL.self) { urls, _ in
            openURLs(urls)
            return !urls.isEmpty
        } isTargeted: { isDropTarget = $0 }
    }
}
