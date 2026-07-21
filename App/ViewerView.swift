import AppKit
import Combine
import SwiftUI

private extension DeepSkyCatalog {
    var overlayColor: Color {
        switch self {
        case .messier: Color(red: 242.0 / 255.0, green: 202.0 / 255.0, blue: 114.0 / 255.0)
        case .ngc: Color(red: 85.0 / 255.0, green: 207.0 / 255.0, blue: 1)
        case .ic: Color(red: 114.0 / 255.0, green: 223.0 / 255.0, blue: 185.0 / 255.0)
        case .sharplessVDB: Color(red: 238.0 / 255.0, green: 154.0 / 255.0, blue: 120.0 / 255.0)
        case .lbn: Color(red: 162.0 / 255.0, green: 217.0 / 255.0, blue: 111.0 / 255.0)
        case .cederblad: Color(red: 112.0 / 255.0, green: 215.0 / 255.0, blue: 208.0 / 255.0)
        case .darkNebulae: Color(red: 180.0 / 255.0, green: 163.0 / 255.0, blue: 240.0 / 255.0)
        case .supernovaRemnants: Color(red: 241.0 / 255.0, green: 135.0 / 255.0, blue: 130.0 / 255.0)
        case .ugc: Color(red: 121.0 / 255.0, green: 175.0 / 255.0, blue: 245.0 / 255.0)
        case .pgc: Color(red: 161.0 / 255.0, green: 174.0 / 255.0, blue: 216.0 / 255.0)
        case .other: Color(red: 193.0 / 255.0, green: 209.0 / 255.0, blue: 211.0 / 255.0)
        }
    }
}

struct ViewerView: View {
    let urls: [URL]
    let showsImageBrowser: Bool
    let exportCoordinator: ImageExportCoordinator
    let onSelectionChange: (URL) -> Void
    let onDropURLs: ([URL]) -> Void

    @State private var selectedIndex: Int
    @State private var model: ImageDocumentModel
    @State private var showInspector = false
    @State private var showImageBrowser: Bool
    @State private var isDropTarget = false

    init(
        urls: [URL],
        initialIndex: Int = 0,
        showsImageBrowser: Bool = false,
        exportCoordinator: ImageExportCoordinator,
        onSelectionChange: @escaping (URL) -> Void = { _ in },
        onDropURLs: @escaping ([URL]) -> Void = { _ in }
    ) {
        self.urls = urls
        self.showsImageBrowser = showsImageBrowser
        self.exportCoordinator = exportCoordinator
        self.onSelectionChange = onSelectionChange
        self.onDropURLs = onDropURLs
        let selectedIndex = min(max(initialIndex, 0), max(urls.count - 1, 0))
        _selectedIndex = State(initialValue: selectedIndex)
        _model = State(initialValue: ImageDocumentModel(url: urls[selectedIndex]))
        _showImageBrowser = State(initialValue: showsImageBrowser)
    }

    var body: some View {
        HSplitView {
            if showsImageBrowser && showImageBrowser {
                ImageBrowserDrawer(
                    urls: urls,
                    selectedIndex: $selectedIndex,
                    select: select
                )
                .frame(minWidth: 170, idealWidth: 210, maxWidth: 280)
            }

            ImagePageView(
                model: model,
                exportCoordinator: exportCoordinator,
                showInspector: $showInspector,
                position: selectedIndex + 1,
                itemCount: urls.count,
                canGoPrevious: selectedIndex > 0,
                canGoNext: selectedIndex + 1 < urls.count,
                goPrevious: { move(by: -1) },
                goNext: { move(by: 1) }
            )
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [8]))
                .padding(8)
                .opacity(isDropTarget ? 1 : 0)
                .allowsHitTesting(false)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            onDropURLs(urls)
            return true
        } isTargeted: { isDropTarget = $0 }
        .onAppear {
            onSelectionChange(currentURL)
        }
        .toolbar {
            if showsImageBrowser {
                ToolbarItem(placement: .navigation) {
                    Button {
                        showImageBrowser.toggle()
                    } label: {
                        Label("Image Browser", systemImage: "sidebar.left")
                    }
                    .help(showImageBrowser ? "Hide Image Browser" : "Show Image Browser")
                }
            }
        }
    }

    private var currentURL: URL {
        urls[selectedIndex]
    }

    private func move(by offset: Int) {
        let newIndex = min(max(selectedIndex + offset, 0), urls.count - 1)
        select(newIndex)
    }

    private func select(_ index: Int) {
        guard urls.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
        model = ImageDocumentModel(url: urls[index])
        onSelectionChange(urls[index])
    }
}

private struct ImageBrowserDrawer: View {
    let urls: [URL]
    @Binding var selectedIndex: Int
    let select: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Images")
                    .font(.headline)
                Spacer()
                Text(urls.count.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(urls.indices, id: \.self) { index in
                            Button {
                                select(index)
                            } label: {
                                ImageBrowserRow(
                                    url: urls[index],
                                    isSelected: index == selectedIndex
                                )
                            }
                            .buttonStyle(.plain)
                            .id(index)
                            .accessibilityLabel(urls[index].lastPathComponent)
                            .accessibilityValue(index == selectedIndex ? "Selected" : "")
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selectedIndex) { _, newIndex in
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                    prefetch(around: newIndex)
                }
            }
        }
        .background(.background)
        .onAppear {
            prefetch(around: selectedIndex)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Image Browser")
    }

    private func prefetch(around index: Int) {
        let lowerBound = max(index - 4, urls.startIndex)
        let upperBound = min(index + 5, urls.endIndex)
        ImageThumbnailCache.prefetch(Array(urls[lowerBound..<upperBound]))
    }
}

private struct ImageBrowserRow: View {
    let url: URL
    let isSelected: Bool

    @StateObject private var model: ImageThumbnailModel

    init(url: URL, isSelected: Bool) {
        self.url = url
        self.isSelected = isSelected
        _model = StateObject(wrappedValue: ImageThumbnailModel(url: url))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.black.opacity(0.92))

                if let image = model.image {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                } else if model.failed {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            Text(url.lastPathComponent)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : .clear)
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.accentColor.opacity(0.8), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
    }
}

private final class ImageThumbnailModel: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published private(set) var failed = false

    init(url: URL) {
        if let cached = ImageThumbnailCache.memoryImage(for: url) {
            image = cached
            return
        }

        ImageThumbnailCache.load(for: url) { [weak self] cached in
            if let cached {
                DispatchQueue.main.async {
                    self?.image = cached
                }
                return
            }
            ImageThumbnailCache.render(for: url) { [weak self] thumbnail in
                if let thumbnail {
                    self?.image = thumbnail
                } else {
                    self?.failed = true
                }
            }
        }
    }
}

private struct ImagePageView: View {
    private static let zoomRange = 0.01...8.0
    private static let zoomStep = 1.25

    private struct CanvasMetrics {
        let imageSize: CGSize
        let canvasSize: CGSize
        let imageOrigin: CGPoint
    }

    private struct ZoomAnchor {
        let viewportPoint: CGPoint
        let imagePoint: CGPoint
    }

    let position: Int
    let itemCount: Int
    let canGoPrevious: Bool
    let canGoNext: Bool
    let goPrevious: () -> Void
    let goNext: () -> Void

    @Environment(\.displayScale) private var displayScale
    @ObservedObject private var model: ImageDocumentModel
    @ObservedObject private var exportCoordinator: ImageExportCoordinator
    @ObservedObject private var catalogSetup = CatalogSetupController.shared
    @State private var zoom = 1.0
    @State private var pinchStartZoom: Double?
    @State private var pinchAnchor: ZoomAnchor?
    @State private var scrollPosition = ScrollPosition()
    @State private var visibleContentOrigin = CGPoint.zero
    @Binding private var showInspector: Bool
    @State private var viewportSize = CGSize.zero
    @State private var isFitToWindow = true
    @State private var showDeepSky = true
    @State private var showNamedStars = true
    @State private var showTransients = true
    @State private var showHistoricalTransients = false
    @State private var showMinorBodies = true
    @State private var showCoordinateGrid = true
    @State private var showCatalogOutlines = true
    @State private var showObjectLabels = true
    @State private var showDetectedStars = false
    @State private var showFieldStars = false
    @State private var showFieldCenter = true
    @State private var hiddenDeepSkyCatalogs = Set<DeepSkyCatalog>()
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var showStretchControls = false
    @State private var stretchDraftStages = [FITSStretchConfiguration.default]
    @State private var selectedStretchStageIndex = 0
    @State private var extractsBackgroundDraft = false
    @State private var isPickingSymmetryPoint = false

    init(
        model: ImageDocumentModel,
        exportCoordinator: ImageExportCoordinator,
        showInspector: Binding<Bool>,
        position: Int,
        itemCount: Int,
        canGoPrevious: Bool,
        canGoNext: Bool,
        goPrevious: @escaping () -> Void,
        goNext: @escaping () -> Void
    ) {
        self.position = position
        self.itemCount = itemCount
        self.canGoPrevious = canGoPrevious
        self.canGoNext = canGoNext
        self.goPrevious = goPrevious
        self.goNext = goNext
        _showInspector = showInspector
        _model = ObservedObject(wrappedValue: model)
        _exportCoordinator = ObservedObject(wrappedValue: exportCoordinator)
    }

    var body: some View {
        HSplitView {
            imagePane
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            if showInspector {
                InspectorView(model: model)
                    .frame(minWidth: 260, idealWidth: 310, maxWidth: 390)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if itemCount > 1 {
                    Button(action: goPrevious) {
                        Label("Previous Image", systemImage: "chevron.left")
                    }
                    .disabled(!canGoPrevious)
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .help("Previous Image (←)")

                    ZStack {
                        Text("\(itemCount) of \(itemCount)")
                            .hidden()
                            .accessibilityHidden(true)
                        Text("\(position) of \(itemCount)")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Image \(position) of \(itemCount)")
                    }
                    .font(.callout.monospacedDigit())
                    .fixedSize()

                    Button(action: goNext) {
                        Label("Next Image", systemImage: "chevron.right")
                    }
                    .disabled(!canGoNext)
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .help("Next Image (→)")
                }

                Button(action: model.undoStretch) {
                    Label("Undo Stretch", systemImage: "arrow.uturn.backward")
                }
                .disabled(!model.supportsFITSStretch || !model.stretchHistory.canUndo)
                .keyboardShortcut("z", modifiers: .command)
                .help("Undo Last Stretch (⌘Z)")

                Button(action: model.redoStretch) {
                    Label("Redo Stretch", systemImage: "arrow.uturn.forward")
                }
                .disabled(!model.supportsFITSStretch || !model.stretchHistory.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .help("Redo Stretch (⇧⌘Z)")

                Button {
                    stretchDraftStages = model.stretchHistory.appliedStages
                    selectedStretchStageIndex = stretchDraftStages.count - 1
                    extractsBackgroundDraft = model.extractsBackground
                    showStretchControls.toggle()
                } label: {
                    Label("Stretch", systemImage: "slider.horizontal.3")
                }
                .disabled(!model.supportsFITSStretch)
                .help(
                    model.supportsFITSStretch
                        ? "Stretch: \(model.stretchConfiguration.type.title)"
                        : "Stretch controls are available for FITS images"
                )
                .popover(isPresented: $showStretchControls, arrowEdge: .bottom) {
                    FITSStretchControlsView(
                        stages: $stretchDraftStages,
                        selectedStageIndex: $selectedStretchStageIndex,
                        extractsBackground: $extractsBackgroundDraft,
                        supportsColor: model.supportsColorStretch,
                        canUndo: model.stretchHistory.canUndo,
                        canRedo: model.stretchHistory.canRedo,
                        isPreviewRendering: model.isPreviewRendering,
                        previewError: model.previewError,
                        undo: {
                            model.undoStretch()
                            stretchDraftStages = model.stretchHistory.appliedStages
                            selectedStretchStageIndex = stretchDraftStages.count - 1
                            extractsBackgroundDraft = model.extractsBackground
                        },
                        redo: {
                            model.redoStretch()
                            stretchDraftStages = model.stretchHistory.appliedStages
                            selectedStretchStageIndex = stretchDraftStages.count - 1
                            extractsBackgroundDraft = model.extractsBackground
                        },
                        pickSymmetryPoint: {
                            showStretchControls = false
                            isPickingSymmetryPoint = true
                        },
                        preview: { stack, extractsBackground in
                            model.preview(
                                stretchStack: stack,
                                extractsBackground: extractsBackground
                            )
                        },
                        clearPreview: model.cancelPreview,
                        save: { stack, extractsBackground in
                            model.replaceStretchStack(
                                with: stack,
                                extractsBackground: extractsBackground
                            )
                            showStretchControls = false
                        },
                        cancel: {
                            model.cancelPreview()
                            showStretchControls = false
                        }
                    )
                }

                Button {
                    showInspector = true
                    model.solve(catalogDirectory: CatalogAccess.resolve())
                } label: {
                    if isSolving {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Solving image")
                    } else {
                        Label("Solve", systemImage: "scope")
                    }
                }
                .disabled(isSolving || model.image == nil)
                .help(solveHelp)

                Menu {
                    Toggle(overlayLabel("Deep Sky", key: "deep_sky"), isOn: $showDeepSky)
                        .disabled(!overlayAvailable("deep_sky"))
                        .help(overlayHelp("deep_sky"))
                    Toggle(
                        overlayLabel("Named Stars", key: "named_stars"),
                        isOn: $showNamedStars
                    )
                    .disabled(!overlayAvailable("named_stars"))
                    .help(overlayHelp("named_stars"))
                    Toggle(
                        overlayLabel("Transients", key: "transients"),
                        isOn: $showTransients
                    )
                    .disabled(!overlayAvailable("transients"))
                    .help(overlayHelp("transients"))
                    Toggle(
                        overlayLabel("Older Transients", key: "historical_transients"),
                        isOn: $showHistoricalTransients
                    )
                    .disabled(!showTransients || !overlayAvailable("historical_transients"))
                    .help(overlayHelp("historical_transients"))
                    Toggle(
                        overlayLabel("Solar System", key: "minor_bodies"),
                        isOn: $showMinorBodies
                    )
                    .disabled(!overlayAvailable("minor_bodies"))
                    .help(overlayHelp("minor_bodies"))

                    Menu {
                        ForEach(availableDeepSkyCatalogs) { catalog in
                            Toggle(isOn: catalogVisibility(catalog)) {
                                Label {
                                    Text("\(catalog.title) · \(deepSkyCatalogCount(catalog))")
                                } icon: {
                                    Image(systemName: "circle.fill")
                                        .foregroundStyle(catalog.overlayColor)
                                }
                            }
                        }
                    } label: {
                        Text("Deep-Sky Catalogs")
                    }
                    .disabled(!showDeepSky || availableDeepSkyCatalogs.isEmpty)

                    Toggle("Detailed OpenNGC Outlines", isOn: $showCatalogOutlines)
                        .disabled(!showDeepSky || !hasCatalogOutlines)
                    Toggle("Object Labels", isOn: $showObjectLabels)
                        .disabled(!hasVisibleObjectLayer)

                    Divider()

                    Toggle(
                        overlayLabel("Field Stars", key: "field_stars"),
                        isOn: $showFieldStars
                    )
                    .disabled(!overlayAvailable("field_stars"))
                    Toggle("RA / Dec Grid", isOn: $showCoordinateGrid)
                    Toggle("Field Center", isOn: $showFieldCenter)

                    Divider()

                    Toggle("Detected Stars", isOn: $showDetectedStars)

                    Divider()

                    Button("Hide All Overlays") {
                        showDeepSky = false
                        showNamedStars = false
                        showTransients = false
                        showHistoricalTransients = false
                        showMinorBodies = false
                        showObjectLabels = false
                        showDetectedStars = false
                        showFieldStars = false
                        showCoordinateGrid = false
                        showFieldCenter = false
                    }
                    .disabled(!hasVisibleOverlays)
                } label: {
                    Label("Overlays", systemImage: "square.3.layers.3d")
                }
                .disabled(solvedSolution == nil)
                .help(solvedSolution == nil ? "Solve the image to enable overlays" : "Solve Overlays")

                Button {
                    presentExportPanel()
                } label: {
                    if isExporting {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Exporting image")
                    } else {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(model.image == nil || isExporting)
                .help("Export Image…")

                Button {
                    changeZoom(by: 1 / Self.zoomStep)
                } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }
                .help("Zoom Out")
                .keyboardShortcut("-", modifiers: .command)

                Button {
                    fitToWindow()
                } label: {
                    Label("Zoom to Fit", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .help("Zoom to Fit")
                .keyboardShortcut("0", modifiers: .command)

                Button {
                    changeZoom(by: Self.zoomStep)
                } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }
                .help("Zoom In")
                .keyboardShortcut("+", modifiers: .command)

                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
            }
        }
        .onChange(of: model.url) { _, _ in
            zoom = 1
            pinchStartZoom = nil
            pinchAnchor = nil
            scrollToOrigin()
            isFitToWindow = true
            if let image = model.image ?? model.previewImage {
                applyFitZoom(image: image, viewport: viewportSize)
            }
        }
        .onAppear {
            catalogSetup.refreshStatus()
        }
        .onChange(of: exportCoordinator.requestNumber) { _, _ in
            guard model.image != nil, !isExporting else {
                NSSound.beep()
                return
            }
            presentExportPanel()
        }
        .alert(
            "Couldn’t Export Image",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            ),
            actions: {
                Button("OK", role: .cancel) {}
            },
            message: {
                Text(exportError ?? "An unknown error occurred.")
            }
        )
    }

    @MainActor
    private func presentExportPanel() {
        guard let image = model.exportImage else {
            NSSound.beep()
            return
        }

        let overlaysAvailable = solvedSolution != nil && hasVisibleOverlays
        let options = ImageExportOptions(overlaysAvailable: overlaysAvailable)
        let panel = NSSavePanel()
        panel.title = "Export Image"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [options.format.contentType]
        panel.nameFieldStringValue = model.url.deletingPathExtension()
            .lastPathComponent + "." + options.format.fileExtension
        panel.accessoryView = NSHostingView(
            rootView: ImageExportAccessoryView(
                options: options,
                overlaysAvailable: overlaysAvailable
            )
        )

        let formatObserver = options.$format.dropFirst().sink { format in
            panel.allowedContentTypes = [format.contentType]
            let stem = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = stem + "." + format.fileExtension
        }
        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            withExtendedLifetime(formatObserver) {}
            return
        }
        withExtendedLifetime(formatObserver) {}

        let exportedImage: CGImage
        if options.includesVisibleOverlays,
           let solution = solvedSolution,
           let composited = renderExportImage(image: image, solution: solution) {
            exportedImage = composited
        } else {
            exportedImage = image
        }

        isExporting = true
        let format = options.format
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try ImageFileWriter.write(
                    exportedImage,
                    to: destinationURL,
                    format: format
                )
            }
            DispatchQueue.main.async {
                isExporting = false
                if case .failure(let error) = result {
                    exportError = error.localizedDescription
                }
            }
        }
    }

    @MainActor
    private func renderExportImage(
        image: CGImage,
        solution: SolveResult
    ) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        let renderer = ImageRenderer(
            content: ExportImageView(
                image: image,
                solution: solution,
                sourceSize: size,
                showsDeepSky: showDeepSky,
                showsNamedStars: showNamedStars,
                showsTransients: showTransients,
                showsHistoricalTransients: showHistoricalTransients,
                showsMinorBodies: showMinorBodies,
                showsCoordinateGrid: showCoordinateGrid,
                showsCatalogOutlines: showCatalogOutlines,
                showsObjectLabels: showObjectLabels,
                showsDetectedStars: showDetectedStars,
                showsFieldStars: showFieldStars,
                showsFieldCenter: showFieldCenter,
                hiddenDeepSkyCatalogs: hiddenDeepSkyCatalogs
            )
        )
        renderer.scale = 1
        renderer.isOpaque = true
        renderer.proposedSize = ProposedViewSize(size)
        return renderer.cgImage
    }

    private var solveHelp: String {
        if isSolving { return "Solving image…" }
        if let status = catalogSetup.status, !status.readyForSolving {
            return "Plate Solve — catalog setup required in Settings"
        }
        return "Plate Solve"
    }

    @ViewBuilder
    private var imagePane: some View {
        switch model.loadState {
        case .loading, .loaded:
            if let image = model.image {
                imageCanvas(image: image, showsLoadingIndicator: isLoading)
            } else if let previewImage = model.previewImage {
                imageCanvas(image: previewImage, showsLoadingIndicator: isLoading)
            } else {
                ProgressView("Reading image…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .failed(let message):
            ContentUnavailableView(
                "Couldn’t Open Image",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        }
    }

    private var isLoading: Bool {
        if case .loading = model.loadState { true } else { false }
    }

    private func imageCanvas(
        image: CGImage,
        showsLoadingIndicator: Bool
    ) -> some View {
        GeometryReader { geometry in
            let metrics = canvasMetrics(
                for: image,
                viewport: geometry.size,
                zoom: zoom
            )

            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Color.black
                    ZStack(alignment: .topLeading) {
                        Image(decorative: image, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: metrics.imageSize.width, height: metrics.imageSize.height)
                            .clipped(antialiased: false)

                        if let solution = solvedSolution, hasVisibleOverlays {
                            SolveOverlayView(
                                solution: solution,
                                sourceSize: sourceSize(for: image),
                                showsDeepSky: showDeepSky,
                                showsNamedStars: showNamedStars,
                                showsTransients: showTransients,
                                showsHistoricalTransients: showHistoricalTransients,
                                showsMinorBodies: showMinorBodies,
                                showsCoordinateGrid: showCoordinateGrid,
                                showsCatalogOutlines: showCatalogOutlines,
                                showsObjectLabels: showObjectLabels,
                                showsDetectedStars: showDetectedStars,
                                showsFieldStars: showFieldStars,
                                showsFieldCenter: showFieldCenter,
                                hiddenDeepSkyCatalogs: hiddenDeepSkyCatalogs
                            )
                            .frame(width: metrics.imageSize.width, height: metrics.imageSize.height)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                    }
                    .frame(width: metrics.imageSize.width, height: metrics.imageSize.height)
                    .offset(x: metrics.imageOrigin.x, y: metrics.imageOrigin.y)
                }
                .frame(width: metrics.canvasSize.width, height: metrics.canvasSize.height)
            }
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGPoint.self) { geometry in
                geometry.visibleRect.origin
            } action: { _, newOrigin in
                visibleContentOrigin = newOrigin
            }
            .background(.black.opacity(0.94))
            .simultaneousGesture(pinchGesture(for: image, viewport: geometry.size))
            .overlay(alignment: .bottomTrailing) {
                if showsLoadingIndicator {
                    ProgressView()
                        .controlSize(.small)
                        .padding(8)
                        .background(.regularMaterial, in: Circle())
                        .padding(12)
                        .accessibilityLabel("Loading full-resolution image")
                }
            }
            .overlay {
                if isPickingSymmetryPoint {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            SpatialTapGesture()
                                .onEnded { value in
                                    captureSymmetryPoint(
                                        at: value.location,
                                        image: image,
                                        viewport: geometry.size
                                    )
                                }
                        )
                }
            }
            .overlay(alignment: .bottom) {
                if isPickingSymmetryPoint {
                    HStack(spacing: 10) {
                        Label(
                            "Click the image to sample the GHS symmetry point",
                            systemImage: "eyedropper"
                        )
                        Button("Cancel") {
                            isPickingSymmetryPoint = false
                            showStretchControls = true
                        }
                        .controlSize(.small)
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(14)
                }
            }
            .onAppear {
                viewportSize = geometry.size
                if isFitToWindow {
                    applyFitZoom(image: image, viewport: geometry.size)
                }
            }
            .onChange(of: geometry.size) { _, newSize in
                viewportSize = newSize
                if isFitToWindow {
                    applyFitZoom(image: image, viewport: newSize)
                }
            }
            .onChange(of: sourceSize(for: image)) { _, _ in
                if isFitToWindow {
                    applyFitZoom(image: image, viewport: geometry.size)
                }
            }
        }
    }

    private func pinchGesture(
        for image: CGImage,
        viewport: CGSize
    ) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchStartZoom == nil {
                    pinchStartZoom = zoom
                    pinchAnchor = makeZoomAnchor(
                        at: value.startLocation,
                        image: image,
                        viewport: viewport
                    )
                    isFitToWindow = false
                }
                guard let pinchAnchor else { return }
                let startZoom = pinchStartZoom ?? zoom
                applyZoom(
                    startZoom * Double(value.magnification),
                    around: pinchAnchor,
                    image: image,
                    viewport: viewport
                )
            }
            .onEnded { value in
                let anchor = pinchAnchor ?? makeZoomAnchor(
                    at: value.startLocation,
                    image: image,
                    viewport: viewport
                )
                let startZoom = pinchStartZoom ?? zoom
                applyZoom(
                    startZoom * Double(value.magnification),
                    around: anchor,
                    image: image,
                    viewport: viewport
                )
                pinchStartZoom = nil
                pinchAnchor = nil
            }
    }

    private func captureSymmetryPoint(
        at location: CGPoint,
        image: CGImage,
        viewport: CGSize
    ) {
        let metrics = canvasMetrics(for: image, viewport: viewport, zoom: zoom)
        let contentPoint = CGPoint(
            x: visibleContentOrigin.x + location.x,
            y: visibleContentOrigin.y + location.y
        )
        let normalizedPoint = CGPoint(
            x: (contentPoint.x - metrics.imageOrigin.x) / metrics.imageSize.width,
            y: (contentPoint.y - metrics.imageOrigin.y) / metrics.imageSize.height
        )
        guard (0...1).contains(normalizedPoint.x),
              (0...1).contains(normalizedPoint.y) else { return }

        let x = min(Int((normalizedPoint.x * CGFloat(image.width)).rounded(.down)), image.width - 1)
        let y = min(Int((normalizedPoint.y * CGFloat(image.height)).rounded(.down)), image.height - 1)
        guard let sample = ImagePixelSampler.normalizedLuminance(image: image, x: x, y: y) else {
            return
        }

        var configuration = stretchDraftStages[selectedStretchStageIndex]
        configuration.type = .ghs
        configuration.symmetryPoint = sample
        configuration.protectShadows = min(configuration.protectShadows, sample)
        configuration.protectHighlights = max(configuration.protectHighlights, sample)
        stretchDraftStages[selectedStretchStageIndex] = configuration
        isPickingSymmetryPoint = false
        showStretchControls = true
    }

    private func clampedZoom(_ value: Double) -> Double {
        min(max(value, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }

    private func changeZoom(by factor: Double) {
        isFitToWindow = false
        guard let image = model.image ?? model.previewImage else {
            zoom = clampedZoom(zoom * factor)
            return
        }
        let viewportPoint = CGPoint(
            x: viewportSize.width / 2,
            y: viewportSize.height / 2
        )
        let anchor = makeZoomAnchor(
            at: viewportPoint,
            image: image,
            viewport: viewportSize
        )
        applyZoom(
            zoom * factor,
            around: anchor,
            image: image,
            viewport: viewportSize
        )
    }

    private func fitToWindow() {
        guard let image = model.image else { return }
        isFitToWindow = true
        applyFitZoom(image: image, viewport: viewportSize)
    }

    private func applyFitZoom(image: CGImage, viewport: CGSize) {
        guard viewport.width > 0, viewport.height > 0 else { return }
        let sourceSize = sourceSize(for: image)
        let horizontalScale = viewport.width / sourceSize.width
        let verticalScale = viewport.height / sourceSize.height
        zoom = clampedZoom(Double(min(horizontalScale, verticalScale)))
        scrollToOrigin()
    }

    private func makeZoomAnchor(
        at location: CGPoint,
        image: CGImage,
        viewport: CGSize
    ) -> ZoomAnchor {
        let viewportPoint = CGPoint(
            x: min(max(location.x, 0), viewport.width),
            y: min(max(location.y, 0), viewport.height)
        )
        let metrics = canvasMetrics(for: image, viewport: viewport, zoom: zoom)
        return ZoomAnchor(
            viewportPoint: viewportPoint,
            imagePoint: CGPoint(
                x: (visibleContentOrigin.x + viewportPoint.x - metrics.imageOrigin.x)
                    / metrics.imageSize.width,
                y: (visibleContentOrigin.y + viewportPoint.y - metrics.imageOrigin.y)
                    / metrics.imageSize.height
            )
        )
    }

    private func applyZoom(
        _ requestedZoom: Double,
        around anchor: ZoomAnchor,
        image: CGImage,
        viewport: CGSize
    ) {
        let newZoom = clampedZoom(requestedZoom)
        zoom = newZoom
        let metrics = canvasMetrics(for: image, viewport: viewport, zoom: newZoom)
        let requestedOrigin = CGPoint(
            x: metrics.imageOrigin.x
                + anchor.imagePoint.x * metrics.imageSize.width
                - anchor.viewportPoint.x,
            y: metrics.imageOrigin.y
                + anchor.imagePoint.y * metrics.imageSize.height
                - anchor.viewportPoint.y
        )
        let maximumOrigin = CGPoint(
            x: max(metrics.canvasSize.width - viewport.width, 0),
            y: max(metrics.canvasSize.height - viewport.height, 0)
        )
        scrollPosition.scrollTo(
            point: CGPoint(
                x: min(max(requestedOrigin.x, 0), maximumOrigin.x),
                y: min(max(requestedOrigin.y, 0), maximumOrigin.y)
            )
        )
    }

    private func scrollToOrigin() {
        visibleContentOrigin = .zero
        scrollPosition.scrollTo(point: .zero)
    }

    private func canvasMetrics(
        for image: CGImage,
        viewport: CGSize,
        zoom: Double
    ) -> CanvasMetrics {
        let imageSize = displayedSize(for: image, zoom: zoom)
        let canvasSize = CGSize(
            width: max(imageSize.width, viewport.width),
            height: max(imageSize.height, viewport.height)
        )
        return CanvasMetrics(
            imageSize: imageSize,
            canvasSize: canvasSize,
            imageOrigin: CGPoint(
                x: pixelAlignedOrigin((canvasSize.width - imageSize.width) / 2),
                y: pixelAlignedOrigin((canvasSize.height - imageSize.height) / 2)
            )
        )
    }

    private func displayedSize(for image: CGImage, zoom: Double) -> CGSize {
        let sourceSize = sourceSize(for: image)
        return CGSize(
            width: pixelAlignedLength(sourceSize.width * zoom),
            height: pixelAlignedLength(sourceSize.height * zoom)
        )
    }

    private func sourceSize(for image: CGImage) -> CGSize {
        guard let metadata = model.metadata, metadata.width > 0, metadata.height > 0 else {
            return CGSize(width: image.width, height: image.height)
        }
        return CGSize(width: metadata.width, height: metadata.height)
    }

    private func pixelAlignedLength(_ value: CGFloat) -> CGFloat {
        (value * displayScale).rounded() / displayScale
    }

    private func pixelAlignedOrigin(_ value: CGFloat) -> CGFloat {
        (value * displayScale).rounded(.down) / displayScale
    }

    private var isSolving: Bool {
        if case .solving = model.solveState { return true }
        return false
    }

    private var solvedSolution: SolveResult? {
        if case .solved(let solution) = model.solveState { return solution }
        return nil
    }

    private func overlayAvailable(_ key: String) -> Bool {
        solvedSolution?.overlayAvailability?[key] ?? (solvedSolution != nil)
    }

    private func overlayHelp(_ key: String) -> String {
        solvedSolution?.overlayUnavailableReasons?[key] ?? "Toggle this solve overlay"
    }

    private func overlayLabel(_ title: String, key: String) -> String {
        guard let count = solvedSolution?.overlayCounts?[key] else { return title }
        return "\(title) · \(count)"
    }

    private var availableDeepSkyCatalogs: [DeepSkyCatalog] {
        guard let solution = solvedSolution else { return [] }
        let present = Set(solution.objectPositions.compactMap(\.deepSkyCatalog))
        return DeepSkyCatalog.allCases.filter(present.contains)
    }

    private func deepSkyCatalogCount(_ catalog: DeepSkyCatalog) -> Int {
        solvedSolution?.objectPositions.lazy.filter { $0.deepSkyCatalog == catalog }.count ?? 0
    }

    private func catalogVisibility(_ catalog: DeepSkyCatalog) -> Binding<Bool> {
        Binding(
            get: { !hiddenDeepSkyCatalogs.contains(catalog) },
            set: { visible in
                if visible {
                    hiddenDeepSkyCatalogs.remove(catalog)
                } else {
                    hiddenDeepSkyCatalogs.insert(catalog)
                }
            }
        )
    }

    private var hasVisibleObjectLayer: Bool {
        showDeepSky || showNamedStars || showTransients || showMinorBodies
    }

    private var hasVisibleOverlays: Bool {
        hasVisibleObjectLayer
            || showDetectedStars
            || showFieldStars
            || showCoordinateGrid
            || showFieldCenter
    }

    private var hasCatalogOutlines: Bool {
        solvedSolution?.objectPositions.contains { !$0.outlines.isEmpty } == true
    }
}

private struct ExportImageView: View {
    let image: CGImage
    let solution: SolveResult
    let sourceSize: CGSize
    let showsDeepSky: Bool
    let showsNamedStars: Bool
    let showsTransients: Bool
    let showsHistoricalTransients: Bool
    let showsMinorBodies: Bool
    let showsCoordinateGrid: Bool
    let showsCatalogOutlines: Bool
    let showsObjectLabels: Bool
    let showsDetectedStars: Bool
    let showsFieldStars: Bool
    let showsFieldCenter: Bool
    let hiddenDeepSkyCatalogs: Set<DeepSkyCatalog>

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .frame(width: sourceSize.width, height: sourceSize.height)

            SolveOverlayView(
                solution: solution,
                sourceSize: sourceSize,
                showsDeepSky: showsDeepSky,
                showsNamedStars: showsNamedStars,
                showsTransients: showsTransients,
                showsHistoricalTransients: showsHistoricalTransients,
                showsMinorBodies: showsMinorBodies,
                showsCoordinateGrid: showsCoordinateGrid,
                showsCatalogOutlines: showsCatalogOutlines,
                showsObjectLabels: showsObjectLabels,
                showsDetectedStars: showsDetectedStars,
                showsFieldStars: showsFieldStars,
                showsFieldCenter: showsFieldCenter,
                hiddenDeepSkyCatalogs: hiddenDeepSkyCatalogs,
                rendersAsynchronously: false
            )
        }
        .frame(width: sourceSize.width, height: sourceSize.height)
    }
}

private struct SolveOverlayView: View {
    private enum Style {
        static let namedStar = Color(red: 1, green: 212.0 / 255.0, blue: 121.0 / 255.0)
        static let identifiedStar = Color(red: 183.0 / 255.0, green: 166.0 / 255.0, blue: 1)
        static let transient = Color(red: 1, green: 123.0 / 255.0, blue: 224.0 / 255.0)
        static let comet = Color(red: 123.0 / 255.0, green: 1, blue: 208.0 / 255.0)
        static let asteroid = Color(red: 1, green: 179.0 / 255.0, blue: 107.0 / 255.0)
        static let fieldStar = Color(red: 238.0 / 255.0, green: 247.0 / 255.0, blue: 1)
        static let grid = Color(red: 125.0 / 255.0, green: 219.0 / 255.0, blue: 232.0 / 255.0)
        static let gridLabel = Color(red: 185.0 / 255.0, green: 243.0 / 255.0, blue: 247.0 / 255.0)
        static let center = Color(red: 242.0 / 255.0, green: 198.0 / 255.0, blue: 109.0 / 255.0)
        static let labelHalo = Color.black.opacity(0.88)
        static let markerStrokeWidth: CGFloat = 0.7
        static let movingMarkerStrokeWidth: CGFloat = 0.95
        static let gridStrokeWidth: CGFloat = 0.65
        static let fieldStarStrokeWidth: CGFloat = 0.65
        static let centerStrokeWidth: CGFloat = 0.75
        static let markerOpacity = 0.88
        static let fieldStarOpacity = 0.78
        static let density = 0.6
        static let minimumRankedObjects = 4
    }

    private struct PlacedLabel {
        let x: CGFloat
        let y: CGFloat
        let halfWidth: CGFloat
    }

    private enum GridAxis {
        case rightAscension
        case declination
    }

    private struct GridCurve {
        let points: [CGPoint?]
        let label: String
        let axis: GridAxis
    }

    let solution: SolveResult
    let sourceSize: CGSize
    let showsDeepSky: Bool
    let showsNamedStars: Bool
    let showsTransients: Bool
    let showsHistoricalTransients: Bool
    let showsMinorBodies: Bool
    let showsCoordinateGrid: Bool
    let showsCatalogOutlines: Bool
    let showsObjectLabels: Bool
    let showsDetectedStars: Bool
    let showsFieldStars: Bool
    let showsFieldCenter: Bool
    let hiddenDeepSkyCatalogs: Set<DeepSkyCatalog>
    var rendersAsynchronously = true

    var body: some View {
        Canvas(rendersAsynchronously: rendersAsynchronously) { context, size in
            guard sourceSize.width > 0, sourceSize.height > 0 else { return }
            let scaleX = size.width / sourceSize.width
            let scaleY = size.height / sourceSize.height
            let markerScale = (scaleX + scaleY) / 2
            let sourceFontSize = max(sourceSize.width / 75, 14)
            let fontSize = sourceFontSize * markerScale

            if showsCoordinateGrid {
                drawCoordinateGrid(
                    scaleX: scaleX,
                    scaleY: scaleY,
                    markerScale: markerScale,
                    canvasSize: size,
                    context: &context
                )
            }

            let visibleObjects = solution.objectPositions.filter(objectIsVisible)
            if !visibleObjects.isEmpty {
                let encompassing = visibleObjects.filter {
                    encompassesFrame($0, width: sourceSize.width, height: sourceSize.height)
                }
                let inFrame = visibleObjects.filter { object in
                    !encompassing.contains { candidate in
                        candidate.name == object.name
                            && candidate.source == object.source
                            && candidate.x == object.x
                            && candidate.y == object.y
                    }
                }
                let rankable = inFrame
                    .filter { $0.prominence?.isFinite == true }
                    .sorted { ($0.prominence ?? 0) > ($1.prominence ?? 0) }
                let unrankable = inFrame.filter { $0.prominence?.isFinite != true }
                let floor = min(rankable.count, Style.minimumRankedObjects)
                let budget = max(
                    floor,
                    Int((Double(floor) + Double(rankable.count - floor) * Style.density).rounded())
                )
                let rendered = unrankable + Array(rankable.prefix(budget))
                var placedLabels: [PlacedLabel] = []

                for object in rendered {
                    let color = objectColor(object)
                    let center = CGPoint(
                        x: CGFloat(object.x) * scaleX,
                        y: CGFloat(object.y) * scaleY
                    )
                    let sourceMajorRadius = max(
                        CGFloat(object.semiMajorPixels),
                        sourceFontSize
                    )
                    let sourceMinorRadius = object.angleDegrees == nil
                        ? sourceMajorRadius
                        : max(CGFloat(object.semiMinorPixels), sourceFontSize)
                    let namedStar = object.kind == "star" || object.kind == "double-star"
                    let movingBody = object.kind == "comet" || object.kind == "asteroid"
                    let transient = object.kind == "transient"

                    if namedStar {
                        let radius = sourceMajorRadius * scaleX
                        var marker = Path()
                        marker.move(to: CGPoint(x: center.x - radius, y: center.y))
                        marker.addLine(to: CGPoint(x: center.x - radius / 3, y: center.y))
                        marker.move(to: CGPoint(x: center.x + radius / 3, y: center.y))
                        marker.addLine(to: CGPoint(x: center.x + radius, y: center.y))
                        markerStroke(marker, color: color, context: &context)
                    } else if movingBody || transient {
                        let horizontalRadius = sourceMajorRadius * scaleX
                        let verticalRadius = sourceMajorRadius * scaleY
                        var marker = Path()
                        marker.move(to: CGPoint(x: center.x, y: center.y - verticalRadius))
                        marker.addLine(to: CGPoint(x: center.x + horizontalRadius, y: center.y))
                        marker.addLine(to: CGPoint(x: center.x, y: center.y + verticalRadius))
                        marker.addLine(to: CGPoint(x: center.x - horizontalRadius, y: center.y))
                        marker.closeSubpath()
                        markerStroke(
                            marker,
                            color: color,
                            lineWidth: Style.movingMarkerStrokeWidth,
                            context: &context
                        )
                        if movingBody, let tail = movingBodyTail(
                            for: object,
                            center: center,
                            sourceRadius: sourceMajorRadius,
                            scaleX: scaleX,
                            scaleY: scaleY
                        ) {
                            markerStroke(
                                tail,
                                color: color,
                                lineWidth: Style.movingMarkerStrokeWidth,
                                context: &context
                            )
                        }
                    } else if showsCatalogOutlines, !object.outlines.isEmpty {
                        for outline in object.outlines {
                            for contour in outline.contours {
                                if let path = outlinePath(
                                    contour,
                                    scaleX: scaleX,
                                    scaleY: scaleY
                                ) {
                                    markerStroke(path, color: color, context: &context)
                                }
                            }
                        }
                    } else {
                        let majorRadius = sourceMajorRadius * scaleX
                        let minorRadius = sourceMinorRadius * scaleY
                        var marker = Path()
                        marker.addEllipse(in: CGRect(
                            x: -majorRadius,
                            y: -minorRadius,
                            width: majorRadius * 2,
                            height: minorRadius * 2
                        ))
                        let angle = CGFloat(object.angleDegrees ?? 0) * .pi / 180
                        let transform = CGAffineTransform(
                            translationX: center.x,
                            y: center.y
                        ).rotated(by: angle)
                        markerStroke(
                            marker.applying(transform),
                            color: color,
                            context: &context
                        )
                    }

                    if showsObjectLabels {
                        let labelPosition = placeLabel(
                            for: object,
                            center: center,
                            fontSize: fontSize,
                            markerScale: markerScale,
                            canvasSize: size,
                            placedLabels: &placedLabels
                        )
                        drawLabel(
                            object.displayName,
                            at: labelPosition,
                            color: color,
                            fontSize: fontSize,
                            context: &context
                        )
                    }
                }

                if showsObjectLabels, !encompassing.isEmpty {
                    let label = "Field within: "
                        + encompassing.map(\.displayName).joined(separator: " · ")
                    drawLabel(
                        label,
                        at: CGPoint(x: fontSize, y: size.height - fontSize),
                        color: Color(red: 174.0 / 255.0, green: 232.0 / 255.0, blue: 1),
                        fontSize: fontSize,
                        anchor: .leading,
                        context: &context
                    )
                }
            }

            if showsDetectedStars {
                var path = Path()
                for star in solution.detectedStarPositions {
                    let point = CGPoint(
                        x: CGFloat(star.x) * scaleX,
                        y: CGFloat(star.y) * scaleY
                    )
                    let radius = max(sourceSize.width / 1300, 2.5) * markerScale
                    path.move(to: CGPoint(x: point.x - radius, y: point.y))
                    path.addLine(to: CGPoint(x: point.x - radius / 3, y: point.y))
                    path.move(to: CGPoint(x: point.x + radius / 3, y: point.y))
                    path.addLine(to: CGPoint(x: point.x + radius, y: point.y))
                }
                markerStroke(path, color: Style.identifiedStar, context: &context)
            }

            if showsFieldStars {
                var path = Path()
                let radius = max(sourceSize.width / 1300, 2.5) * markerScale
                for star in solution.catalogStarPositions {
                    let point = CGPoint(
                        x: CGFloat(star.x) * scaleX,
                        y: CGFloat(star.y) * scaleY
                    )
                    path.addEllipse(in: markerRect(center: point, radius: radius))
                }
                context.stroke(
                    path,
                    with: .color(Style.fieldStar.opacity(Style.fieldStarOpacity)),
                    lineWidth: Style.fieldStarStrokeWidth
                )
            }

            if showsFieldCenter {
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = fontSize
                var path = Path()
                path.addEllipse(in: markerRect(center: center, radius: radius))
                path.move(to: CGPoint(x: center.x - radius * 1.7, y: center.y))
                path.addLine(to: CGPoint(x: center.x + radius * 1.7, y: center.y))
                path.move(to: CGPoint(x: center.x, y: center.y - radius * 1.7))
                path.addLine(to: CGPoint(x: center.x, y: center.y + radius * 1.7))
                context.stroke(
                    path,
                    with: .color(Style.center),
                    lineWidth: Style.centerStrokeWidth
                )
            }
        }
    }

    private func drawCoordinateGrid(
        scaleX: CGFloat,
        scaleY: CGFloat,
        markerScale: CGFloat,
        canvasSize: CGSize,
        context: inout GraphicsContext
    ) {
        let fontSize = gridLabelFontSize() * markerScale
        for curve in coordinateGrid() {
            var path = Path()
            var penDown = false
            let visiblePoints = curve.points.compactMap { point -> CGPoint? in
                guard let point else {
                    penDown = false
                    return nil
                }
                let scaled = CGPoint(x: point.x * scaleX, y: point.y * scaleY)
                if penDown {
                    path.addLine(to: scaled)
                } else {
                    path.move(to: scaled)
                }
                penDown = true
                return point.x >= 4
                    && point.x <= sourceSize.width - 4
                    && point.y >= 4
                    && point.y <= sourceSize.height - 4
                    ? scaled
                    : nil
            }
            context.stroke(
                path,
                with: .color(Style.grid.opacity(0.72)),
                style: StrokeStyle(
                    lineWidth: Style.gridStrokeWidth,
                    dash: [7, 5]
                )
            )
            guard let first = visiblePoints.first else { continue }
            let anchor = visiblePoints.dropFirst().reduce(first) { best, candidate in
                switch curve.axis {
                case .rightAscension: candidate.y < best.y ? candidate : best
                case .declination: candidate.x < best.x ? candidate : best
                }
            }
            let padding = max(6, fontSize * 0.45)
            let estimatedWidth = CGFloat(curve.label.count) * fontSize * 0.7
            let point: CGPoint
            let textAnchor: UnitPoint
            switch curve.axis {
            case .rightAscension:
                point = CGPoint(
                    x: min(max(anchor.x, padding + estimatedWidth / 2), canvasSize.width - padding - estimatedWidth / 2),
                    y: min(max(anchor.y + fontSize * 1.35, padding + fontSize), canvasSize.height - padding)
                )
                textAnchor = .center
            case .declination:
                point = CGPoint(
                    x: min(max(anchor.x + padding, padding), canvasSize.width - padding - estimatedWidth),
                    y: min(max(anchor.y - padding, padding + fontSize), canvasSize.height - padding)
                )
                textAnchor = .leading
            }
            drawGridLabel(
                curve.label,
                at: point,
                fontSize: fontSize,
                anchor: textAnchor,
                context: &context
            )
        }
    }

    private func coordinateGrid() -> [GridCurve] {
        let width = Double(sourceSize.width)
        let height = Double(sourceSize.height)
        guard width > 0, height > 0 else { return [] }
        let centerRA = pixelToWorld(x: width / 2, y: height / 2).0
        var minimumRA = Double.infinity
        var maximumRA = -Double.infinity
        var minimumDec = Double.infinity
        var maximumDec = -Double.infinity
        for xIndex in 0...8 {
            for yIndex in 0...8 {
                let sky = pixelToWorld(
                    x: width * Double(xIndex) / 8,
                    y: height * Double(yIndex) / 8
                )
                let unwrappedRA = centerRA + modulo(sky.0 - centerRA + 540, 360) - 180
                minimumRA = min(minimumRA, unwrappedRA)
                maximumRA = max(maximumRA, unwrappedRA)
                minimumDec = min(minimumDec, sky.1)
                maximumDec = max(maximumDec, sky.1)
            }
        }
        guard minimumRA.isFinite, maximumRA.isFinite,
              minimumDec.isFinite, maximumDec.isFinite else { return [] }
        let cosineDec = max(abs(cos(solution.centerDecDegrees * .pi / 180)), 0.05)
        let span = max(
            maximumDec - minimumDec,
            (maximumRA - minimumRA) * cosineDec,
            solution.scaleArcsecPerPixel / 3_600
        )
        let decStep = niceGridStep(span / 5)
        let raStep = niceGridStep(span / cosineDec / 5)
        var curves: [GridCurve] = []

        var ra = floor(minimumRA / raStep) * raStep
        for _ in 0..<32 where ra <= maximumRA + raStep {
            curves.append(GridCurve(
                points: sampleGridCurve(
                    start: minimumDec - decStep,
                    end: maximumDec + decStep
                ) { dec in
                    worldToPixel(ra: modulo(ra, 360), dec: min(max(dec, -89.999_999), 89.999_999))
                },
                label: formatRA(modulo(ra, 360)),
                axis: .rightAscension
            ))
            ra += raStep
        }

        var dec = floor(minimumDec / decStep) * decStep
        for _ in 0..<32 where dec <= maximumDec + decStep && dec <= 90 {
            if dec >= -90 {
                curves.append(GridCurve(
                    points: sampleGridCurve(
                        start: minimumRA - raStep,
                        end: maximumRA + raStep
                    ) { ra in
                        worldToPixel(ra: modulo(ra, 360), dec: min(max(dec, -89.999_999), 89.999_999))
                    },
                    label: formatDeclination(dec),
                    axis: .declination
                ))
            }
            dec += decStep
        }
        return curves
    }

    private func sampleGridCurve(
        start: Double,
        end: Double,
        projection: (Double) -> CGPoint?
    ) -> [CGPoint?] {
        (0...96).map { index in
            let coordinate = start + (end - start) * Double(index) / 96
            guard let point = projection(coordinate), point.x.isFinite, point.y.isFinite else {
                return nil
            }
            let width = Double(sourceSize.width)
            let height = Double(sourceSize.height)
            guard Double(point.x) >= -4 * width,
                  Double(point.x) <= 5 * width,
                  Double(point.y) >= -4 * height,
                  Double(point.y) <= 5 * height else { return nil }
            return point
        }
    }

    private func pixelToWorld(x: Double, y: Double) -> (Double, Double) {
        let wcs = solution.wcs
        let dx = x - wcs.crpix[0]
        let dy = y - wcs.crpix[1]
        let xi = (wcs.cd[0][0] * dx + wcs.cd[0][1] * dy) * .pi / 180
        let eta = (wcs.cd[1][0] * dx + wcs.cd[1][1] * dy) * .pi / 180
        let ra0 = wcs.crval[0] * .pi / 180
        let dec0 = wcs.crval[1] * .pi / 180
        let rho = hypot(xi, eta)
        guard rho > 0 else { return (wcs.crval[0], wcs.crval[1]) }
        let c = atan(rho)
        let dec = asin(cos(c) * sin(dec0) + eta * sin(c) * cos(dec0) / rho)
        let ra = ra0 + atan2(
            xi * sin(c),
            rho * cos(dec0) * cos(c) - eta * sin(dec0) * sin(c)
        )
        return (modulo(ra * 180 / .pi, 360), dec * 180 / .pi)
    }

    private func worldToPixel(ra: Double, dec: Double) -> CGPoint? {
        let wcs = solution.wcs
        let ra0 = wcs.crval[0] * .pi / 180
        let dec0 = wcs.crval[1] * .pi / 180
        let ra = ra * .pi / 180
        let dec = dec * .pi / 180
        let deltaRA = ra - ra0
        let cosineC = sin(dec0) * sin(dec) + cos(dec0) * cos(dec) * cos(deltaRA)
        guard cosineC > 1e-9 else { return nil }
        let xi = cos(dec) * sin(deltaRA) / cosineC * 180 / .pi
        let eta = (cos(dec0) * sin(dec) - sin(dec0) * cos(dec) * cos(deltaRA))
            / cosineC * 180 / .pi
        let determinant = wcs.cd[0][0] * wcs.cd[1][1] - wcs.cd[0][1] * wcs.cd[1][0]
        guard determinant != 0 else { return nil }
        return CGPoint(
            x: wcs.crpix[0] + (wcs.cd[1][1] * xi - wcs.cd[0][1] * eta) / determinant,
            y: wcs.crpix[1] + (-wcs.cd[1][0] * xi + wcs.cd[0][0] * eta) / determinant
        )
    }

    private func gridLabelFontSize() -> CGFloat {
        max(min(max(sourceSize.width / 60, 18), sourceSize.width / 18), 6)
    }

    private func niceGridStep(_ target: Double) -> Double {
        let steps: [Double] = [
            1.0 / 3_600, 2.0 / 3_600, 5.0 / 3_600, 10.0 / 3_600,
            15.0 / 3_600, 30.0 / 3_600, 1.0 / 60, 2.0 / 60,
            5.0 / 60, 10.0 / 60, 15.0 / 60, 30.0 / 60,
            1, 2, 5, 10, 15, 30, 45, 90,
        ]
        return steps.first { $0 >= target } ?? 90
    }

    private func formatRA(_ ra: Double) -> String {
        let totalTenths = Int((modulo(ra, 360) / 15 * 36_000).rounded()) % 864_000
        let hours = totalTenths / 36_000
        let minutes = totalTenths % 36_000 / 600
        let seconds = totalTenths % 600
        return String(
            format: "RA %02dh%02dm%02d.%01ds",
            hours,
            minutes,
            seconds / 10,
            seconds % 10
        )
    }

    private func formatDeclination(_ dec: Double) -> String {
        let sign = dec < 0 ? "−" : "+"
        let totalTenths = Int((abs(dec) * 36_000).rounded())
        let degrees = totalTenths / 36_000
        let minutes = totalTenths % 36_000 / 600
        let seconds = totalTenths % 600
        return String(
            format: "Dec %@%02d°%02d′%02d.%01d″",
            sign,
            degrees,
            minutes,
            seconds / 10,
            seconds % 10
        )
    }

    private func modulo(_ value: Double, _ divisor: Double) -> Double {
        ((value.truncatingRemainder(dividingBy: divisor)) + divisor)
            .truncatingRemainder(dividingBy: divisor)
    }

    private func drawGridLabel(
        _ value: String,
        at point: CGPoint,
        fontSize: CGFloat,
        anchor: UnitPoint,
        context: inout GraphicsContext
    ) {
        let font = Font.system(size: fontSize, weight: .medium, design: .monospaced)
        let halo = Text(value).font(font).foregroundStyle(Style.labelHalo)
        let foreground = Text(value).font(font).foregroundStyle(Style.gridLabel)
        let radius = max(fontSize * 0.05, 0.5)
        for offset in [
            CGSize(width: -radius, height: 0),
            CGSize(width: radius, height: 0),
            CGSize(width: 0, height: -radius),
            CGSize(width: 0, height: radius),
        ] {
            context.draw(
                halo,
                at: CGPoint(x: point.x + offset.width, y: point.y + offset.height),
                anchor: anchor
            )
        }
        context.draw(foreground, at: point, anchor: anchor)
    }

    private func movingBodyTail(
        for object: SolveObjectPoint,
        center: CGPoint,
        sourceRadius: CGFloat,
        scaleX: CGFloat,
        scaleY: CGFloat
    ) -> Path? {
        guard let direction = object.directionImageAngleDegrees else { return nil }
        let physicalLength = object.motionArcsecPerHour.map {
            CGFloat($0 * 3 / solution.scaleArcsecPerPixel)
        }
        let vectorLength = physicalLength.map {
            min(max($0, sourceRadius * 3), sourceRadius * 9)
        }
        let defaultTipDistance: CGFloat = object.kind == "comet" ? 4 : 4.5
        let tipDistance = vectorLength.map { max(abs($0) / max(abs(sourceRadius), .ulpOfOne), 1.5) }
            ?? defaultTipDistance
        let radians = CGFloat(direction) * .pi / 180
        func point(along: CGFloat, offset: CGFloat = 0) -> CGPoint {
            CGPoint(
                x: center.x + (cos(radians) * sourceRadius * along - sin(radians) * sourceRadius * offset) * scaleX,
                y: center.y + (sin(radians) * sourceRadius * along + cos(radians) * sourceRadius * offset) * scaleY
            )
        }
        var path = Path()
        if object.kind == "comet" {
            let root = point(along: 1.15)
            let span = tipDistance - 1.15
            let shoulder = 1.15 + span * 0.75
            let flare = min(max(span * 0.18, 0.35), 0.85)
            let tip = point(along: tipDistance)
            path.move(to: root)
            path.addLine(to: tip)
            path.move(to: root)
            path.addLine(to: point(along: shoulder, offset: flare))
            path.move(to: root)
            path.addLine(to: point(along: shoulder, offset: -flare))
        } else {
            let root = point(along: 1.2)
            let span = tipDistance - 1.2
            let tip = point(along: tipDistance)
            let arrowRoot = 1.2 + span * 0.73
            let arrowWidth = min(max(span * 0.2, 0.45), 0.9)
            path.move(to: root)
            path.addLine(to: tip)
            path.move(to: point(along: arrowRoot, offset: arrowWidth))
            path.addLine(to: tip)
            path.addLine(to: point(along: arrowRoot, offset: -arrowWidth))
        }
        return path
    }

    private func objectIsVisible(_ object: SolveObjectPoint) -> Bool {
        switch object.kind {
        case "star", "double-star", "identified-star":
            return showsNamedStars
        case "transient":
            return showsTransients
                && (object.nearCapture != false || showsHistoricalTransients)
        case "comet", "asteroid":
            return showsMinorBodies
        default:
            guard showsDeepSky, let catalog = object.deepSkyCatalog else { return false }
            return !hiddenDeepSkyCatalogs.contains(catalog)
        }
    }

    private func objectColor(_ object: SolveObjectPoint) -> Color {
        switch object.kind {
        case "comet": Style.comet
        case "asteroid": Style.asteroid
        case "transient": Style.transient
        case "identified-star": Style.identifiedStar
        case "star", "double-star": Style.namedStar
        default: (object.deepSkyCatalog ?? .other).overlayColor
        }
    }

    private func encompassesFrame(
        _ object: SolveObjectPoint,
        width: CGFloat,
        height: CGFloat
    ) -> Bool {
        guard object.semiMajorPixels > 0 else { return false }
        let angle = CGFloat(object.angleDegrees ?? 0) * .pi / 180
        let cosine = cos(angle)
        let sine = sin(angle)
        let majorRadius = CGFloat(object.semiMajorPixels)
        let minorRadius = object.angleDegrees == nil
            ? majorRadius
            : max(CGFloat(object.semiMinorPixels), 1)
        let corners = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: width, y: 0),
            CGPoint(x: width, y: height),
            CGPoint(x: 0, y: height),
        ]
        return corners.allSatisfy { corner in
            let dx = corner.x - CGFloat(object.x)
            let dy = corner.y - CGFloat(object.y)
            let u = (dx * cosine + dy * sine) / majorRadius
            let v = (-dx * sine + dy * cosine) / minorRadius
            return u * u + v * v <= 1
        }
    }

    private func placeLabel(
        for object: SolveObjectPoint,
        center: CGPoint,
        fontSize: CGFloat,
        markerScale: CGFloat,
        canvasSize: CGSize,
        placedLabels: inout [PlacedLabel]
    ) -> CGPoint {
        let estimatedHalfWidth = CGFloat(object.displayName.count) * fontSize * 0.275
        let maximumHalfWidth = max(0, canvasSize.width / 2 - fontSize * 0.25)
        let halfWidth = min(estimatedHalfWidth, maximumHalfWidth)
        let x = halfWidth >= maximumHalfWidth
            ? canvasSize.width / 2
            : min(
                max(center.x, halfWidth + fontSize * 0.25),
                canvasSize.width - halfWidth - fontSize * 0.25
            )
        let radius = max(CGFloat(object.semiMinorPixels) * markerScale, fontSize)
        var y = center.y - radius - fontSize * 0.5
        for _ in 0..<6 {
            let collision = placedLabels.contains { placed in
                abs(placed.y - y) < fontSize * 1.3
                    && abs(placed.x - x) < placed.halfWidth + halfWidth
            }
            if !collision { break }
            y -= fontSize * 1.4
        }
        y = min(max(y, fontSize * 1.1), canvasSize.height - fontSize * 0.35)
        placedLabels.append(PlacedLabel(x: x, y: y, halfWidth: halfWidth))
        return CGPoint(x: x, y: y)
    }

    private func drawLabel(
        _ value: String,
        at point: CGPoint,
        color: Color,
        fontSize: CGFloat,
        anchor: UnitPoint = .center,
        context: inout GraphicsContext
    ) {
        let font = Font.system(size: fontSize, weight: .regular)
        let halo = Text(value).font(font).foregroundStyle(Style.labelHalo)
        let foreground = Text(value).font(font).foregroundStyle(color)
        let radius = max(fontSize * 0.05, 0.5)
        for offset in [
            CGSize(width: -radius, height: 0),
            CGSize(width: radius, height: 0),
            CGSize(width: 0, height: -radius),
            CGSize(width: 0, height: radius),
            CGSize(width: -radius, height: -radius),
            CGSize(width: radius, height: -radius),
            CGSize(width: -radius, height: radius),
            CGSize(width: radius, height: radius),
        ] {
            context.draw(
                halo,
                at: CGPoint(x: point.x + offset.width, y: point.y + offset.height),
                anchor: anchor
            )
        }
        context.draw(foreground, at: point, anchor: anchor)
    }

    private func markerRect(center: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
    }

    private func outlinePath(
        _ contour: SolveObjectContour,
        scaleX: CGFloat,
        scaleY: CGFloat
    ) -> Path? {
        let points = contour.points.compactMap { coordinates -> CGPoint? in
            guard coordinates.count == 2,
                  coordinates[0].isFinite,
                  coordinates[1].isFinite else { return nil }
            return CGPoint(
                x: CGFloat(coordinates[0]) * scaleX,
                y: CGFloat(coordinates[1]) * scaleY
            )
        }
        let minimumPointCount = contour.closed ? 3 : 2
        guard points.count >= minimumPointCount, let first = points.first else { return nil }
        var path = Path()
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        if contour.closed {
            path.closeSubpath()
        }
        return path
    }

    private func markerStroke(
        _ path: Path,
        color: Color,
        lineWidth: CGFloat = Style.markerStrokeWidth,
        context: inout GraphicsContext
    ) {
        context.stroke(
            path,
            with: .color(color.opacity(Style.markerOpacity)),
            lineWidth: lineWidth
        )
    }
}

enum HistogramPlotScale {
    static func ceiling(for channels: [[UInt64]]) -> Double {
        let interior = channels.flatMap { bins -> ArraySlice<UInt64> in
            guard bins.count > 2 else { return bins[...] }
            return bins.dropFirst().dropLast()
        }
        let nonzeroInterior = interior.filter { $0 > 0 }.sorted()
        let nonzeroAll = channels.flatMap { $0 }.filter { $0 > 0 }.sorted()
        let candidates = nonzeroInterior.isEmpty ? nonzeroAll : nonzeroInterior
        guard !candidates.isEmpty else { return 0 }

        // Clipped black/white pixels and hot bins can be orders of magnitude
        // taller than the useful distribution. Scale to the 98th percentile
        // of populated interior bins and clamp taller columns at the top.
        let index = Int(
            (Double(candidates.count - 1) * 0.98).rounded(.down)
        )
        return Double(candidates[index])
    }

    static func normalizedHeight(count: UInt64, ceiling: Double) -> Double {
        guard ceiling > 0 else { return 0 }
        return min(Double(count) / ceiling, 1)
    }
}

private struct ImageHistogramView: View {
    let histogram: ImageHistogram
    let isMonochrome: Bool

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }

            var grid = Path()
            for fraction in [CGFloat(0.25), 0.5, 0.75] {
                let x = size.width * fraction
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            context.stroke(
                grid,
                with: .color(.white.opacity(0.09)),
                lineWidth: 1
            )

            let channels = isMonochrome
                ? [(histogram.red, Color.white)]
                : [
                    (histogram.red, Color.red),
                    (histogram.green, Color.green),
                    (histogram.blue, Color.blue),
                ]
            let ceiling = HistogramPlotScale.ceiling(
                for: channels.map(\.0)
            )
            guard ceiling > 0 else { return }

            context.blendMode = .plusLighter
            for (bins, color) in channels {
                draw(
                    bins: bins,
                    color: color,
                    ceiling: ceiling,
                    size: size,
                    context: &context
                )
            }
        }
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement()
        .accessibilityLabel(isMonochrome ? "Luminance histogram" : "RGB histogram")
    }

    private func draw(
        bins: [UInt64],
        color: Color,
        ceiling: Double,
        size: CGSize,
        context: inout GraphicsContext
    ) {
        guard bins.count > 1 else { return }

        var curve = Path()
        for (index, count) in bins.enumerated() {
            let x = CGFloat(index) / CGFloat(bins.count - 1) * size.width
            let height = CGFloat(
                HistogramPlotScale.normalizedHeight(
                    count: count,
                    ceiling: ceiling
                )
            ) * size.height
            let point = CGPoint(x: x, y: size.height - height)
            if index == 0 {
                curve.move(to: point)
            } else {
                curve.addLine(to: point)
            }
        }

        var area = curve
        area.addLine(to: CGPoint(x: size.width, y: size.height))
        area.addLine(to: CGPoint(x: 0, y: size.height))
        area.closeSubpath()
        context.fill(area, with: .color(color.opacity(isMonochrome ? 0.3 : 0.2)))
        context.stroke(curve, with: .color(color.opacity(0.9)), lineWidth: 1)
    }
}

private struct LabeledHistogramView: View {
    let title: String
    let axisTitle: String
    let histogram: ImageHistogram
    let isMonochrome: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.medium))

            ImageHistogramView(
                histogram: histogram,
                isMonochrome: isMonochrome
            )
            .frame(height: 88)

            HStack {
                Text(levelLabel(histogram.lowerBound))
                Spacer()
                Text(axisTitle)
                Spacer()
                Text(levelLabel(histogram.upperBound))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func levelLabel(_ value: Double) -> String {
        if value.rounded() == value {
            return Int(value).formatted()
        }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }
}

enum ImagePixelSampler {
    static func normalizedLuminance(
        image: CGImage,
        x: Int,
        y: Int,
        radius: Int = 1
    ) -> Double? {
        guard radius >= 0,
              image.bitsPerComponent == 8,
              image.bitsPerPixel == 32,
              image.alphaInfo == .last || image.alphaInfo == .premultipliedLast,
              (0..<image.width).contains(x),
              (0..<image.height).contains(y),
              let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }

        let byteCount = CFDataGetLength(data)
        var samples: [Double] = []
        for sampleY in max(y - radius, 0)...min(y + radius, image.height - 1) {
            for sampleX in max(x - radius, 0)...min(x + radius, image.width - 1) {
                let offset = sampleY * image.bytesPerRow + sampleX * 4
                guard offset + 2 < byteCount else { return nil }
                let red = Double(bytes[offset]) / 255
                let green = Double(bytes[offset + 1]) / 255
                let blue = Double(bytes[offset + 2]) / 255
                samples.append(0.2126 * red + 0.7152 * green + 0.0722 * blue)
            }
        }
        guard !samples.isEmpty else { return nil }
        samples.sort()
        return samples[samples.count / 2]
    }
}

private struct InspectorView: View {
    @ObservedObject var model: ImageDocumentModel

    var body: some View {
        List {
            if let metadata = model.metadata {
                Section("Image") {
                    LabeledContent("Dimensions", value: "\(metadata.width) × \(metadata.height)")
                    LabeledContent("Format", value: metadata.format)
                    LabeledContent("Encoding", value: metadata.colorKind)
                    if model.supportsFITSStretch {
                        LabeledContent(
                            "Stretch",
                            value: model.stretchHistory.appliedStages.count == 1
                                ? model.stretchConfiguration.type.title
                                : "\(model.stretchHistory.appliedStages.count) stages · \(model.stretchConfiguration.type.title)"
                        )
                        if model.supportsColorStretch {
                            LabeledContent(
                                "Color handling",
                                value: model.stretchConfiguration.colorStrategy.title
                            )
                        }
                    }
                    LabeledContent("Median", value: "\(metadata.statistics.median)")
                    LabeledContent("MAD", value: metadata.statistics.mad.formatted(.number.precision(.fractionLength(2))))
                }

                if metadata.inputHistogram?.isValid == true
                    || metadata.displayHistogram?.isValid == true {
                    Section("Histograms") {
                        VStack(spacing: 12) {
                            if let histogram = metadata.inputHistogram, histogram.isValid {
                                LabeledHistogramView(
                                    title: "Input",
                                    axisTitle: "Pre-stretch level",
                                    histogram: histogram,
                                    isMonochrome: metadata.colorKind.hasPrefix("mono")
                                )
                            }
                            if let histogram = metadata.displayHistogram, histogram.isValid {
                                LabeledHistogramView(
                                    title: "Display",
                                    axisTitle: "Stretched level",
                                    histogram: histogram,
                                    isMonochrome: metadata.colorKind.hasPrefix("mono")
                                )
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section("Plate solution") {
                solveDetails
            }

            if let headers = model.metadata?.headers, !headers.isEmpty {
                Section("FITS headers") {
                    ForEach(headers.keys.sorted(), id: \.self) { key in
                        LabeledContent(key, value: headers[key]?.description ?? "")
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var solveDetails: some View {
        switch model.solveState {
        case .idle:
            Text("Not solved")
                .foregroundStyle(.secondary)
        case .solving:
            ProgressView("Solving…")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Text(message)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                SettingsLink {
                    Label("Catalog Settings…", systemImage: "gearshape")
                }
            }
        case .solved(let solution):
            LabeledContent("RA", value: solution.centerRaDegrees.formatted(.number.precision(.fractionLength(5))) + "°")
            LabeledContent("Dec", value: solution.centerDecDegrees.formatted(.number.precision(.fractionLength(5))) + "°")
            LabeledContent("Scale", value: solution.scaleArcsecPerPixel.formatted(.number.precision(.fractionLength(3))) + "″/px")
            LabeledContent("Matches", value: "\(solution.matchedStars)")
            LabeledContent("RMS", value: solution.rmsArcsec.formatted(.number.precision(.fractionLength(2))) + "″")
            if let captureTime = solution.captureTime {
                LabeledContent("Acquired", value: captureTime)
            }
            if let counts = solution.overlayCounts {
                LabeledContent("Deep sky", value: "\(counts["deep_sky"] ?? 0)")
                LabeledContent("Named stars", value: "\(counts["named_stars"] ?? 0)")
                LabeledContent("Transients", value: "\(counts["transients"] ?? 0)")
                LabeledContent("Solar system", value: "\(counts["minor_bodies"] ?? 0)")
            } else {
                LabeledContent("Sky objects", value: "\(solution.objectPositions.count)")
            }
            if let error = solution.objectCatalogError {
                Text("Object overlay unavailable: \(error)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let reasons = solution.overlayUnavailableReasons {
                ForEach(reasons.keys.sorted(), id: \.self) { key in
                    if key != "deep_sky", key != "named_stars", let reason = reasons[key] {
                        Text("\(overlayLayerName(key)): \(reason)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            LabeledContent("Detected diagnostics", value: "\(solution.detectedStarPositions.count)")
            LabeledContent("Catalog diagnostics", value: "\(solution.catalogStarPositions.count)")
        }
    }

    private func overlayLayerName(_ key: String) -> String {
        switch key {
        case "transients": "Transients"
        case "historical_transients": "Older transients"
        case "minor_bodies": "Solar system"
        case "field_stars": "Field stars"
        default: key
        }
    }
}
