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
            CommandGroup(replacing: .undoRedo) {
                Button("Undo Stretch") {
                    appDelegate.undoImageEdit(nil)
                }
                .keyboardShortcut("z")

                Button("Redo Stretch") {
                    appDelegate.redoImageEdit(nil)
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .appInfo) {
                Button("About Seiza") {
                    appDelegate.showAboutPanel(nil)
                }
                Divider()
                CheckForUpdatesView(updater: appDelegate.updateController.updater)
            }
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    appDelegate.openDocument(nil)
                }
                .keyboardShortcut("o")

                Divider()

                Button("Live Stack…") {
                    appDelegate.openLiveStack(nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
            CommandGroup(after: .saveItem) {
                Button("Export…") {
                    appDelegate.exportDocument(nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandGroup(after: .pasteboard) {
                Button("Copy Image") {
                    appDelegate.copyImage(nil)
                }
                .keyboardShortcut("c")

                Divider()

                Button("Copy Adjustments") {
                    appDelegate.copyImageAdjustments(nil)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button("Paste Adjustments") {
                    appDelegate.pasteImageAdjustments(nil)
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView(updater: appDelegate.updateController.updater)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    let updateController = UpdateController()

    private final class DocumentWindowSession {
        var controller: NSWindowController?
        var collectionTask: Task<Void, Never>?
        let exportCoordinator = ImageExportCoordinator()
        let editCoordinator = ImageEditCommandCoordinator()
        let processingClipboardCoordinator = ImageProcessingClipboardCoordinator()
        private var accessedURLs: [URL] = []

        init(accessURLs: [URL]) {
            for url in accessURLs where url.startAccessingSecurityScopedResource() {
                accessedURLs.append(url)
            }
        }

        deinit {
            collectionTask?.cancel()
            accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        }
    }

    private var documentWindows: [URL: DocumentWindowSession] = [:]
    private weak var welcomeWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.installEditMenuRouting()
        }
    }

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
        panel.message = "Choose FITS, XISF, JPEG, PNG, or TIFF images, or a folder containing them."
        guard panel.runModal() == .OK else { return }
        open(panel.urls)
    }

    @objc func exportDocument(_ sender: Any?) {
        guard let session = activeDocumentSession else {
            NSSound.beep()
            return
        }
        session.exportCoordinator.requestExport()
    }

    @objc func copyImage(_ sender: Any?) {
        guard let session = activeDocumentSession else {
            NSSound.beep()
            return
        }
        session.exportCoordinator.requestCopy()
    }

    @objc func copyImageAdjustments(_ sender: Any?) {
        guard let session = activeDocumentSession else {
            NSSound.beep()
            return
        }
        session.processingClipboardCoordinator.requestCopy()
    }

    @objc func undoImageEdit(_ sender: Any?) {
        guard let session = activeDocumentSession, session.editCoordinator.canUndo else {
            NSSound.beep()
            return
        }
        session.editCoordinator.requestUndo()
    }

    @objc func redoImageEdit(_ sender: Any?) {
        guard let session = activeDocumentSession, session.editCoordinator.canRedo else {
            NSSound.beep()
            return
        }
        session.editCoordinator.requestRedo()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undoImageEdit(_:)):
            return activeDocumentSession?.editCoordinator.canUndo == true
        case #selector(redoImageEdit(_:)):
            return activeDocumentSession?.editCoordinator.canRedo == true
        default:
            return true
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        routeEditCommands(in: menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        routeEditCommands(in: menu)
    }

    @objc func pasteImageAdjustments(_ sender: Any?) {
        guard let session = activeDocumentSession else {
            NSSound.beep()
            return
        }
        session.processingClipboardCoordinator.requestPaste()
    }

    @objc func showAboutPanel(_ sender: Any?) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let credits = NSAttributedString(
            string: AboutDetails.seizaCoreDescription,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraphStyle,
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
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
            refreshEditCommandAvailability()
            closeWelcomeWindow()
            return
        }

        let session = DocumentWindowSession(accessURLs: request.accessURLs)
        observeEditAvailability(for: session)
        let window = NSWindow()
        let controller = NSWindowController(window: window)
        session.controller = controller
        documentWindows[windowKey] = session
        let directImages = directImageRoots(request.roots)
        if let directImages {
            installViewer(
                imageURLs: directImages,
                openedDirectory: directImages.count > 1,
                exportCoordinator: session.exportCoordinator,
                editCoordinator: session.editCoordinator,
                processingClipboardCoordinator: session.processingClipboardCoordinator,
                in: window
            )
        } else {
            installCollectionLoadingView(for: request.roots, in: window)
        }
        window.setContentSize(NSSize(width: 1120, height: 760))
        window.minSize = NSSize(width: 640, height: 420)
        window.styleMask.insert([.resizable, .titled, .closable, .miniaturizable])
        window.tabbingMode = .automatic
        window.titlebarSeparatorStyle = .none
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshEditCommandAvailability()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let window else { return }
                self?.removeDocumentWindow(for: window)
            }
        }
        controller.showWindow(nil)
        DispatchQueue.main.async {
            window.titlebarSeparatorStyle = .none
        }
        closeWelcomeWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        refreshEditCommandAvailability()

        guard directImages == nil else { return }
        let roots = request.roots
        session.collectionTask = Task { [weak self, weak session, weak window] in
            let scan = await Task.detached(priority: .userInitiated) {
                ImageCollection.scan(from: roots)
            }.value
            guard !Task.isCancelled,
                  let self,
                  let session,
                  let window,
                  self.documentWindows[windowKey] === session else { return }
            session.collectionTask = nil
            guard !scan.images.isEmpty else {
                window.close()
                self.presentNoSupportedImagesAlert()
                return
            }
            self.installViewer(
                imageURLs: scan.images,
                openedDirectory: scan.includesDirectory,
                exportCoordinator: session.exportCoordinator,
                editCoordinator: session.editCoordinator,
                processingClipboardCoordinator: session.processingClipboardCoordinator,
                in: window
            )
        }
    }

    func replaceContents(
        of window: NSWindow,
        with urls: [URL],
        additionalAccessURLs: [URL] = []
    ) {
        let request = normalizedRoots(from: urls)
        guard let windowKey = request.roots.first else { return }

        if let existing = documentWindows[windowKey]?.controller,
           existing.window !== window {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let replacement = DocumentWindowSession(
            accessURLs: request.accessURLs + additionalAccessURLs
        )
        observeEditAvailability(for: replacement)
        guard let current = documentWindows.first(where: {
            $0.value.controller?.window === window
        }), let controller = current.value.controller else {
            open(urls)
            return
        }

        if let directImages = directImageRoots(request.roots) {
            finishReplacingContents(
                currentKey: current.key,
                newKey: windowKey,
                session: replacement,
                controller: controller,
                imageURLs: directImages,
                openedDirectory: directImages.count > 1,
                window: window
            )
            return
        }

        let previousController = window.contentViewController
        let previousTitle = window.title
        installCollectionLoadingView(for: request.roots, in: window)
        let roots = request.roots
        current.value.collectionTask?.cancel()
        current.value.collectionTask = Task { [weak self, weak window] in
            let scan = await Task.detached(priority: .userInitiated) {
                ImageCollection.scan(from: roots)
            }.value
            guard !Task.isCancelled,
                  let self,
                  let window,
                  self.documentWindows[current.key] === current.value else { return }
            current.value.collectionTask = nil
            guard !scan.images.isEmpty else {
                window.contentViewController = previousController
                window.title = previousTitle
                self.presentNoSupportedImagesAlert()
                return
            }
            self.finishReplacingContents(
                currentKey: current.key,
                newKey: windowKey,
                session: replacement,
                controller: controller,
                imageURLs: scan.images,
                openedDirectory: scan.includesDirectory,
                window: window
            )
        }
    }

    func documentWindow(for root: URL) -> NSWindow? {
        documentWindows[root.standardizedFileURL]?.controller?.window
    }

    private func installViewer(
        imageURLs: [URL],
        openedDirectory: Bool,
        exportCoordinator: ImageExportCoordinator,
        editCoordinator: ImageEditCommandCoordinator,
        processingClipboardCoordinator: ImageProcessingClipboardCoordinator,
        in window: NSWindow
    ) {
        let view = ViewerView(
            urls: imageURLs,
            showsImageBrowser: openedDirectory,
            exportCoordinator: exportCoordinator,
            editCoordinator: editCoordinator,
            processingClipboardCoordinator: processingClipboardCoordinator,
            onSelectionChange: { [weak window] selectedURL in
                window?.title = selectedURL.lastPathComponent
            },
            onDropURLs: { [weak self, weak window] urls in
                guard let window else { return }
                self?.replaceContents(of: window, with: urls)
            },
            onStackComplete: { [weak self, weak window] result in
                guard let self, let window else { return }
                self.replaceContents(
                    of: window,
                    with: result.results.map(\.output),
                    additionalAccessURLs: result.outputAccessURLs
                )
                let showsSummary = result.results.count > 1
                    || result.rejectedFrames > 0
                    || result.results.contains {
                        $0.snrAnalysis.points.count > 1 || $0.snrWarning != nil
                    }
                if showsSummary {
                    self.presentStackSummary(result, in: window)
                }
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

    private func installCollectionLoadingView(for roots: [URL], in window: NSWindow) {
        let name = roots.first?.lastPathComponent ?? "Images"
        window.contentViewController = NSHostingController(
            rootView: ImageCollectionLoadingView(name: name)
        )
        window.title = "Loading \(name)…"
    }

    private func finishReplacingContents(
        currentKey: URL,
        newKey: URL,
        session: DocumentWindowSession,
        controller: NSWindowController,
        imageURLs: [URL],
        openedDirectory: Bool,
        window: NSWindow
    ) {
        documentWindows.removeValue(forKey: currentKey)
        session.controller = controller
        documentWindows[newKey] = session
        installViewer(
            imageURLs: imageURLs,
            openedDirectory: openedDirectory,
            exportCoordinator: session.exportCoordinator,
            editCoordinator: session.editCoordinator,
            processingClipboardCoordinator: session.processingClipboardCoordinator,
            in: window
        )
        window.makeKeyAndOrderFront(nil)
        refreshEditCommandAvailability()
    }

    private func presentStackSummary(_ result: ImageStackBatchResult, in window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = result.results.count == 1 ? "Stack Complete" : "Stacks Complete"
        var lines = result.results.map { single in
            var line = "\(single.output.lastPathComponent): "
                + "\(single.acceptedFrames) accepted, \(single.rejectedFrames) rejected"
            if single.snrAnalysis.points.count > 1 {
                line += String(
                    format: " · noise %.2f× lower", single.snrAnalysis.noiseImprovement)
            }
            return line
        }
        let warnings = Set(result.results.compactMap(\.snrWarning))
        lines.append(contentsOf: warnings.sorted())
        alert.informativeText = lines.joined(separator: "\n")
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Done")
        if result.results.count == 1, let single = result.results.first,
           single.snrAnalysis.points.count > 1 {
            let analysis = single.snrAnalysis
            let accessory = VStack(alignment: .leading, spacing: 8) {
                StackSnrChartView(points: analysis.points)
                    .frame(width: 400, height: 210)
                Text(Self.describeStackSnr(analysis))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 400, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let hosting = NSHostingView(rootView: accessory)
            hosting.setFrameSize(hosting.fittingSize)
            alert.accessoryView = hosting
        }
        alert.beginSheetModal(for: window)
    }

    static func describeStackSnr(_ analysis: StackSnrAnalysis) -> String {
        String(
            format: "Measured noise improved %.2f×; an ideal square-root stack at "
                + "this depth improves %.2f× (%.0f%% efficiency).",
            analysis.noiseImprovement,
            analysis.idealImprovement,
            analysis.efficiency * 100)
    }

    @objc func openLiveStack(_ sender: Any?) {
        LiveStackWindowController.present(
            initialFolder: activeDocumentRootDirectory()
        ) { [weak self] output in
            self?.open([output])
        }
    }

    private func activeDocumentRootDirectory() -> URL? {
        let candidateWindows = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
        for window in candidateWindows {
            guard let entry = documentWindows.first(where: {
                $0.value.controller?.window === window
            }) else { continue }
            let root = entry.key
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: root.path, isDirectory: &isDirectory)
            else { continue }
            return isDirectory.boolValue ? root : root.deletingLastPathComponent()
        }
        return nil
    }

    private var activeDocumentSession: DocumentWindowSession? {
        let candidateWindows = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
        for window in candidateWindows {
            if let session = documentWindows.values.first(where: {
                $0.controller?.window === window
            }) {
                return session
            }
        }
        return nil
    }

    private func observeEditAvailability(for session: DocumentWindowSession) {
        session.editCoordinator.availabilityDidChange = { [weak self, weak session] in
            guard let self, let session, self.isActive(session) else { return }
            self.refreshEditCommandAvailability()
        }
    }

    private func isActive(_ session: DocumentWindowSession) -> Bool {
        guard let documentWindow = session.controller?.window else { return false }
        if documentWindow.isKeyWindow || documentWindow.isMainWindow {
            return true
        }
        if let keyWindow = NSApp.keyWindow,
           keyWindow.parent === documentWindow || keyWindow.sheetParent === documentWindow {
            return true
        }
        let visibleSessions = documentWindows.values.filter {
            $0.controller?.window?.isVisible == true
        }
        return visibleSessions.count == 1 && visibleSessions[0] === session
    }

    private func refreshEditCommandAvailability() {
        installEditMenuRouting()
        NSApp.mainMenu?.item(withTitle: "Edit")?.submenu?.update()
    }

    private func installEditMenuRouting() {
        guard let editMenu = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu else { return }
        editMenu.delegate = self
        routeEditCommands(in: editMenu)
    }

    private func routeEditCommands(in editMenu: NSMenu) {
        if let undoItem = editMenu.item(withTitle: "Undo Stretch") {
            undoItem.target = self
            undoItem.action = #selector(undoImageEdit(_:))
            undoItem.keyEquivalent = "z"
            undoItem.keyEquivalentModifierMask = [.command]
            undoItem.isEnabled = activeDocumentSession?.editCoordinator.canUndo == true
        }
        if let redoItem = editMenu.item(withTitle: "Redo Stretch") {
            redoItem.target = self
            redoItem.action = #selector(redoImageEdit(_:))
            redoItem.keyEquivalent = "z"
            redoItem.keyEquivalentModifierMask = [.command, .shift]
            redoItem.isEnabled = activeDocumentSession?.editCoordinator.canRedo == true
        }
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

    private func directImageRoots(_ roots: [URL]) -> [URL]? {
        guard roots.allSatisfy({ !$0.hasDirectoryPath && ImageCollection.isSupportedImage($0) })
        else { return nil }
        return roots
    }

    private func removeDocumentWindow(for window: NSWindow) {
        if let entry = documentWindows.first(where: {
            $0.value.controller?.window === window
        }) {
            documentWindows.removeValue(forKey: entry.key)
        }
        refreshEditCommandAvailability()
    }

    private func presentNoSupportedImagesAlert() {
        let alert = NSAlert()
        alert.messageText = "No Supported Images Found"
        alert.informativeText = "Choose a folder containing FITS, XISF, JPEG, PNG, or TIFF images."
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func closeWelcomeWindow() {
        welcomeWindow?.close()
        welcomeWindow = nil
    }
}

private struct ImageCollectionLoadingView: View {
    let name: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Reading \(name)…")
                .font(.headline)
        }
        .frame(minWidth: 560, minHeight: 380)
    }
}

enum AboutDetails {
    static var seizaCoreDescription: String {
        "Seiza Core \(SeizaCore.version)\nCommit \(SeizaCore.gitCommit)"
    }
}
