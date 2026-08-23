import Foundation

// MARK: - Errors

enum StarAnalysisError: LocalizedError, Equatable {
    case invalidOptions(String)
    case unsupportedSource
    case missingSource(String)
    case sourceChanged(String)
    case malformedResponse
    case invalidData(String)
    case core(String)

    var errorDescription: String? {
        switch self {
        case .invalidOptions(let message):
            return message
        case .unsupportedSource:
            return "Star analysis currently supports FITS and XISF images."
        case .missingSource:
            return "The image to analyze does not exist."
        case .sourceChanged(let path):
            return "The image changed while its stars were being analyzed: \(path)"
        case .malformedResponse:
            return "The Seiza core returned malformed star analysis JSON."
        case .invalidData(let detail):
            return "The Seiza core returned invalid star analysis data: \(detail)."
        case .core(let message):
            return message
        }
    }
}

// MARK: - Options

/// The native detector's request contract. Absent fields mean "the core
/// decides"; absence is load-bearing, because omitting the preset and the
/// optical scale lets the core classify from FITS/XISF headers.
struct StarAnalysisOptions: Equatable, Sendable {
    enum Preset: String, Sendable {
        case widefield
        case standard
        case longfocal
    }

    enum PSFType: String, Sendable {
        case none
        case gaussian
        case moffat4
    }

    enum StructureRemoval: String, Sendable {
        case filtered
        case atrous
    }

    var preset: Preset? = nil
    var focalLengthMm: Double? = nil
    var pixelSizeUm: Double? = nil
    var psfType: PSFType? = nil
    var structureRemoval: StructureRemoval? = nil
    var detectionBinning: Int? = nil
    var keepSaturated: Bool? = nil
    var noiseReductionRadius: Int? = nil
    var sensitivity: Double? = nil
    var triangleAngleDegrees: Double? = nil

    /// The only options the interactive UI sends: bounded work on large
    /// frames without overriding the core's header classification.
    static let interactiveDefault = StarAnalysisOptions(
        psfType: .moffat4,
        detectionBinning: 2,
        sensitivity: 30,
        triangleAngleDegrees: 0)

    func validate() throws {
        if (focalLengthMm == nil) != (pixelSizeUm == nil) {
            throw StarAnalysisError.invalidOptions(
                "Focal length and pixel size must be provided together.")
        }
        if preset != nil, focalLengthMm != nil {
            throw StarAnalysisError.invalidOptions(
                "Choose a detector preset or provide focal length and pixel size, "
                    + "not both.")
        }
        for value in [focalLengthMm, pixelSizeUm].compactMap({ $0 })
        where !value.isFinite || value <= 0 {
            throw StarAnalysisError.invalidOptions(
                "The value must be finite and positive.")
        }
        if let detectionBinning, !(1...16).contains(detectionBinning) {
            throw StarAnalysisError.invalidOptions(
                "Detection binning must be between 1 and 16.")
        }
        if let noiseReductionRadius, !(0...64).contains(noiseReductionRadius) {
            throw StarAnalysisError.invalidOptions(
                "Noise reduction radius must be between 0 and 64 pixels.")
        }
        if let sensitivity, !sensitivity.isFinite || sensitivity <= 0 {
            throw StarAnalysisError.invalidOptions(
                "Sensitivity must be a finite positive value.")
        }
        if let triangleAngleDegrees, !triangleAngleDegrees.isFinite {
            throw StarAnalysisError.invalidOptions("The triangle angle must be finite.")
        }
    }

    /// Deterministic camelCase JSON with absent keys omitted. Validates
    /// first, so an invalid options object never reaches the cache or the
    /// native layer.
    func jsonString() throws -> String {
        try validate()
        var payload: [(String, Any)] = []
        if let preset { payload.append(("preset", preset.rawValue)) }
        if let focalLengthMm { payload.append(("focalLengthMm", focalLengthMm)) }
        if let pixelSizeUm { payload.append(("pixelSizeUm", pixelSizeUm)) }
        if let psfType { payload.append(("psfType", psfType.rawValue)) }
        if let structureRemoval {
            payload.append(("structureRemoval", structureRemoval.rawValue))
        }
        if let detectionBinning { payload.append(("detectionBinning", detectionBinning)) }
        if let keepSaturated { payload.append(("keepSaturated", keepSaturated)) }
        if let noiseReductionRadius {
            payload.append(("noiseReductionRadius", noiseReductionRadius))
        }
        if let sensitivity { payload.append(("sensitivity", sensitivity)) }
        if let triangleAngleDegrees {
            payload.append(("triangleAngleDegrees", triangleAngleDegrees))
        }
        let fields = payload.map { key, value -> String in
            switch value {
            case let text as String:
                return "\"\(key)\":\"\(text)\""
            case let flag as Bool:
                return "\"\(key)\":\(flag)"
            case let number as Int:
                return "\"\(key)\":\(number)"
            case let number as Double:
                return "\"\(key)\":\(formatJSONNumber(number))"
            default:
                return "\"\(key)\":null"
            }
        }
        return "{" + fields.joined(separator: ",") + "}"
    }
}

private func formatJSONNumber(_ value: Double) -> String {
    if value == value.rounded(), abs(value) < 1e15 {
        return String(Int64(value))
    }
    return "\(value)"
}

// MARK: - Response models

struct StarAnalysisStar: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var hfr: Double
    var fwhm: Double
    var brightness: Double
    var background: Double
    var snr: Double
    var flux: Double
    var pixelCount: Int
    var saturated: Bool
    var eccentricity: Double? = nil
    var theta: Double? = nil
    var rSquared: Double? = nil
}

struct StarAnalysisCell: Codable, Equatable, Sendable {
    var row: Int
    var col: Int
    var starCount: Int
    var medianHfr: Double? = nil
    var medianEccentricity: Double? = nil
    var meanTheta: Double? = nil
    var thetaCoherence: Double = 0
}

enum StarAnalysisCornerPosition: String, Codable, Sendable, CaseIterable {
    case topLeft = "top-left"
    case topRight = "top-right"
    case bottomLeft = "bottom-left"
    case bottomRight = "bottom-right"

    var cell: (row: Int, col: Int) {
        switch self {
        case .topLeft: (0, 0)
        case .topRight: (0, 2)
        case .bottomLeft: (2, 0)
        case .bottomRight: (2, 2)
        }
    }

    var displayName: String {
        switch self {
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        }
    }
}

struct StarAnalysisCorner: Codable, Equatable, Sendable {
    var corner: StarAnalysisCornerPosition
    var hfr: Double? = nil
}

struct StarAnalysisTilt: Codable, Equatable, Sendable {
    var centerHfr: Double? = nil
    var corners: [StarAnalysisCorner] = []
    var meanHfr: Double? = nil
    var tiltPercent: Double? = nil
    var curvaturePercent: Double? = nil
    var worstCorner: StarAnalysisCornerPosition? = nil
    var bestCorner: StarAnalysisCornerPosition? = nil
}

struct StarAnalysisTriangleCenter: Codable, Equatable, Sendable {
    var starCount: Int
    var medianHfr: Double? = nil
}

struct StarAnalysisTriangleSector: Codable, Equatable, Sendable {
    var sector: Int
    var axisAngleDegrees: Double
    var starCount: Int
    var medianHfr: Double? = nil
}

struct StarAnalysisTriangleTilt: Codable, Equatable, Sendable {
    var angleDegrees: Double
    var innerRadiusPixels: Double
    var outerRadiusPixels: Double
    var minimumStarsPerRegion: Int
    var ready: Bool
    var center: StarAnalysisTriangleCenter
    var sectors: [StarAnalysisTriangleSector] = []
    var overallMedianHfr: Double? = nil
    var tiltPercent: Double? = nil
    var bestSector: Int? = nil
    var worstSector: Int? = nil
}

struct StarAnalysisResult: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var width: Int
    var height: Int
    var majorAxisOrientationsNormalized: Bool = false
    var averageHfr: Double
    var averageFwhm: Double
    var noiseSigma: Double
    var backgroundMean: Double
    var stars: [StarAnalysisStar] = []
    var cells: [StarAnalysisCell] = []
    var tilt: StarAnalysisTilt
    var triangleTilt: StarAnalysisTriangleTilt? = nil

    var hasPSFMeasurements: Bool {
        stars.contains { $0.eccentricity != nil && $0.theta != nil }
    }

    func cell(row: Int, col: Int) -> StarAnalysisCell? {
        cells.first { $0.row == row && $0.col == col }
    }
}

// MARK: - Contract validation

enum StarAnalysisContract {
    static func normalizeDegrees(_ value: Double) -> Double {
        let wrapped = value.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    static func nearlyEqual(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) <= 1e-9 * max(1, abs(a), abs(b))
    }

    /// Decodes and fully validates a native response against the request.
    /// Every rejection names its defect; a violated invariant must never
    /// reach the renderer.
    static func decode(
        _ json: String,
        requestedTriangleAngle: Double?
    ) throws -> StarAnalysisResult {
        let result: StarAnalysisResult
        do {
            result = try JSONDecoder().decode(
                StarAnalysisResult.self, from: Data(json.utf8))
        } catch {
            throw StarAnalysisError.malformedResponse
        }
        try validate(result)
        try validateTriangleRequest(
            result, requestedTriangleAngle: requestedTriangleAngle)
        return result
    }

    static func validate(_ result: StarAnalysisResult) throws {
        func reject(_ detail: String) throws -> Never {
            throw StarAnalysisError.invalidData(detail)
        }

        guard result.schemaVersion == 1 else {
            try reject("unsupported star analysis schema version \(result.schemaVersion)")
        }
        guard result.width > 0, result.height > 0 else {
            try reject("image dimensions must be positive")
        }
        for (name, value) in [
            ("average HFR", result.averageHfr),
            ("average FWHM", result.averageFwhm),
            ("noise sigma", result.noiseSigma),
            ("background mean", result.backgroundMean),
        ] where !value.isFinite || value < 0 {
            try reject("\(name) must be finite and non-negative")
        }
        if !result.stars.isEmpty, result.averageHfr <= 0 {
            try reject("average HFR must be positive when stars were measured")
        }

        for (index, star) in result.stars.enumerated() {
            guard star.x.isFinite, star.x >= 0, star.x < Double(result.width) else {
                try reject("star \(index) X is outside the image")
            }
            guard star.y.isFinite, star.y >= 0, star.y < Double(result.height) else {
                try reject("star \(index) Y is outside the image")
            }
            guard star.hfr.isFinite, star.hfr > 0 else {
                try reject("star \(index) HFR must be positive")
            }
            for (name, value) in [
                ("FWHM", star.fwhm), ("brightness", star.brightness),
                ("background", star.background), ("SNR", star.snr),
                ("flux", star.flux),
            ] where !value.isFinite || value < 0 {
                try reject("star \(index) \(name) must be finite and non-negative")
            }
            guard star.pixelCount > 0 else {
                try reject("star \(index) pixel count must be positive")
            }
            let psfFields = [star.eccentricity, star.theta, star.rSquared]
            let presentCount = psfFields.compactMap { $0 }.count
            if presentCount != 0 && presentCount != psfFields.count {
                try reject("star \(index) has an incomplete PSF measurement")
            }
            if let eccentricity = star.eccentricity,
                !eccentricity.isFinite || eccentricity < 0 || eccentricity > 1 {
                try reject("star \(index) eccentricity is outside [0, 1]")
            }
            if let theta = star.theta {
                guard theta.isFinite else {
                    try reject("star \(index) theta must be finite")
                }
                if result.majorAxisOrientationsNormalized,
                    theta < 0 || theta >= Double.pi {
                    try reject("star \(index) theta is outside the normalized range")
                }
            }
            if let rSquared = star.rSquared, !rSquared.isFinite || rSquared > 1 {
                try reject("star \(index) r-squared is invalid")
            }
        }

        guard result.cells.count == 9 else {
            try reject("the tilt grid must contain 9 cells")
        }
        var seenCells = Set<Int>()
        var cellStarTotal = 0
        for cell in result.cells {
            guard (0...2).contains(cell.row), (0...2).contains(cell.col) else {
                try reject("cell \(cell.row),\(cell.col) is outside the grid")
            }
            guard seenCells.insert(cell.row * 3 + cell.col).inserted else {
                try reject("cell \(cell.row),\(cell.col) appears more than once")
            }
            guard cell.starCount >= 0 else {
                try reject("cell \(cell.row),\(cell.col) star count is negative")
            }
            cellStarTotal += cell.starCount
            guard cell.thetaCoherence.isFinite,
                cell.thetaCoherence >= 0, cell.thetaCoherence <= 1
            else {
                try reject("cell \(cell.row),\(cell.col) coherence is outside [0, 1]")
            }
            if cell.starCount == 0 {
                if cell.medianHfr != nil || cell.medianEccentricity != nil
                    || cell.meanTheta != nil || cell.thetaCoherence != 0 {
                    try reject("empty cell \(cell.row),\(cell.col) contains measurements")
                }
            } else {
                guard let medianHfr = cell.medianHfr, medianHfr.isFinite, medianHfr >= 0
                else {
                    try reject("non-empty cell \(cell.row),\(cell.col) is missing median HFR")
                }
            }
            if let medianEccentricity = cell.medianEccentricity,
                !medianEccentricity.isFinite || medianEccentricity < 0
                    || medianEccentricity > 1 {
                try reject("cell \(cell.row),\(cell.col) eccentricity is outside [0, 1]")
            }
            if let meanTheta = cell.meanTheta {
                guard meanTheta.isFinite else {
                    try reject("cell \(cell.row),\(cell.col) direction must be finite")
                }
                if result.majorAxisOrientationsNormalized,
                    meanTheta < 0 || meanTheta >= Double.pi {
                    try reject("cell \(cell.row),\(cell.col) direction is outside the normalized range")
                }
            } else if cell.thetaCoherence != 0 {
                try reject("cell \(cell.row),\(cell.col) has coherence without a direction")
            }
        }
        guard cellStarTotal == result.stars.count else {
            try reject("cell star counts do not match the detected-star count")
        }

        try validateTilt(result)
        if let triangle = result.triangleTilt {
            try validateTriangle(triangle, result: result)
        }
    }

    private static func validateTilt(_ result: StarAnalysisResult) throws {
        func reject(_ detail: String) throws -> Never {
            throw StarAnalysisError.invalidData(detail)
        }
        let tilt = result.tilt
        guard tilt.corners.count == 4 else {
            try reject("the tilt summary must contain 4 corners")
        }
        var seen = Set<StarAnalysisCornerPosition>()
        for corner in tilt.corners {
            guard seen.insert(corner.corner).inserted else {
                try reject("\(corner.corner.displayName) appears more than once")
            }
            let cell = corner.corner.cell
            let gridMedian = result.cell(row: cell.row, col: cell.col)?.medianHfr
            guard valuesMatch(corner.hfr, gridMedian) else {
                try reject("\(corner.corner.displayName) HFR does not match its grid cell")
            }
        }
        let centerMedian = result.cell(row: 1, col: 1)?.medianHfr
        guard valuesMatch(tilt.centerHfr, centerMedian) else {
            try reject("center HFR does not match the center grid cell")
        }
        let allCornersMeasured = tilt.corners.allSatisfy { $0.hfr != nil }
        let verdictFields = [
            tilt.tiltPercent != nil,
            tilt.worstCorner != nil,
            tilt.bestCorner != nil,
        ]
        if Set(verdictFields).count != 1
            || (tilt.tiltPercent != nil && !allCornersMeasured) {
            try reject("tilt verdict and best/worst corners are inconsistent")
        }
        let anyCellMedian = result.cells.contains { $0.medianHfr != nil }
        guard (tilt.meanHfr != nil) == anyCellMedian else {
            try reject("mean HFR availability does not match the grid")
        }
        let curvaturePossible = allCornersMeasured
            && (tilt.centerHfr ?? 0) > 0
        guard (tilt.curvaturePercent != nil) == curvaturePossible else {
            try reject("curvature verdict availability does not match the grid")
        }
    }

    private static func validateTriangle(
        _ triangle: StarAnalysisTriangleTilt,
        result: StarAnalysisResult
    ) throws {
        func reject(_ detail: String) throws -> Never {
            throw StarAnalysisError.invalidData(detail)
        }
        guard triangle.angleDegrees.isFinite,
            triangle.angleDegrees >= 0, triangle.angleDegrees < 360
        else {
            try reject("triangle angle is outside [0, 360)")
        }
        let width = Double(result.width)
        let height = Double(result.height)
        let expectedInner = 0.25 * ((width / 2) * (width / 2)
            + (height / 2) * (height / 2)).squareRoot()
        let expectedOuter = 0.5 * min(width, height)
        guard nearlyEqual(triangle.innerRadiusPixels, expectedInner),
            nearlyEqual(triangle.outerRadiusPixels, expectedOuter)
        else {
            try reject("triangle inner/outer radius does not match the image dimensions")
        }
        guard triangle.minimumStarsPerRegion == 3 else {
            try reject("triangle minimum stars per region must be 3")
        }
        guard triangle.sectors.count == 3,
            triangle.sectors.enumerated().allSatisfy({ $0.element.sector == $0.offset + 1 })
        else {
            try reject("triangle sectors must be ordered 1, 2, 3")
        }
        var sectorStarTotal = 0
        for sector in triangle.sectors {
            let expectedAxis = normalizeDegrees(
                triangle.angleDegrees + Double(sector.sector - 1) * 120)
            guard sector.axisAngleDegrees.isFinite,
                nearlyEqual(sector.axisAngleDegrees, expectedAxis)
            else {
                try reject("triangle sector axis angle is inconsistent")
            }
            guard sector.starCount >= 0 else {
                try reject("triangle sector star count is negative")
            }
            sectorStarTotal += sector.starCount
            guard (sector.medianHfr != nil) == (sector.starCount > 0) else {
                try reject("triangle sector median HFR availability is inconsistent")
            }
            if let median = sector.medianHfr, !median.isFinite || median <= 0 {
                try reject("triangle sector median HFR must be positive")
            }
        }
        guard (triangle.center.medianHfr != nil) == (triangle.center.starCount > 0)
        else {
            try reject("triangle center median HFR availability is inconsistent")
        }
        if let median = triangle.center.medianHfr, !median.isFinite || median <= 0 {
            try reject("triangle center median HFR must be positive")
        }
        guard triangle.center.starCount + sectorStarTotal <= result.stars.count else {
            try reject("triangle regions exceed the detected-star count")
        }
        let hasAnnulus = triangle.innerRadiusPixels < triangle.outerRadiusPixels
        if !hasAnnulus, sectorStarTotal != 0 {
            try reject("triangle sectors contain stars without a usable annulus")
        }
        guard (triangle.overallMedianHfr != nil) == (sectorStarTotal > 0) else {
            try reject("triangle overall median HFR availability is inconsistent")
        }
        if let overall = triangle.overallMedianHfr, !overall.isFinite || overall <= 0 {
            try reject("triangle overall median HFR must be positive")
        }
        let expectedReady = hasAnnulus
            && triangle.sectors.allSatisfy {
                $0.starCount >= triangle.minimumStarsPerRegion
            }
            && triangle.overallMedianHfr != nil
        guard triangle.ready == expectedReady else {
            try reject("triangle readiness is inconsistent")
        }
        let verdictFields = [
            triangle.tiltPercent != nil,
            triangle.bestSector != nil,
            triangle.worstSector != nil,
        ]
        guard Set(verdictFields).count == 1,
            (triangle.tiltPercent != nil) == triangle.ready
        else {
            try reject("triangle verdict and readiness are inconsistent")
        }
        if triangle.ready {
            let medians = triangle.sectors.compactMap { sector in
                sector.medianHfr.map { (sector.sector, $0) }
            }
            let best = medians.min { ($0.1, $0.0) < ($1.1, $1.0) }
            let worst = medians.max { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.0 > rhs.0
            }
            guard triangle.bestSector == best?.0, triangle.worstSector == worst?.0
            else {
                try reject("triangle best/worst sectors are inconsistent")
            }
            if let overall = triangle.overallMedianHfr,
                let bestMedian = best?.1, let worstMedian = worst?.1,
                let tiltPercent = triangle.tiltPercent {
                let expected = 100 * (worstMedian - bestMedian) / overall
                guard nearlyEqual(tiltPercent, expected) else {
                    try reject("triangle tilt percent is inconsistent")
                }
            }
        }
    }

    static func validateTriangleRequest(
        _ result: StarAnalysisResult,
        requestedTriangleAngle: Double?
    ) throws {
        func reject(_ detail: String) throws -> Never {
            throw StarAnalysisError.invalidData(detail)
        }
        switch (requestedTriangleAngle, result.triangleTilt) {
        case (nil, nil):
            return
        case (nil, .some):
            try reject("triangle tilt was returned without being requested")
        case (.some, nil):
            try reject("triangle tilt is missing from a request that enabled it")
        case (.some(let requested), .some(let triangle)):
            guard nearlyEqual(
                triangle.angleDegrees, normalizeDegrees(requested))
            else {
                try reject("triangle angle does not match the requested angle")
            }
        }
    }

    private static func valuesMatch(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil):
            return true
        case (.some(let lhs), .some(let rhs)):
            return nearlyEqual(lhs, rhs)
        default:
            return false
        }
    }
}
