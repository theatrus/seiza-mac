import SwiftUI

// MARK: - Geometry

/// One vertex of the parallelogram tilt diagram, in source pixels.
struct TiltPerimeterVertex: Equatable, Sendable {
    var row: Int
    var column: Int
    var starCount: Int
    var medianHfr: Double
    var point: CGPoint
}

struct TiltPerimeterDiagram: Equatable, Sendable {
    var center: CGPoint
    var vertices: [TiltPerimeterVertex]
    var centerMeasurement: Double?
    var referenceCornerHfr: Double
}

struct TriangleTiltVertex: Equatable, Sendable {
    var sector: Int
    var axisAngleDegrees: Double
    var starCount: Int
    var medianHfr: Double
    var point: CGPoint
}

struct TriangleTiltDiagram: Equatable, Sendable {
    var center: CGPoint
    var vertices: [TriangleTiltVertex]
    var centerStarCount: Int
    var centerHfr: Double?
    var referenceWorstHfr: Double
    var overallMedianHfr: Double
    var tiltPercent: Double
}

enum StarAnalysisCellVisualKind: Equatable, Sendable {
    case neutral
    case good
    case warning
    case poor
}

/// Pure geometry and policy shared by the viewport overlay, the export
/// compositor, and the tests. Every function works in source-image pixels.
enum StarAnalysisOverlayGeometry {
    static let maximumStarMarkers = 1000
    static let maximumStarLabels = 100
    static let minimumReliableCellStars = 3
    static let meaningfulCellSpreadFraction = 0.03
    static let minimumOrientationCoherence = 0.25
    static let tiltPerimeterMaximumAxisExtentFraction = 0.4
    static let triangleTiltMaximumRadiusFraction = 0.4

    static func isUsableStar(_ star: StarAnalysisStar) -> Bool {
        star.x.isFinite && star.y.isFinite && star.hfr.isFinite && star.hfr > 0
    }

    /// Sharpest-first star selection, stable by index, bounded.
    static func selectStarIndices(
        _ stars: [StarAnalysisStar],
        maximum: Int = StarAnalysisOverlayGeometry.maximumStarMarkers
    ) -> [Int] {
        stars.indices
            .filter { isUsableStar(stars[$0]) }
            .sorted {
                if stars[$0].hfr != stars[$1].hfr {
                    return stars[$0].hfr < stars[$1].hfr
                }
                return $0 < $1
            }
            .prefix(max(maximum, 0))
            .map { $0 }
    }

    static func isReliableCell(_ cell: StarAnalysisCell?) -> Bool {
        guard let cell, cell.starCount >= minimumReliableCellStars,
            let median = cell.medianHfr, median.isFinite, median > 0
        else { return false }
        return true
    }

    /// The bounds of a 3-by-3 grid cell; multiply-then-divide so adjacent
    /// edges meet exactly.
    static func cellBounds(
        row: Int, col: Int, width: Double, height: Double
    ) -> CGRect {
        precondition((0...2).contains(row) && (0...2).contains(col))
        precondition(width > 0 && height > 0)
        let left = width * Double(col) / 3
        let top = height * Double(row) / 3
        let right = width * Double(col + 1) / 3
        let bottom = height * Double(row + 1) / 3
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    static func findSharpestReliableHfr(_ cells: [StarAnalysisCell?]) -> Double? {
        cells.compactMap { cell -> Double? in
            isReliableCell(cell) ? cell?.medianHfr : nil
        }.min()
    }

    static func classifyCell(
        _ cell: StarAnalysisCell?, sharpestReliableHfr: Double?
    ) -> StarAnalysisCellVisualKind {
        guard isReliableCell(cell), let median = cell?.medianHfr,
            let sharpest = sharpestReliableHfr, sharpest.isFinite, sharpest > 0
        else { return .neutral }
        let softness = (median - sharpest) / sharpest
        if softness < 0.10 { return .good }
        if softness < 0.25 { return .warning }
        return .poor
    }

    /// Whether the reliable cell medians spread enough to mean anything;
    /// seeing noise alone stays below the threshold.
    static func hasMeaningfulReliableSpread(_ cells: [StarAnalysisCell?]) -> Bool {
        let medians = cells.compactMap { cell -> Double? in
            isReliableCell(cell) ? cell?.medianHfr : nil
        }
        guard medians.count >= 2,
            let minimum = medians.min(), let maximum = medians.max(),
            minimum > 0, minimum.isFinite, maximum.isFinite
        else { return false }
        return (maximum - minimum) / minimum >= meaningfulCellSpreadFraction
    }

    static func shouldDrawStarLabel(radii: CGSize, fontSize: Double) -> Bool {
        min(radii.width, radii.height) >= 8 && fontSize >= 8
    }

    static func shouldDrawOrientation(
        normalized: Bool, starCount: Int, meanTheta: Double?, coherence: Double
    ) -> Bool {
        normalized && starCount >= minimumReliableCellStars
            && meanTheta?.isFinite == true
            && coherence.isFinite && coherence > minimumOrientationCoherence
    }

    /// The parallelogram diagram: each reliable corner cell's median HFR,
    /// normalized to the softest corner, pushed diagonally outward. The
    /// corner directions are deliberately un-normalized `(±1, ±1)`, so the
    /// extent applies per axis and equal corners form a square.
    static func tiltPerimeter(
        cells: [StarAnalysisCell],
        width: Double,
        height: Double
    ) -> TiltPerimeterDiagram? {
        guard width > 0, height > 0 else { return nil }
        var byPosition: [Int: StarAnalysisCell] = [:]
        for cell in cells where (0...2).contains(cell.row) && (0...2).contains(cell.col) {
            let key = cell.row * 3 + cell.col
            if let existing = byPosition[key], existing.starCount >= cell.starCount {
                continue
            }
            byPosition[key] = cell
        }
        let cornerOrder: [(row: Int, col: Int, direction: CGPoint)] = [
            (0, 0, CGPoint(x: -1, y: -1)),
            (0, 2, CGPoint(x: 1, y: -1)),
            (2, 2, CGPoint(x: 1, y: 1)),
            (2, 0, CGPoint(x: -1, y: 1)),
        ]
        var corners: [(cell: StarAnalysisCell, direction: CGPoint)] = []
        for corner in cornerOrder {
            guard let cell = byPosition[corner.row * 3 + corner.col],
                isReliableCell(cell)
            else { return nil }
            corners.append((cell, corner.direction))
        }
        let referenceCornerHfr = corners.compactMap(\.cell.medianHfr).max() ?? 0
        guard referenceCornerHfr > 0 else { return nil }
        let maximumAxisExtent =
            min(width, height) * tiltPerimeterMaximumAxisExtentFraction
        let center = CGPoint(x: width / 2, y: height / 2)
        let vertices = corners.map { corner -> TiltPerimeterVertex in
            let median = corner.cell.medianHfr ?? 0
            let normalizedRadius = median / referenceCornerHfr
            return TiltPerimeterVertex(
                row: corner.cell.row,
                column: corner.cell.col,
                starCount: corner.cell.starCount,
                medianHfr: median,
                point: CGPoint(
                    x: center.x + corner.direction.x * normalizedRadius
                        * maximumAxisExtent,
                    y: center.y + corner.direction.y * normalizedRadius
                        * maximumAxisExtent))
        }
        let centerCell = byPosition[1 * 3 + 1]
        let centerMeasurement = isReliableCell(centerCell)
            ? centerCell?.medianHfr
            : nil
        return TiltPerimeterDiagram(
            center: center,
            vertices: vertices,
            centerMeasurement: centerMeasurement,
            referenceCornerHfr: referenceCornerHfr)
    }

    /// The triangle diagram: each ready sector's median HFR, normalized to
    /// the worst sector, pushed along its axis. Angle 0 is image-up and
    /// positive angles turn clockwise on screen, so the direction is
    /// `(sin θ, −cos θ)` in y-down image space.
    static func triangleTilt(
        _ triangle: StarAnalysisTriangleTilt?,
        width: Double,
        height: Double
    ) -> TriangleTiltDiagram? {
        guard let triangle, triangle.ready,
            triangle.minimumStarsPerRegion > 0,
            triangle.sectors.count == 3,
            width > 0, height > 0,
            let worstSector = triangle.worstSector, (1...3).contains(worstSector),
            let overallMedian = triangle.overallMedianHfr,
            overallMedian.isFinite, overallMedian > 0,
            let tiltPercent = triangle.tiltPercent,
            tiltPercent.isFinite, tiltPercent >= 0
        else { return nil }
        for (index, sector) in triangle.sectors.enumerated() {
            guard sector.sector == index + 1,
                sector.starCount >= triangle.minimumStarsPerRegion,
                let median = sector.medianHfr, median.isFinite, median > 0,
                sector.axisAngleDegrees.isFinite,
                sector.axisAngleDegrees >= 0, sector.axisAngleDegrees < 360
            else { return nil }
        }
        let medians = triangle.sectors.compactMap(\.medianHfr)
        guard let referenceWorstHfr = medians.max(),
            let declaredWorst = triangle.sectors
                .first(where: { $0.sector == worstSector })?.medianHfr,
            StarAnalysisContract.nearlyEqual(declaredWorst, referenceWorstHfr)
        else { return nil }

        let center = CGPoint(x: width / 2, y: height / 2)
        let maximumRadius = min(width, height) * triangleTiltMaximumRadiusFraction
        let vertices = triangle.sectors.map { sector -> TriangleTiltVertex in
            let radians = sector.axisAngleDegrees * .pi / 180
            let direction = CGPoint(x: sin(radians), y: -cos(radians))
            let radius = maximumRadius * (sector.medianHfr ?? 0) / referenceWorstHfr
            return TriangleTiltVertex(
                sector: sector.sector,
                axisAngleDegrees: sector.axisAngleDegrees,
                starCount: sector.starCount,
                medianHfr: sector.medianHfr ?? 0,
                point: CGPoint(
                    x: center.x + direction.x * radius,
                    y: center.y + direction.y * radius))
        }
        let centerHfr: Double?
        if triangle.center.starCount >= triangle.minimumStarsPerRegion,
            let median = triangle.center.medianHfr, median.isFinite, median > 0 {
            centerHfr = median
        } else {
            centerHfr = nil
        }
        return TriangleTiltDiagram(
            center: center,
            vertices: vertices,
            centerStarCount: triangle.center.starCount,
            centerHfr: centerHfr,
            referenceWorstHfr: referenceWorstHfr,
            overallMedianHfr: overallMedian,
            tiltPercent: tiltPercent)
    }
}

// MARK: - Precomputed overlay model

/// Everything the overlay needs, computed once when a result arrives so
/// menu enablement and every draw are cheap.
struct StarAnalysisOverlayModel: Equatable, Sendable {
    let result: StarAnalysisResult
    let selectedStarIndices: [Int]
    let cellGrid: [StarAnalysisCell?]
    let sharpestReliableHfr: Double?
    let hasMeaningfulSpread: Bool
    let sharpestCell: (Int, Int)?
    let softestCell: (Int, Int)?
    let tiltPerimeter: TiltPerimeterDiagram?
    let triangleTilt: TriangleTiltDiagram?

    init(result: StarAnalysisResult) {
        self.result = result
        selectedStarIndices = StarAnalysisOverlayGeometry.selectStarIndices(result.stars)
        var grid = [StarAnalysisCell?](repeating: nil, count: 9)
        for cell in result.cells
        where (0...2).contains(cell.row) && (0...2).contains(cell.col) {
            let index = cell.row * 3 + cell.col
            if let existing = grid[index], existing.starCount >= cell.starCount {
                continue
            }
            grid[index] = cell
        }
        cellGrid = grid
        sharpestReliableHfr = StarAnalysisOverlayGeometry.findSharpestReliableHfr(grid)
        hasMeaningfulSpread =
            StarAnalysisOverlayGeometry.hasMeaningfulReliableSpread(grid)
        if hasMeaningfulSpread {
            let reliable = grid.compactMap { cell -> StarAnalysisCell? in
                StarAnalysisOverlayGeometry.isReliableCell(cell) ? cell : nil
            }
            let sharpest = reliable.min {
                ($0.medianHfr ?? .infinity) < ($1.medianHfr ?? .infinity)
            }
            let softest = reliable.max {
                ($0.medianHfr ?? -.infinity) < ($1.medianHfr ?? -.infinity)
            }
            sharpestCell = sharpest.map { ($0.row, $0.col) }
            softestCell = softest.map { ($0.row, $0.col) }
        } else {
            sharpestCell = nil
            softestCell = nil
        }
        tiltPerimeter = StarAnalysisOverlayGeometry.tiltPerimeter(
            cells: result.cells,
            width: Double(result.width),
            height: Double(result.height))
        triangleTilt = StarAnalysisOverlayGeometry.triangleTilt(
            result.triangleTilt,
            width: Double(result.width),
            height: Double(result.height))
    }

    static func == (lhs: StarAnalysisOverlayModel, rhs: StarAnalysisOverlayModel) -> Bool {
        lhs.result == rhs.result
    }
}

// MARK: - Overlay view

/// The measured-star and sensor-tilt overlay. Split into two layers so the
/// translucent tilt grid draws below the solve overlay while the markers
/// and diagrams stay legible on top of everything.
struct StarAnalysisOverlayView: View {
    enum Layer {
        case tiltGrid
        case markers
    }

    let model: StarAnalysisOverlayModel
    let sourceSize: CGSize
    let layer: Layer
    let showsMeasuredStars: Bool
    let showsSensorTilt: Bool
    let showsParallelogramTilt: Bool
    let showsTriangleTilt: Bool
    var rendersAsynchronously = true

    private enum Style {
        static let measuredStar = Color(red: 1.0, green: 0.831, blue: 0.475)
        static let tiltPerimeter = Color(red: 1.0, green: 0.831, blue: 0.475)
        static let triangleTilt = Color(red: 0.384, green: 0.851, blue: 1.0)
        static let grid = Color(red: 0.835, green: 0.878, blue: 0.898).opacity(0.804)
        static let neutralFill = Color(red: 0.510, green: 0.565, blue: 0.604).opacity(0.110)
        static let neutralLabel = Color(red: 0.835, green: 0.878, blue: 0.898)
        static let lowSampleLabel = Color(red: 1.0, green: 0.831, blue: 0.475)
        static let goodFill = Color(red: 0.329, green: 0.820, blue: 0.478).opacity(0.165)
        static let goodLabel = Color(red: 0.451, green: 0.918, blue: 0.580)
        static let warningFill = Color(red: 0.945, green: 0.722, blue: 0.294).opacity(0.180)
        static let warningLabel = Color(red: 1.0, green: 0.831, blue: 0.475)
        static let poorFill = Color(red: 0.914, green: 0.404, blue: 0.404).opacity(0.196)
        static let poorLabel = Color(red: 1.0, green: 0.545, blue: 0.545)
        static let orientation = Color(red: 0.933, green: 0.969, blue: 1.0).opacity(0.863)
        static let labelShadow = Color.black.opacity(0.882)
        static let screenStrokeWidth: CGFloat = 1.35
        static let emphasisStrokeWidth: CGFloat = 2.5
    }

    var body: some View {
        Canvas(rendersAsynchronously: rendersAsynchronously) { context, size in
            guard sourceSize.width > 0, sourceSize.height > 0 else { return }
            let scaleX = size.width / sourceSize.width
            let scaleY = size.height / sourceSize.height
            let markerScale = (scaleX + scaleY) / 2
            switch layer {
            case .tiltGrid:
                if showsSensorTilt {
                    drawSensorTilt(
                        context: &context, scaleX: scaleX, scaleY: scaleY,
                        markerScale: markerScale)
                }
            case .markers:
                if showsMeasuredStars {
                    drawMeasuredStars(
                        context: &context, scaleX: scaleX, scaleY: scaleY,
                        markerScale: markerScale)
                }
                if showsParallelogramTilt, let diagram = model.tiltPerimeter {
                    drawTiltPerimeter(
                        diagram, context: &context, scaleX: scaleX, scaleY: scaleY,
                        markerScale: markerScale)
                }
                if showsTriangleTilt, let diagram = model.triangleTilt {
                    drawTriangleTilt(
                        diagram, context: &context, scaleX: scaleX, scaleY: scaleY,
                        markerScale: markerScale)
                }
            }
        }
    }

    // MARK: Measured stars

    private func drawMeasuredStars(
        context: inout GraphicsContext,
        scaleX: CGFloat, scaleY: CGFloat, markerScale: CGFloat
    ) {
        let fontSize = max(9 * markerScale, 0.1)
        var labelsDrawn = 0
        for index in model.selectedStarIndices {
            let star = model.result.stars[index]
            let sourceRadius = max(2.5 * star.hfr, 5)
            let center = CGPoint(x: star.x * scaleX, y: star.y * scaleY)
            let radii = CGSize(
                width: sourceRadius * scaleX, height: sourceRadius * scaleY)
            guard center.x.isFinite, center.y.isFinite,
                radii.width > 0, radii.height > 0
            else { continue }
            let ellipse = Path(ellipseIn: CGRect(
                x: center.x - radii.width, y: center.y - radii.height,
                width: radii.width * 2, height: radii.height * 2))
            context.stroke(
                ellipse, with: .color(Style.measuredStar),
                lineWidth: Style.screenStrokeWidth)
            if sourceRadius < 8 {
                let dot = CGRect(
                    x: center.x - Style.screenStrokeWidth,
                    y: center.y - Style.screenStrokeWidth,
                    width: Style.screenStrokeWidth * 2,
                    height: Style.screenStrokeWidth * 2)
                context.fill(Path(ellipseIn: dot), with: .color(Style.measuredStar))
            }
            guard labelsDrawn < StarAnalysisOverlayGeometry.maximumStarLabels,
                StarAnalysisOverlayGeometry.shouldDrawStarLabel(
                    radii: radii, fontSize: fontSize)
            else { continue }
            labelsDrawn += 1
            let position = CGPoint(
                x: center.x + radii.width + max(3 * markerScale, 2),
                y: center.y - fontSize * 0.55)
            drawHaloedText(
                String(format: "%.2f", star.hfr),
                at: position,
                anchor: .topLeading,
                fontSize: fontSize,
                color: Style.measuredStar,
                context: &context)
        }
    }

    // MARK: Sensor tilt grid

    private func drawSensorTilt(
        context: inout GraphicsContext,
        scaleX: CGFloat, scaleY: CGFloat, markerScale: CGFloat
    ) {
        let width = Double(sourceSize.width)
        let height = Double(sourceSize.height)
        let sourceFontSize = min(min(width / 3, height / 3) / 18, 72)
        let fontSize = max(max(sourceFontSize, 15) * markerScale, 0.1)

        for row in 0...2 {
            for col in 0...2 {
                let cell = model.cellGrid[row * 3 + col]
                let kind = StarAnalysisOverlayGeometry.classifyCell(
                    cell, sharpestReliableHfr: model.sharpestReliableHfr)
                let sourceBounds = StarAnalysisOverlayGeometry.cellBounds(
                    row: row, col: col, width: width, height: height)
                let bounds = scaledRect(sourceBounds, scaleX: scaleX, scaleY: scaleY)
                context.fill(Path(bounds), with: .color(fillColor(kind)))

                let drawsOrientation = cell.map { value in
                    StarAnalysisOverlayGeometry.shouldDrawOrientation(
                        normalized: model.result.majorAxisOrientationsNormalized,
                        starCount: value.starCount,
                        meanTheta: value.meanTheta,
                        coherence: value.thetaCoherence)
                } ?? false

                if fontSize >= 8,
                    bounds.width >= fontSize * 5, bounds.height >= fontSize * 2.5 {
                    let labelBounds = drawsOrientation
                        ? CGRect(
                            x: bounds.minX, y: bounds.minY,
                            width: bounds.width, height: bounds.height * 0.7)
                        : bounds
                    let color: Color
                    if let cell, cell.starCount > 0,
                        cell.starCount
                            < StarAnalysisOverlayGeometry.minimumReliableCellStars {
                        color = Style.lowSampleLabel
                    } else {
                        color = labelColor(kind)
                    }
                    drawHaloedText(
                        cellLabel(cell),
                        at: CGPoint(x: labelBounds.midX, y: labelBounds.midY),
                        anchor: .center,
                        fontSize: fontSize,
                        color: color,
                        context: &context)
                }

                if drawsOrientation, let cell, let meanTheta = cell.meanTheta {
                    let coherence = min(max(cell.thetaCoherence, 0), 1)
                    let halfLength = min(sourceBounds.width, sourceBounds.height)
                        * (0.09 + 0.07 * coherence)
                    let anchor = CGPoint(
                        x: sourceBounds.midX,
                        y: sourceBounds.minY + sourceBounds.height * 0.78)
                    let dx = cos(meanTheta) * halfLength
                    let dy = sin(meanTheta) * halfLength
                    var path = Path()
                    path.move(to: CGPoint(
                        x: (anchor.x - dx) * scaleX, y: (anchor.y - dy) * scaleY))
                    path.addLine(to: CGPoint(
                        x: (anchor.x + dx) * scaleX, y: (anchor.y + dy) * scaleY))
                    let normalizedCoherence = min(max(
                        (coherence
                            - StarAnalysisOverlayGeometry.minimumOrientationCoherence)
                            / (1 - StarAnalysisOverlayGeometry.minimumOrientationCoherence),
                        0), 1)
                    context.stroke(
                        path, with: .color(Style.orientation),
                        lineWidth: 1.5 + normalizedCoherence * 2.5)
                }
            }
        }

        var gridPath = Path()
        for line in 0...3 {
            let x = width * Double(line) / 3 * scaleX
            gridPath.move(to: CGPoint(x: x, y: 0))
            gridPath.addLine(to: CGPoint(x: x, y: height * scaleY))
            let y = height * Double(line) / 3 * scaleY
            gridPath.move(to: CGPoint(x: 0, y: y))
            gridPath.addLine(to: CGPoint(x: width * scaleX, y: y))
        }
        context.stroke(
            gridPath, with: .color(Style.grid), lineWidth: Style.screenStrokeWidth)

        if model.hasMeaningfulSpread {
            if let sharpest = model.sharpestCell {
                let bounds = scaledRect(
                    StarAnalysisOverlayGeometry.cellBounds(
                        row: sharpest.0, col: sharpest.1,
                        width: width, height: height),
                    scaleX: scaleX, scaleY: scaleY)
                context.stroke(
                    Path(bounds), with: .color(Style.goodLabel),
                    lineWidth: Style.emphasisStrokeWidth)
            }
            if let softest = model.softestCell {
                let bounds = scaledRect(
                    StarAnalysisOverlayGeometry.cellBounds(
                        row: softest.0, col: softest.1,
                        width: width, height: height),
                    scaleX: scaleX, scaleY: scaleY)
                context.stroke(
                    Path(bounds), with: .color(Style.poorLabel),
                    lineWidth: Style.emphasisStrokeWidth)
            }
        }
    }

    static func cellLabelText(_ cell: StarAnalysisCell?) -> String {
        guard let cell, cell.starCount > 0 else { return "No measured stars" }
        var count = "\(cell.starCount) star"
        if cell.starCount != 1 { count += "s" }
        let sample = cell.starCount
            < StarAnalysisOverlayGeometry.minimumReliableCellStars
            ? " · low sample"
            : ""
        if let median = cell.medianHfr {
            return String(format: "HFR %.2f\n%@%@", median, count, sample)
        }
        return "HFR unavailable\n\(count)\(sample)"
    }

    private func cellLabel(_ cell: StarAnalysisCell?) -> String {
        Self.cellLabelText(cell)
    }

    // MARK: Parallelogram tilt

    private func drawTiltPerimeter(
        _ diagram: TiltPerimeterDiagram,
        context: inout GraphicsContext,
        scaleX: CGFloat, scaleY: CGFloat, markerScale: CGFloat
    ) {
        let vertices = diagram.vertices.map {
            CGPoint(x: $0.point.x * scaleX, y: $0.point.y * scaleY)
        }
        let center = CGPoint(
            x: diagram.center.x * scaleX, y: diagram.center.y * scaleY)
        guard vertices.count == 4,
            vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite })
        else { return }

        var edges = Path()
        edges.addLines(vertices + [vertices[0]])
        context.stroke(
            edges, with: .color(Style.tiltPerimeter),
            lineWidth: Style.emphasisStrokeWidth)
        var diagonals = Path()
        diagonals.move(to: vertices[0])
        diagonals.addLine(to: vertices[2])
        diagonals.move(to: vertices[1])
        diagonals.addLine(to: vertices[3])
        context.stroke(
            diagonals, with: .color(Style.tiltPerimeter),
            lineWidth: Style.screenStrokeWidth)
        for vertex in vertices {
            context.fill(
                Path(ellipseIn: CGRect(
                    x: vertex.x - 2.75, y: vertex.y - 2.75, width: 5.5, height: 5.5)),
                with: .color(Style.tiltPerimeter))
        }

        let sourceFontSize = min(max(
            min(Double(sourceSize.width), Double(sourceSize.height)) / 55, 20), 72)
        let fontSize = max(sourceFontSize * markerScale, 0.1)
        guard fontSize >= 8 else { return }
        let imageBounds = CGRect(
            x: 0, y: 0,
            width: sourceSize.width * scaleX, height: sourceSize.height * scaleY)

        for (index, vertex) in vertices.enumerated() {
            let direction = CGPoint(x: vertex.x - center.x, y: vertex.y - center.y)
            let length = (direction.x * direction.x + direction.y * direction.y)
                .squareRoot()
            let outward = length > 0
                ? CGPoint(x: direction.x / length, y: direction.y / length)
                : direction
            let offset = max(fontSize * 0.85, 5)
            let labelCenter = clampLabelCenter(
                CGPoint(
                    x: vertex.x + outward.x * offset,
                    y: vertex.y + outward.y * offset),
                bounds: imageBounds,
                width: fontSize * 5.6, height: fontSize * 1.45)
            drawHaloedText(
                String(format: "HFR %.2f", diagram.vertices[index].medianHfr),
                at: labelCenter,
                anchor: .center,
                fontSize: fontSize,
                color: Style.tiltPerimeter,
                weight: .semibold,
                context: &context)
        }

        let centerText = Self.tiltPerimeterCenterLabel(
            centerMeasurement: diagram.centerMeasurement,
            cornerTiltPercent: model.result.tilt.tiltPercent)
        let centerBox = CGSize(
            width: fontSize * 9.5,
            height: fontSize * (centerText.contains("\n") ? 3.0 : 1.7))
        let centerLabel = clampLabelCenter(
            center, bounds: imageBounds,
            width: centerBox.width, height: centerBox.height)
        drawHaloedText(
            centerText,
            at: centerLabel,
            anchor: .center,
            fontSize: fontSize,
            color: Style.tiltPerimeter,
            weight: .semibold,
            context: &context)
    }

    static func tiltPerimeterCenterLabel(
        centerMeasurement: Double?,
        cornerTiltPercent: Double?
    ) -> String {
        var lines: [String] = []
        if let centerMeasurement {
            lines.append(String(format: "CENTER HFR %.2f", centerMeasurement))
        }
        if let cornerTiltPercent {
            lines.append(String(format: "CORNER TILT %.1f%%", cornerTiltPercent))
        }
        return lines.isEmpty ? "HFR TILT" : lines.joined(separator: "\n")
    }

    // MARK: Triangle tilt

    private func drawTriangleTilt(
        _ diagram: TriangleTiltDiagram,
        context: inout GraphicsContext,
        scaleX: CGFloat, scaleY: CGFloat, markerScale: CGFloat
    ) {
        let vertices = diagram.vertices.map {
            CGPoint(x: $0.point.x * scaleX, y: $0.point.y * scaleY)
        }
        let center = CGPoint(
            x: diagram.center.x * scaleX, y: diagram.center.y * scaleY)
        guard vertices.count == 3,
            vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite })
        else { return }

        var edges = Path()
        edges.addLines(vertices + [vertices[0]])
        context.stroke(
            edges, with: .color(Style.triangleTilt),
            lineWidth: Style.emphasisStrokeWidth)
        var spokes = Path()
        for vertex in vertices {
            spokes.move(to: center)
            spokes.addLine(to: vertex)
        }
        context.stroke(
            spokes, with: .color(Style.triangleTilt),
            lineWidth: Style.screenStrokeWidth)
        for vertex in vertices {
            context.fill(
                Path(ellipseIn: CGRect(
                    x: vertex.x - 2.75, y: vertex.y - 2.75, width: 5.5, height: 5.5)),
                with: .color(Style.triangleTilt))
        }

        let sourceFontSize = min(max(
            min(Double(sourceSize.width), Double(sourceSize.height)) / 55, 20), 72)
        let fontSize = max(sourceFontSize * markerScale, 0.1)
        guard fontSize >= 8 else { return }
        let imageBounds = CGRect(
            x: 0, y: 0,
            width: sourceSize.width * scaleX, height: sourceSize.height * scaleY)

        for (index, vertex) in vertices.enumerated() {
            let source = diagram.vertices[index]
            let direction = CGPoint(x: vertex.x - center.x, y: vertex.y - center.y)
            let length = (direction.x * direction.x + direction.y * direction.y)
                .squareRoot()
            let outward = length > 0
                ? CGPoint(x: direction.x / length, y: direction.y / length)
                : direction
            let offset = max(fontSize * 0.85, 5)
            let labelCenter = clampLabelCenter(
                CGPoint(
                    x: vertex.x + outward.x * offset,
                    y: vertex.y + outward.y * offset),
                bounds: imageBounds,
                width: fontSize * 7.2, height: fontSize * 1.45)
            drawHaloedText(
                String(format: "S%d  HFR %.2f", source.sector, source.medianHfr),
                at: labelCenter,
                anchor: .center,
                fontSize: fontSize,
                color: Style.triangleTilt,
                weight: .semibold,
                context: &context)
        }

        let centerText = Self.triangleTiltCenterLabel(diagram)
        let lineCount = centerText.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let centerBox = CGSize(
            width: fontSize * 10.5,
            height: fontSize * (1.25 + Double(lineCount) * 0.85))
        let centerLabel = clampLabelCenter(
            center, bounds: imageBounds,
            width: centerBox.width, height: centerBox.height)
        drawHaloedText(
            centerText,
            at: centerLabel,
            anchor: .center,
            fontSize: fontSize,
            color: Style.triangleTilt,
            weight: .semibold,
            context: &context)
    }

    static func triangleTiltCenterLabel(_ diagram: TriangleTiltDiagram) -> String {
        var lines: [String] = []
        if let centerHfr = diagram.centerHfr {
            lines.append(String(format: "CENTER HFR %.2f", centerHfr))
        }
        lines.append(String(format: "MEDIAN HFR %.2f", diagram.overallMedianHfr))
        lines.append(String(format: "SECTOR TILT %.1f%%", diagram.tiltPercent))
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    private func fillColor(_ kind: StarAnalysisCellVisualKind) -> Color {
        switch kind {
        case .neutral: Style.neutralFill
        case .good: Style.goodFill
        case .warning: Style.warningFill
        case .poor: Style.poorFill
        }
    }

    private func labelColor(_ kind: StarAnalysisCellVisualKind) -> Color {
        switch kind {
        case .neutral: Style.neutralLabel
        case .good: Style.goodLabel
        case .warning: Style.warningLabel
        case .poor: Style.poorLabel
        }
    }

    private func scaledRect(
        _ rect: CGRect, scaleX: CGFloat, scaleY: CGFloat
    ) -> CGRect {
        CGRect(
            x: rect.minX * scaleX, y: rect.minY * scaleY,
            width: rect.width * scaleX, height: rect.height * scaleY)
    }

    private func clampLabelCenter(
        _ center: CGPoint, bounds: CGRect, width: CGFloat, height: CGFloat
    ) -> CGPoint {
        let halfWidth = min(width / 2, bounds.width / 2)
        let halfHeight = min(height / 2, bounds.height / 2)
        return CGPoint(
            x: min(max(center.x, bounds.minX + halfWidth), bounds.maxX - halfWidth),
            y: min(max(center.y, bounds.minY + halfHeight), bounds.maxY - halfHeight))
    }

    private func drawHaloedText(
        _ string: String,
        at point: CGPoint,
        anchor: UnitPoint,
        fontSize: CGFloat,
        color: Color,
        weight: Font.Weight = .regular,
        context: inout GraphicsContext
    ) {
        let font = Font.system(size: fontSize, weight: weight).monospacedDigit()
        let shadow = Text(string).font(font).foregroundColor(Style.labelShadow)
        for offset in [
            CGPoint(x: -1, y: -1), CGPoint(x: 0, y: -1), CGPoint(x: 1, y: -1),
            CGPoint(x: -1, y: 0), CGPoint(x: 1, y: 0),
            CGPoint(x: -1, y: 1), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1),
        ] {
            context.draw(
                shadow,
                at: CGPoint(x: point.x + offset.x, y: point.y + offset.y),
                anchor: anchor)
        }
        context.draw(
            Text(string).font(font).foregroundColor(color),
            at: point,
            anchor: anchor)
    }
}
