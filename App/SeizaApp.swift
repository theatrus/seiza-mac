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
        let request = normalizedRoots(from: urls)
        guard let windowKey = request.roots.first else { return }

        if let existing = documentWindows[windowKey]?.controller {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            closeWelcomeWindow()
            return
        }

        let session = DocumentWindowSession(accessURLs: request.accessURLs)
        let imageURLs = ImageCollection.collect(from: request.roots)
        guard !imageURLs.isEmpty else {
            presentNoSupportedImagesAlert()
            return
        }

        let window = NSWindow()
        let controller = NSWindowController(window: window)
        session.controller = controller
        documentWindows[windowKey] = session
        installViewer(
            imageURLs: imageURLs,
            openedDirectory: containsDirectory(request.roots),
            in: window
        )
        window.setContentSize(NSSize(width: 1120, height: 760))
        window.minSize = NSSize(width: 640, height: 420)
        window.styleMask.insert([.resizable, .titled, .closable, .miniaturizable])
        window.tabbingMode = .automatic
        window.titlebarSeparatorStyle = .none
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            guard let window else { return }
            self?.removeDocumentWindow(for: window)
        }
        controller.showWindow(nil)
        DispatchQueue.main.async {
            window.titlebarSeparatorStyle = .none
        }
        closeWelcomeWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func replaceContents(of window: NSWindow, with urls: [URL]) {
        let request = normalizedRoots(from: urls)
        guard let windowKey = request.roots.first else { return }

        if let existing = documentWindows[windowKey]?.controller,
           existing.window !== window {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let replacement = DocumentWindowSession(accessURLs: request.accessURLs)
        let imageURLs = ImageCollection.collect(from: request.roots)
        guard !imageURLs.isEmpty else {
            presentNoSupportedImagesAlert()
            return
        }
        guard let current = documentWindows.first(where: {
            $0.value.controller?.window === window
        }), let controller = current.value.controller else {
            open(urls)
            return
        }

        documentWindows.removeValue(forKey: current.key)
        replacement.controller = controller
        documentWindows[windowKey] = replacement
        installViewer(
            imageURLs: imageURLs,
            openedDirectory: containsDirectory(request.roots),
            in: window
        )
        window.makeKeyAndOrderFront(nil)
    }

    func documentWindow(for root: URL) -> NSWindow? {
        documentWindows[root.standardizedFileURL]?.controller?.window
    }

    private func installViewer(
        imageURLs: [URL],
        openedDirectory: Bool,
        in window: NSWindow
    ) {
        let view = ViewerView(
            urls: imageURLs,
            showsImageBrowser: openedDirectory,
            onSelectionChange: { [weak window] selectedURL in
                window?.title = selectedURL.lastPathComponent
            },
            onDropURLs: { [weak self, weak window] urls in
                guard let window else { return }
                self?.replaceContents(of: window, with: urls)
            }
        )
        if let hostingController = window.contentViewController
            as? NSHostingController<ViewerView> {
            hostingController.rootView = view
        } else {
            window.contentViewController = NSHostingController(rootView: view)
        }
        window.title = imageURLs[0].lastPathComponent
    }

    private func normalizedRoots(from urls: [URL]) -> (roots: [URL], accessURLs: [URL]) {
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
        return (roots, accessURLs)
    }

    private func containsDirectory(_ roots: [URL]) -> Bool {
        roots.contains { root in
            (try? root.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    private func removeDocumentWindow(for window: NSWindow) {
        if let entry = documentWindows.first(where: {
            $0.value.controller?.window === window
        }) {
            documentWindows.removeValue(forKey: entry.key)
        }
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
