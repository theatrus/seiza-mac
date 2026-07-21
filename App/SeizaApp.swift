import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct SeizaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            WelcomeView(
                openPanel: {
                    appDelegate.openDocument(nil)
                },
                openURLs: { urls in
                    appDelegate.open(urls)
                }
            )
            .frame(minWidth: 560, minHeight: 380)
            .onAppear {
                appDelegate.registerWelcomeWindow()
            }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    appDelegate.openDocument(nil)
                }
                .keyboardShortcut("o")
            }
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private final class DocumentWindowSession {
        var controller: NSWindowController?
        private var accessedURLs: [URL] = []

        init(accessURLs: [URL]) {
            for url in accessURLs where url.startAccessingSecurityScopedResource() {
                accessedURLs.append(url)
            }
        }

        deinit {
            accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        }
    }

    private var documentWindows: [URL: DocumentWindowSession] = [:]
    private weak var welcomeWindow: NSWindow?

    func registerWelcomeWindow() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let documentWindows = Set(
                self.documentWindows.values.compactMap { $0.controller?.window }
            )
            self.welcomeWindow = NSApp.windows.first {
                $0.title == "Seiza" && !documentWindows.contains($0)
            }
            if !self.documentWindows.isEmpty {
                self.closeWelcomeWindow()
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        open(urls)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        open(filenames.map(URL.init(fileURLWithPath:)))
        sender.reply(toOpenOrPrint: .success)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = UTType.seizaSupportedImages + [.folder]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Choose FITS, JPEG, PNG, or TIFF images, or a folder containing them."
        guard panel.runModal() == .OK else { return }
        open(panel.urls)
    }

    func open(_ url: URL) {
        open([url])
    }

    func open(_ urls: [URL]) {
        var seenRoots = Set<URL>()
        var roots: [URL] = []
        var accessURLs: [URL] = []
        for url in urls {
            let canonicalURL = url.standardizedFileURL
            if seenRoots.insert(canonicalURL).inserted {
                roots.append(canonicalURL)
                accessURLs.append(url)
            }
        }
        guard let windowKey = roots.first else { return }

        if let existing = documentWindows[windowKey]?.controller {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            closeWelcomeWindow()
            return
        }

        let session = DocumentWindowSession(accessURLs: accessURLs)
        let imageURLs = ImageCollection.collect(from: roots)
        guard !imageURLs.isEmpty else {
            presentNoSupportedImagesAlert()
            return
        }
        let openedDirectory = roots.contains { root in
            (try? root.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }

        let window = NSWindow()
        let view = ViewerView(
            urls: imageURLs,
            showsImageBrowser: openedDirectory
        ) { [weak window] selectedURL in
            window?.title = selectedURL.lastPathComponent
        }
        window.contentViewController = NSHostingController(rootView: view)
        window.title = imageURLs[0].lastPathComponent
        window.setContentSize(NSSize(width: 1120, height: 760))
        window.minSize = NSSize(width: 640, height: 420)
        window.styleMask.insert([.resizable, .titled, .closable, .miniaturizable])
        window.tabbingMode = .automatic
        window.titlebarSeparatorStyle = .none
        let controller = NSWindowController(window: window)
        session.controller = controller
        documentWindows[windowKey] = session
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.documentWindows.removeValue(forKey: windowKey)
        }
        controller.showWindow(nil)
        DispatchQueue.main.async {
            window.titlebarSeparatorStyle = .none
        }
        closeWelcomeWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func presentNoSupportedImagesAlert() {
        let alert = NSAlert()
        alert.messageText = "No Supported Images Found"
        alert.informativeText = "Choose a folder containing FITS, JPEG, PNG, or TIFF images."
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func closeWelcomeWindow() {
        welcomeWindow?.close()
        welcomeWindow = nil
    }
}
