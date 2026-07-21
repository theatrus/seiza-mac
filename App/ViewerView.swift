import AppKit
import SwiftUI

struct ViewerView: View {
    let urls: [URL]
    let showsImageBrowser: Bool
    let onSelectionChange: (URL) -> Void

    @State private var selectedIndex: Int
    @State private var model: ImageDocumentModel
    @State private var showInspector = false
    @State private var showImageBrowser: Bool

    init(
        urls: [URL],
        initialIndex: Int = 0,
        showsImageBrowser: Bool = false,
        onSelectionChange: @escaping (URL) -> Void = { _ in }
    ) {
        self.urls = urls
        self.showsImageBrowser = showsImageBrowser
        self.onSelectionChange = onSelectionChange
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
    @State private var zoom = 1.0
    @State private var pinchStartZoom: Double?
    @State private var pinchAnchor: ZoomAnchor?
    @State private var scrollPosition = ScrollPosition()
    @State private var visibleContentOrigin = CGPoint.zero
    @Binding private var showInspector: Bool
    @State private var viewportSize = CGSize.zero
    @State private var isFitToWindow = true
    @State private var showSkyObjects = true
    @State private var showCatalogOutlines = true
    @State private var showObjectLabels = true
    @State private var showDetectedStars = false
    @State private var showCatalogStars = false
    @State private var showFieldCenter = true

    init(
        model: ImageDocumentModel,
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
                .help(isSolving ? "Solving image…" : "Plate Solve")

                Menu {
                    Toggle("Deep-Sky Objects", isOn: $showSkyObjects)
                    Toggle("Detailed OpenNGC Outlines", isOn: $showCatalogOutlines)
                        .disabled(!showSkyObjects || !hasCatalogOutlines)
                    Toggle("Object Labels", isOn: $showObjectLabels)
                        .disabled(!showSkyObjects)
                    Toggle("Field Center", isOn: $showFieldCenter)

                    Divider()

                    Toggle("Detected Stars", isOn: $showDetectedStars)
                    Toggle("Catalog Stars", isOn: $showCatalogStars)

                    Divider()

                    Button("Hide All Overlays") {
                        showSkyObjects = false
                        showObjectLabels = false
                        showDetectedStars = false
                        showCatalogStars = false
                        showFieldCenter = false
                    }
                    .disabled(!hasVisibleOverlays)
                } label: {
                    Label("Overlays", systemImage: "square.3.layers.3d")
                }
                .disabled(solvedSolution == nil)
                .help(solvedSolution == nil ? "Solve the image to enable overlays" : "Solve Overlays")

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
    }

    @ViewBuilder
    private var imagePane: some View {
        switch model.loadState {
        case .loading:
            if let previewImage = model.previewImage {
                imageCanvas(image: previewImage, showsLoadingIndicator: true)
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
        case .loaded:
            if let image = model.image {
                imageCanvas(image: image, showsLoadingIndicator: false)
            }
        }
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
                                sourceSize: CGSize(width: image.width, height: image.height),
                                showsSkyObjects: showSkyObjects,
                                showsCatalogOutlines: showCatalogOutlines,
                                showsObjectLabels: showObjectLabels,
                                showsDetectedStars: showDetectedStars,
                                showsCatalogStars: showCatalogStars,
                                showsFieldCenter: showFieldCenter
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
            .onAppear {
                viewportSize = geometry.size
                applyFitZoom(image: image, viewport: geometry.size)
            }
            .onChange(of: geometry.size) { _, newSize in
                viewportSize = newSize
                if isFitToWindow {
                    applyFitZoom(image: image, viewport: newSize)
                }
            }
            .onChange(of: CGSize(width: image.width, height: image.height)) { _, _ in
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
        let horizontalScale = viewport.width / CGFloat(image.width)
        let verticalScale = viewport.height / CGFloat(image.height)
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
        CGSize(
            width: pixelAlignedLength(CGFloat(image.width) * zoom),
            height: pixelAlignedLength(CGFloat(image.height) * zoom)
        )
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

    private var hasVisibleOverlays: Bool {
        showSkyObjects || showDetectedStars || showCatalogStars || showFieldCenter
    }

    private var hasCatalogOutlines: Bool {
        solvedSolution?.objectPositions.contains { !$0.outlines.isEmpty } == true
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
        static let center = Color(red: 242.0 / 255.0, green: 198.0 / 255.0, blue: 109.0 / 255.0)
        static let labelHalo = Color.black.opacity(0.88)
        static let messier = Color(red: 242.0 / 255.0, green: 202.0 / 255.0, blue: 114.0 / 255.0)
        static let ngc = Color(red: 85.0 / 255.0, green: 207.0 / 255.0, blue: 1)
        static let ic = Color(red: 114.0 / 255.0, green: 223.0 / 255.0, blue: 185.0 / 255.0)
        static let sharplessVdb = Color(red: 238.0 / 255.0, green: 154.0 / 255.0, blue: 120.0 / 255.0)
        static let lbn = Color(red: 162.0 / 255.0, green: 217.0 / 255.0, blue: 111.0 / 255.0)
        static let cederblad = Color(red: 112.0 / 255.0, green: 215.0 / 255.0, blue: 208.0 / 255.0)
        static let darkNebula = Color(red: 180.0 / 255.0, green: 163.0 / 255.0, blue: 240.0 / 255.0)
        static let supernovaRemnant = Color(red: 241.0 / 255.0, green: 135.0 / 255.0, blue: 130.0 / 255.0)
        static let ugc = Color(red: 121.0 / 255.0, green: 175.0 / 255.0, blue: 245.0 / 255.0)
        static let pgc = Color(red: 161.0 / 255.0, green: 174.0 / 255.0, blue: 216.0 / 255.0)
        static let otherDeepSky = Color(red: 193.0 / 255.0, green: 209.0 / 255.0, blue: 211.0 / 255.0)

        static let markerStrokeWidth: CGFloat = 0.7
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

    let solution: SolveResult
    let sourceSize: CGSize
    let showsSkyObjects: Bool
    let showsCatalogOutlines: Bool
    let showsObjectLabels: Bool
    let showsDetectedStars: Bool
    let showsCatalogStars: Bool
    let showsFieldCenter: Bool

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            guard sourceSize.width > 0, sourceSize.height > 0 else { return }
            let scaleX = size.width / sourceSize.width
            let scaleY = size.height / sourceSize.height
            let markerScale = (scaleX + scaleY) / 2
            let sourceFontSize = max(sourceSize.width / 75, 14)
            let fontSize = sourceFontSize * markerScale

            if showsSkyObjects {
                let encompassing = solution.objectPositions.filter {
                    encompassesFrame($0, width: sourceSize.width, height: sourceSize.height)
                }
                let inFrame = solution.objectPositions.filter { object in
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
                    if showsCatalogOutlines, !object.outlines.isEmpty {
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
                        let sourceMajorRadius = max(
                            CGFloat(object.semiMajorPixels),
                            sourceFontSize
                        )
                        let sourceMinorRadius: CGFloat
                        if object.angleDegrees == nil {
                            // The catalog has no trustworthy orientation for this
                            // asymmetric extent, so draw the conservative circle.
                            sourceMinorRadius = sourceMajorRadius
                        } else {
                            sourceMinorRadius = max(
                                CGFloat(object.semiMinorPixels),
                                sourceFontSize
                            )
                        }
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

            if showsCatalogStars {
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

    private func objectColor(_ object: SolveObjectPoint) -> Color {
        switch object.kind {
        case "comet": Style.comet
        case "asteroid": Style.asteroid
        case "transient": Style.transient
        case "identified-star": Style.identifiedStar
        case "star", "double-star": Style.namedStar
        default: deepSkyCatalogColor(for: object.name)
        }
    }

    private func deepSkyCatalogColor(for name: String) -> Color {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if matches("^PGC(?:\\s|$)", name) { return Style.pgc }
        if matches("^UGC(?:\\s|$)", name) { return Style.ugc }
        if matches("^LBN(?:\\s|$)", name) { return Style.lbn }
        if matches("^(?:Ced|Cederblad)(?:\\s|$)", name) { return Style.cederblad }
        if matches("^(?:LDN(?:\\s|$)|B\\s*\\d)", name) { return Style.darkNebula }
        if matches("^SNR(?:\\s|$)", name) { return Style.supernovaRemnant }
        if matches("^(?:Sh\\s*2[- ]|vdB(?:\\s|$))", name) { return Style.sharplessVdb }
        if matches("^M\\s*\\d", name) { return Style.messier }
        if matches("^NGC\\s*\\d", name) { return Style.ngc }
        if matches("^IC\\s*\\d", name) { return Style.ic }
        return Style.otherDeepSky
    }

    private func matches(_ pattern: String, _ value: String) -> Bool {
        value.range(
            of: pattern,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
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
        context: inout GraphicsContext
    ) {
        context.stroke(
            path,
            with: .color(color.opacity(Style.markerOpacity)),
            lineWidth: Style.markerStrokeWidth
        )
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
                    LabeledContent("Median", value: "\(metadata.statistics.median)")
                    LabeledContent("MAD", value: metadata.statistics.mad.formatted(.number.precision(.fractionLength(2))))
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
            LabeledContent("Sky objects", value: "\(solution.objectPositions.count)")
            if let error = solution.objectCatalogError {
                Text("Object overlay unavailable: \(error)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            LabeledContent("Detected diagnostics", value: "\(solution.detectedStarPositions.count)")
            LabeledContent("Catalog diagnostics", value: "\(solution.catalogStarPositions.count)")
        }
    }
}
