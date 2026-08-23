import XCTest

@testable import Seiza

// MARK: - Payload builder

/// Builds a canonical, internally consistent native response that the
/// contract validator accepts, so each defect test mutates exactly one
/// thing.
private enum StarPayload {
    static func valid(
        width: Int = 1000,
        height: Int = 500,
        includeTriangle: Bool = true,
        mutate: (inout [String: Any]) -> Void = { _ in }
    ) -> String {
        var stars: [[String: Any]] = []
        for index in 0..<15 {
            stars.append([
                "x": Double(10 + index * 5), "y": Double(10 + index * 3),
                "hfr": 2.0, "fwhm": 4.7, "brightness": 900.0,
                "background": 100.0, "snr": 40.0, "flux": 5000.0,
                "pixelCount": 20, "saturated": false,
            ])
        }
        func cell(
            _ row: Int, _ col: Int, count: Int, median: Double?
        ) -> [String: Any] {
            [
                "row": row, "col": col, "starCount": count,
                "medianHfr": median as Any, "medianEccentricity": NSNull(),
                "meanTheta": NSNull(), "thetaCoherence": 0,
            ]
        }
        let cells: [[String: Any]] = [
            cell(0, 0, count: 3, median: 2), cell(0, 1, count: 0, median: nil),
            cell(0, 2, count: 3, median: 2), cell(1, 0, count: 0, median: nil),
            cell(1, 1, count: 3, median: 2), cell(1, 2, count: 0, median: nil),
            cell(2, 0, count: 3, median: 2), cell(2, 1, count: 0, median: nil),
            cell(2, 2, count: 3, median: 2),
        ]
        let tilt: [String: Any] = [
            "centerHfr": 2.0,
            "corners": [
                ["corner": "top-left", "hfr": 2.0],
                ["corner": "top-right", "hfr": 2.0],
                ["corner": "bottom-left", "hfr": 2.0],
                ["corner": "bottom-right", "hfr": 2.0],
            ],
            "meanHfr": 2.0, "tiltPercent": 0.0, "curvaturePercent": 0.0,
            "worstCorner": "top-left", "bestCorner": "top-left",
        ]
        var payload: [String: Any] = [
            "schemaVersion": 1, "width": width, "height": height,
            "majorAxisOrientationsNormalized": true,
            "averageHfr": 2.0, "averageFwhm": 4.7,
            "noiseSigma": 12.0, "backgroundMean": 100.0,
            "stars": stars, "cells": cells, "tilt": tilt,
        ]
        if includeTriangle {
            let halfWidth = Double(width) / 2
            let halfHeight = Double(height) / 2
            payload["triangleTilt"] = [
                "angleDegrees": 0.0,
                "innerRadiusPixels":
                    0.25 * (halfWidth * halfWidth + halfHeight * halfHeight)
                        .squareRoot(),
                "outerRadiusPixels": 0.5 * Double(min(width, height)),
                "minimumStarsPerRegion": 3,
                "ready": true,
                "center": ["starCount": 3, "medianHfr": 2.0],
                "sectors": [
                    ["sector": 1, "axisAngleDegrees": 0.0, "starCount": 3,
                     "medianHfr": 2.0],
                    ["sector": 2, "axisAngleDegrees": 120.0, "starCount": 3,
                     "medianHfr": 2.0],
                    ["sector": 3, "axisAngleDegrees": 240.0, "starCount": 3,
                     "medianHfr": 4.0],
                ],
                "overallMedianHfr": 2.0,
                "tiltPercent": 100.0,
                "bestSector": 1,
                "worstSector": 3,
            ] as [String: Any]
        }
        mutate(&payload)
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return String(decoding: data, as: UTF8.self)
    }

    static func mutateTriangle(
        _ payload: inout [String: Any], _ key: String, _ value: Any
    ) {
        var triangle = payload["triangleTilt"] as! [String: Any]
        triangle[key] = value
        payload["triangleTilt"] = triangle
    }
}

// MARK: - Options

final class StarAnalysisOptionsTests: XCTestCase {
    func testInteractiveDefaultBoundsWorkWithoutOverridingClassification() throws {
        let options = StarAnalysisOptions.interactiveDefault
        XCTAssertEqual(options.psfType, .moffat4)
        XCTAssertEqual(options.detectionBinning, 2)
        XCTAssertEqual(options.sensitivity, 30)
        XCTAssertEqual(options.triangleAngleDegrees, 0)
        XCTAssertNil(options.preset)
        XCTAssertNil(options.focalLengthMm)
        XCTAssertNil(options.pixelSizeUm)
        XCTAssertEqual(
            try options.jsonString(),
            #"{"psfType":"moffat4","detectionBinning":2,"sensitivity":30,"#
                + #""triangleAngleDegrees":0}"#)
    }

    func testValidationRejectsAmbiguousAndOutOfRangeOptions() {
        func message(_ options: StarAnalysisOptions) -> String? {
            do {
                _ = try options.jsonString()
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        var focalOnly = StarAnalysisOptions()
        focalOnly.focalLengthMm = 750
        XCTAssertEqual(
            message(focalOnly),
            "Focal length and pixel size must be provided together.")
        var both = StarAnalysisOptions()
        both.preset = .standard
        both.focalLengthMm = 750
        both.pixelSizeUm = 3.76
        XCTAssertEqual(
            message(both),
            "Choose a detector preset or provide focal length and pixel size, "
                + "not both.")
        var badBinning = StarAnalysisOptions()
        badBinning.detectionBinning = 17
        XCTAssertEqual(
            message(badBinning), "Detection binning must be between 1 and 16.")
        var badRadius = StarAnalysisOptions()
        badRadius.noiseReductionRadius = 65
        XCTAssertEqual(
            message(badRadius),
            "Noise reduction radius must be between 0 and 64 pixels.")
        var badSensitivity = StarAnalysisOptions()
        badSensitivity.sensitivity = 0
        XCTAssertEqual(
            message(badSensitivity), "Sensitivity must be a finite positive value.")
        var badAngle = StarAnalysisOptions()
        badAngle.triangleAngleDegrees = .nan
        XCTAssertEqual(message(badAngle), "The triangle angle must be finite.")
    }

    func testUnnormalizedTriangleAngleIsPassedThrough() throws {
        var options = StarAnalysisOptions()
        options.triangleAngleDegrees = 725
        XCTAssertEqual(try options.jsonString(), #"{"triangleAngleDegrees":725}"#)
    }
}

// MARK: - Contract validation

final class StarAnalysisContractTests: XCTestCase {
    private func decodeError(
        _ json: String, requestedAngle: Double? = 0
    ) -> String? {
        do {
            _ = try StarAnalysisContract.decode(
                json, requestedTriangleAngle: requestedAngle)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func testCanonicalPayloadDecodesAndValidates() throws {
        let result = try StarAnalysisContract.decode(
            StarPayload.valid(), requestedTriangleAngle: 0)
        XCTAssertEqual(result.width, 1000)
        XCTAssertEqual(result.stars.count, 15)
        XCTAssertEqual(result.cells.count, 9)
        XCTAssertEqual(result.triangleTilt?.ready, true)
        XCTAssertEqual(result.triangleTilt?.tiltPercent, 100)
        XCTAssertFalse(result.hasPSFMeasurements)
    }

    func testEmptyDetectionIsAValidMeasuredResult() throws {
        let json = StarPayload.valid(includeTriangle: false) { payload in
            payload["stars"] = [Any]()
            payload["averageHfr"] = 0.0
            payload["averageFwhm"] = 0.0
            var cells = payload["cells"] as! [[String: Any]]
            for index in cells.indices {
                cells[index]["starCount"] = 0
                cells[index]["medianHfr"] = NSNull()
            }
            payload["cells"] = cells
            payload["tilt"] = [
                "centerHfr": NSNull(),
                "corners": [
                    ["corner": "top-left", "hfr": NSNull()],
                    ["corner": "top-right", "hfr": NSNull()],
                    ["corner": "bottom-left", "hfr": NSNull()],
                    ["corner": "bottom-right", "hfr": NSNull()],
                ],
                "meanHfr": NSNull(), "tiltPercent": NSNull(),
                "curvaturePercent": NSNull(),
                "worstCorner": NSNull(), "bestCorner": NSNull(),
            ] as [String: Any]
        }
        let result = try StarAnalysisContract.decode(
            json, requestedTriangleAngle: nil)
        XCTAssertTrue(result.stars.isEmpty)
        XCTAssertNil(result.tilt.tiltPercent)
    }

    func testSchemaAndBoundsDefectsAreRejected() {
        XCTAssertTrue(decodeError(StarPayload.valid { $0["schemaVersion"] = 2 })!
            .contains("schema version 2"))
        XCTAssertEqual(decodeError("null"), StarAnalysisError.malformedResponse
            .localizedDescription)
        let outOfFrame = StarPayload.valid { payload in
            var stars = payload["stars"] as! [[String: Any]]
            stars[0]["x"] = 1000.0
            payload["stars"] = stars
        }
        XCTAssertTrue(decodeError(outOfFrame)!.contains("star 0 X"))
    }

    func testTriangleDefectsAreRejectedWithNamedReasons() {
        let cases: [(String, (inout [String: Any]) -> Void)] = [
            ("triangle angle", { StarPayload.mutateTriangle(&$0, "angleDegrees", 360.0) }),
            ("image dimensions", { StarPayload.mutateTriangle(&$0, "innerRadiusPixels", 17.0) }),
            ("minimum stars per region must be 3",
             { StarPayload.mutateTriangle(&$0, "minimumStarsPerRegion", 2) }),
            ("ordered 1, 2, 3", { payload in
                var triangle = payload["triangleTilt"] as! [String: Any]
                var sectors = triangle["sectors"] as! [[String: Any]]
                sectors[0]["sector"] = 2
                triangle["sectors"] = sectors
                payload["triangleTilt"] = triangle
            }),
            ("axis angle is inconsistent", { payload in
                var triangle = payload["triangleTilt"] as! [String: Any]
                var sectors = triangle["sectors"] as! [[String: Any]]
                sectors[1]["axisAngleDegrees"] = 121.0
                triangle["sectors"] = sectors
                payload["triangleTilt"] = triangle
            }),
            ("median HFR availability", { payload in
                var triangle = payload["triangleTilt"] as! [String: Any]
                var sectors = triangle["sectors"] as! [[String: Any]]
                sectors[0]["medianHfr"] = NSNull()
                triangle["sectors"] = sectors
                payload["triangleTilt"] = triangle
            }),
            ("readiness is inconsistent",
             { StarPayload.mutateTriangle(&$0, "ready", false) }),
            ("verdict and readiness", { payload in
                StarPayload.mutateTriangle(&payload, "bestSector", NSNull())
            }),
            ("best/worst sectors",
             { StarPayload.mutateTriangle(&$0, "bestSector", 2) }),
            ("tilt percent is inconsistent",
             { StarPayload.mutateTriangle(&$0, "tiltPercent", 51.0) }),
            ("overall median HFR availability",
             { StarPayload.mutateTriangle(&$0, "overallMedianHfr", NSNull()) }),
            ("exceed the detected-star count", { payload in
                StarPayload.mutateTriangle(
                    &payload, "center", ["starCount": 20, "medianHfr": 2.0])
            }),
        ]
        for (expected, mutate) in cases {
            let message = decodeError(StarPayload.valid(mutate: mutate))
            XCTAssertNotNil(message, expected)
            XCTAssertTrue(
                message?.contains(expected) == true,
                "expected '\(expected)' in '\(message ?? "nil")'")
        }
    }

    func testTriangleMustCorrelateWithItsRequest() {
        XCTAssertTrue(decodeError(
            StarPayload.valid(includeTriangle: false), requestedAngle: 0)!
            .contains("missing from a request that enabled it"))
        XCTAssertTrue(decodeError(StarPayload.valid(), requestedAngle: nil)!
            .contains("without being requested"))
        XCTAssertTrue(decodeError(StarPayload.valid(), requestedAngle: 120)!
            .contains("does not match the requested angle"))
        // 725 normalizes to 5; a payload at angle 5 with matching axes passes.
        let normalized = StarPayload.valid { payload in
            StarPayload.mutateTriangle(&payload, "angleDegrees", 5.0)
            var triangle = payload["triangleTilt"] as! [String: Any]
            var sectors = triangle["sectors"] as! [[String: Any]]
            sectors[0]["axisAngleDegrees"] = 5.0
            sectors[1]["axisAngleDegrees"] = 125.0
            sectors[2]["axisAngleDegrees"] = 245.0
            triangle["sectors"] = sectors
            payload["triangleTilt"] = triangle
        }
        XCTAssertNil(decodeError(normalized, requestedAngle: 725))
    }
}

// MARK: - Geometry

final class StarAnalysisGeometryTests: XCTestCase {
    private func cell(
        _ row: Int, _ col: Int, count: Int, median: Double?
    ) -> StarAnalysisCell {
        StarAnalysisCell(
            row: row, col: col, starCount: count, medianHfr: median,
            medianEccentricity: nil, meanTheta: nil, thetaCoherence: 0)
    }

    private func cornerCells(
        topLeft: Double = 2, topRight: Double = 2,
        bottomLeft: Double = 2, bottomRight: Double = 2,
        center: Double? = 2
    ) -> [StarAnalysisCell] {
        var cells = [
            cell(0, 0, count: 3, median: topLeft),
            cell(0, 2, count: 3, median: topRight),
            cell(2, 0, count: 3, median: bottomLeft),
            cell(2, 2, count: 3, median: bottomRight),
        ]
        if let center {
            cells.append(cell(1, 1, count: 3, median: center))
        }
        return cells
    }

    func testStarSelectionIsSharpestFirstAndBounded() {
        func star(_ hfr: Double, x: Double = 10) -> StarAnalysisStar {
            StarAnalysisStar(
                x: x, y: 10, hfr: hfr, fwhm: 1, brightness: 1, background: 1,
                snr: 1, flux: 1, pixelCount: 1, saturated: false)
        }
        var stars = [
            star(4), star(.nan), star(1.5), star(2), star(3, x: .infinity), star(0),
        ]
        stars[1].hfr = .nan
        XCTAssertEqual(
            StarAnalysisOverlayGeometry.selectStarIndices(stars, maximum: 2), [2, 3])

        let many = (0..<1200).map { star(Double(1200 - $0)) }
        let selected = StarAnalysisOverlayGeometry.selectStarIndices(many)
        XCTAssertEqual(selected.count, 1000)
        XCTAssertEqual(selected.first, 1199)
        XCTAssertEqual(selected.last, 200)
    }

    func testCellClassificationBoundaries() {
        func classify(_ median: Double) -> StarAnalysisCellVisualKind {
            StarAnalysisOverlayGeometry.classifyCell(
                cell(0, 0, count: 3, median: median), sharpestReliableHfr: 10)
        }
        XCTAssertEqual(classify(10.0), .good)
        XCTAssertEqual(classify(10.99), .good)
        XCTAssertEqual(classify(11.0), .warning)
        XCTAssertEqual(classify(12.49), .warning)
        XCTAssertEqual(classify(12.5), .poor)
        XCTAssertEqual(
            StarAnalysisOverlayGeometry.classifyCell(
                cell(0, 0, count: 2, median: 50), sharpestReliableHfr: 10),
            .neutral)
    }

    func testMeaningfulSpreadThresholdIsInclusive() {
        XCTAssertFalse(StarAnalysisOverlayGeometry.hasMeaningfulReliableSpread([
            cell(0, 0, count: 3, median: 10), cell(0, 2, count: 3, median: 10.29),
        ]))
        XCTAssertTrue(StarAnalysisOverlayGeometry.hasMeaningfulReliableSpread([
            cell(0, 0, count: 3, median: 10), cell(0, 2, count: 3, median: 10.30),
        ]))
    }

    func testOrientationGateIsStrict() {
        func gate(
            normalized: Bool = true, count: Int = 3,
            theta: Double? = 1.0, coherence: Double = 0.9
        ) -> Bool {
            StarAnalysisOverlayGeometry.shouldDrawOrientation(
                normalized: normalized, starCount: count,
                meanTheta: theta, coherence: coherence)
        }
        XCTAssertFalse(gate(normalized: false))
        XCTAssertFalse(gate(count: 2))
        XCTAssertFalse(gate(theta: nil))
        XCTAssertFalse(gate(coherence: 0.25))
        XCTAssertTrue(gate(coherence: 0.251))
    }

    func testCellBoundsMeetExactly() {
        let topLeft = StarAnalysisOverlayGeometry.cellBounds(
            row: 0, col: 0, width: 100, height: 100)
        let center = StarAnalysisOverlayGeometry.cellBounds(
            row: 1, col: 1, width: 100, height: 100)
        XCTAssertEqual(topLeft.maxX, center.minX, accuracy: 1e-12)
        XCTAssertEqual(topLeft.maxX, 100.0 / 3, accuracy: 1e-12)
    }

    func testTiltPerimeterPinnedVertices() throws {
        let equal = try XCTUnwrap(StarAnalysisOverlayGeometry.tiltPerimeter(
            cells: cornerCells(), width: 1000, height: 500))
        XCTAssertEqual(
            equal.vertices.map(\.point),
            [CGPoint(x: 300, y: 50), CGPoint(x: 700, y: 50),
             CGPoint(x: 700, y: 450), CGPoint(x: 300, y: 450)])
        XCTAssertEqual(equal.referenceCornerHfr, 2)
        XCTAssertEqual(equal.centerMeasurement, 2)

        let skewed = try XCTUnwrap(StarAnalysisOverlayGeometry.tiltPerimeter(
            cells: cornerCells(topRight: 4), width: 1000, height: 500))
        XCTAssertEqual(skewed.referenceCornerHfr, 4)
        XCTAssertEqual(skewed.vertices[1].point, CGPoint(x: 700, y: 50))
        XCTAssertEqual(skewed.vertices[0].point, CGPoint(x: 400, y: 150))
    }

    func testTiltPerimeterRequiresFourReliableCorners() {
        var missingMedian = cornerCells()
        missingMedian[0] = cell(0, 0, count: 3, median: nil)
        XCTAssertNil(StarAnalysisOverlayGeometry.tiltPerimeter(
            cells: missingMedian, width: 1000, height: 500))
        var lowSample = cornerCells()
        lowSample[1] = cell(0, 2, count: 2, median: 2)
        XCTAssertNil(StarAnalysisOverlayGeometry.tiltPerimeter(
            cells: lowSample, width: 1000, height: 500))
        // A missing center never gates the diagram.
        let noCenter = StarAnalysisOverlayGeometry.tiltPerimeter(
            cells: cornerCells(center: nil), width: 1000, height: 500)
        XCTAssertNotNil(noCenter)
        XCTAssertNil(noCenter?.centerMeasurement)
    }

    private func triangle(
        medians: [Double] = [2, 2, 2],
        counts: [Int] = [3, 3, 3],
        angle: Double = 0,
        ready: Bool = true,
        centerCount: Int = 3,
        centerMedian: Double? = 2
    ) -> StarAnalysisTriangleTilt {
        let worst = medians.enumerated().max { lhs, rhs in
            if lhs.element != rhs.element { return lhs.element < rhs.element }
            return lhs.offset > rhs.offset
        }
        let best = medians.enumerated().min { lhs, rhs in
            if lhs.element != rhs.element { return lhs.element < rhs.element }
            return lhs.offset < rhs.offset
        }
        return StarAnalysisTriangleTilt(
            angleDegrees: angle,
            innerRadiusPixels: 0.25 * (500.0 * 500 + 250 * 250).squareRoot(),
            outerRadiusPixels: 250,
            minimumStarsPerRegion: 3,
            ready: ready,
            center: StarAnalysisTriangleCenter(
                starCount: centerCount, medianHfr: centerMedian),
            sectors: medians.enumerated().map { index, median in
                StarAnalysisTriangleSector(
                    sector: index + 1,
                    axisAngleDegrees: StarAnalysisContract.normalizeDegrees(
                        angle + Double(index) * 120),
                    starCount: counts[index],
                    medianHfr: counts[index] > 0 ? median : nil)
            },
            overallMedianHfr: 2,
            tiltPercent: ready
                ? 100 * ((worst?.element ?? 0) - (best?.element ?? 0)) / 2
                : nil,
            bestSector: ready ? (best?.offset ?? 0) + 1 : nil,
            worstSector: ready ? (worst?.offset ?? 0) + 1 : nil)
    }

    func testTriangleTiltPinnedVertices() throws {
        let equal = try XCTUnwrap(StarAnalysisOverlayGeometry.triangleTilt(
            triangle(), width: 1000, height: 500))
        XCTAssertEqual(equal.vertices[0].point.x, 500, accuracy: 0.001)
        XCTAssertEqual(equal.vertices[0].point.y, 50, accuracy: 0.001)
        XCTAssertEqual(equal.vertices[1].point.x, 673.2051, accuracy: 0.001)
        XCTAssertEqual(equal.vertices[1].point.y, 350, accuracy: 0.001)
        XCTAssertEqual(equal.vertices[2].point.x, 326.7949, accuracy: 0.001)
        XCTAssertEqual(equal.vertices[2].point.y, 350, accuracy: 0.001)

        let skewed = try XCTUnwrap(StarAnalysisOverlayGeometry.triangleTilt(
            triangle(medians: [2, 4, 2]), width: 1000, height: 500))
        XCTAssertEqual(skewed.referenceWorstHfr, 4)
        XCTAssertEqual(skewed.vertices[0].point.x, 500, accuracy: 0.001)
        XCTAssertEqual(skewed.vertices[0].point.y, 150, accuracy: 0.001)
        XCTAssertEqual(skewed.vertices[1].point.x, 673.2051, accuracy: 0.001)
        XCTAssertEqual(skewed.vertices[1].point.y, 350, accuracy: 0.001)

        let rotated = try XCTUnwrap(StarAnalysisOverlayGeometry.triangleTilt(
            triangle(angle: 90), width: 1000, height: 500))
        XCTAssertEqual(rotated.vertices[0].point.x, 700, accuracy: 0.001)
        XCTAssertEqual(rotated.vertices[0].point.y, 250, accuracy: 0.001)
    }

    func testTriangleTiltGates() {
        XCTAssertNil(StarAnalysisOverlayGeometry.triangleTilt(
            triangle(ready: false), width: 1000, height: 500))
        XCTAssertNil(StarAnalysisOverlayGeometry.triangleTilt(
            triangle(counts: [2, 3, 3], ready: true), width: 1000, height: 500))
        // A sparse center hides its HFR but never gates the diagram.
        let sparseCenter = StarAnalysisOverlayGeometry.triangleTilt(
            triangle(centerCount: 1, centerMedian: 1.5), width: 1000, height: 500)
        XCTAssertNotNil(sparseCenter)
        XCTAssertEqual(sparseCenter?.centerStarCount, 1)
        XCTAssertNil(sparseCenter?.centerHfr)
    }

    func testCenterLabelsKeepTheTwoTiltPercentagesApart() {
        XCTAssertEqual(
            StarAnalysisOverlayView.tiltPerimeterCenterLabel(
                centerMeasurement: 2.5, cornerTiltPercent: 7.1),
            "CENTER HFR 2.50\nCORNER TILT 7.1%")
        XCTAssertEqual(
            StarAnalysisOverlayView.tiltPerimeterCenterLabel(
                centerMeasurement: nil, cornerTiltPercent: nil),
            "HFR TILT")
        let diagram = TriangleTiltDiagram(
            center: .zero, vertices: [], centerStarCount: 3, centerHfr: 2.1,
            referenceWorstHfr: 4, overallMedianHfr: 2.2, tiltPercent: 12.3)
        XCTAssertEqual(
            StarAnalysisOverlayView.triangleTiltCenterLabel(diagram),
            "CENTER HFR 2.10\nMEDIAN HFR 2.20\nSECTOR TILT 12.3%")
    }
}

// MARK: - Service

private final class FakeStarClient: StarAnalysisNativeClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var coreVersionValue = "0.18.7"
    var responder: @Sendable (String) throws -> String
    var onCall: (@Sendable (String) -> Void)?

    init(responder: @escaping @Sendable (String) throws -> String) {
        self.responder = responder
    }

    var coreVersion: String { coreVersionValue }

    var calls: [String] {
        lock.withLock { _calls }
    }

    func detectPath(_ path: String, optionsJSON: String) throws -> String {
        lock.withLock { _calls.append(path) }
        onCall?(path)
        return try responder(path)
    }
}

final class StarAnalysisServiceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("seiza-star-service-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeSource(_ name: String = "frame.fits") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("abc".utf8).write(to: url)
        return url
    }

    private func payload() -> String {
        StarPayload.valid()
    }

    func testCacheKeyIncludesFileIdentityCoreVersionAndOptions() async throws {
        let client = FakeStarClient { _ in StarPayload.valid() }
        let service = StarAnalysisService(client: client)
        let source = try makeSource()
        let options = StarAnalysisOptions.interactiveDefault

        _ = try await service.analyze(path: source.path, options: options)
        _ = try await service.analyze(path: source.path, options: options)
        XCTAssertEqual(client.calls.count, 1, "second identical call is cached")

        client.coreVersionValue = "0.19.0"
        _ = try await service.analyze(path: source.path, options: options)
        XCTAssertEqual(client.calls.count, 2, "core version participates in the key")

        var gaussian = options
        gaussian.psfType = .gaussian
        _ = try await service.analyze(path: source.path, options: gaussian)
        XCTAssertEqual(client.calls.count, 3, "options participate in the key")

        try Data("abcd".utf8).write(to: source)
        _ = try await service.analyze(path: source.path, options: gaussian)
        XCTAssertEqual(client.calls.count, 4, "file identity participates in the key")
    }

    func testCacheEvictsLeastRecentlyUsedAtItsBound() async throws {
        let client = FakeStarClient { _ in StarPayload.valid() }
        let service = StarAnalysisService(client: client, cacheCapacity: 2)
        let first = try makeSource("a.fits")
        let second = try makeSource("b.fits")
        let third = try makeSource("c.fits")
        let options = StarAnalysisOptions.interactiveDefault
        _ = try await service.analyze(path: first.path, options: options)
        _ = try await service.analyze(path: second.path, options: options)
        _ = try await service.analyze(path: third.path, options: options)
        _ = try await service.analyze(path: first.path, options: options)
        XCTAssertEqual(client.calls.count, 4, "A was evicted by C at capacity 2")
    }

    func testUnsupportedAndMissingSourcesAreRejectedBeforeNative() async throws {
        let client = FakeStarClient { _ in StarPayload.valid() }
        let service = StarAnalysisService(client: client)
        let raster = directory.appendingPathComponent("image.png")
        try Data("abc".utf8).write(to: raster)
        do {
            _ = try await service.analyze(path: raster.path)
            XCTFail("raster must be rejected")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Star analysis currently supports FITS and XISF images.")
        }
        do {
            _ = try await service.analyze(
                path: directory.appendingPathComponent("absent.fits").path)
            XCTFail("missing file must be rejected")
        } catch {
            XCTAssertEqual(
                error.localizedDescription, "The image to analyze does not exist.")
        }
        XCTAssertTrue(client.calls.isEmpty)
    }

    func testChangedSourceIsDiscardedInsteadOfBeingCached() async throws {
        let source = try makeSource()
        let client = FakeStarClient { _ in StarPayload.valid() }
        client.onCall = { _ in
            try? Data("mutated".utf8).write(to: source)
        }
        let service = StarAnalysisService(client: client)
        do {
            _ = try await service.analyze(
                path: source.path, options: .interactiveDefault)
            XCTFail("a mutated source must be discarded")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains(
                    "changed while its stars were being analyzed"))
        }
        XCTAssertEqual(client.calls.count, 1)
    }

    func testConcurrentRequestsShareOneNativeOperation() async throws {
        let source = try makeSource()
        let started = expectation(description: "native started")
        let release = DispatchSemaphore(value: 0)
        let client = FakeStarClient { _ in
            release.wait()
            return StarPayload.valid()
        }
        client.onCall = { _ in started.fulfill() }
        let service = StarAnalysisService(client: client)

        async let first = service.analyze(
            path: source.path, options: .interactiveDefault)
        await fulfillment(of: [started], timeout: 10)
        async let second = service.analyze(
            path: source.path, options: .interactiveDefault)
        try await Task.sleep(nanoseconds: 100_000_000)
        release.signal()
        let firstResult = try await first
        let secondResult = try await second
        XCTAssertEqual(firstResult, secondResult)
        XCTAssertEqual(client.calls.count, 1)
    }

    func testCanceledQueuedAnalysisNeverDelaysTheNewerImage() async throws {
        let slow = try makeSource("slow.fits")
        let queued = try makeSource("queued.fits")
        let newer = try makeSource("newer.fits")
        let started = expectation(description: "first native started")
        let release = DispatchSemaphore(value: 0)
        let client = FakeStarClient { path in
            if path.hasSuffix("slow.fits") { release.wait() }
            return StarPayload.valid()
        }
        client.onCall = { path in
            if path.hasSuffix("slow.fits") { started.fulfill() }
        }
        let service = StarAnalysisService(client: client)

        let slowTask = Task {
            try await service.analyze(path: slow.path, options: .interactiveDefault)
        }
        await fulfillment(of: [started], timeout: 10)
        let queuedTask = Task {
            try await service.analyze(path: queued.path, options: .interactiveDefault)
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        queuedTask.cancel()
        _ = try? await queuedTask.value
        let newerTask = Task {
            try await service.analyze(path: newer.path, options: .interactiveDefault)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        release.signal()
        _ = try await slowTask.value
        _ = try await newerTask.value
        let names = client.calls.map { URL(fileURLWithPath: $0).lastPathComponent }
        XCTAssertEqual(names, ["slow.fits", "newer.fits"],
            "the abandoned queued job never reached the native detector")
    }
}

// MARK: - Native end to end

final class StarAnalysisNativeTests: XCTestCase {
    func testSyntheticFieldMeasuresThroughTheRealDetector() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("seiza-star-native-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Broad PSFs (sigma 4 px, HFR well above the detector's floor even
        // after detection binning 2) on a low physical background: the
        // detector's noise estimate tracks the background level, so a
        // realistic camera pedestal keeps bright stars above the
        // interactive sensitivity gate. Stored values carry the standard
        // BZERO 32768 offset, exactly like real capture files.
        let stars: [(Double, Double)] = [
            (80, 66), (286, 112), (528, 140), (172, 198), (414, 234), (92, 280),
            (330, 306), (572, 352), (218, 384), (468, 416), (124, 452), (366, 474),
        ]
        var values = [Int16](repeating: 0, count: 640 * 512)
        for index in values.indices {
            let x = Double(index % 640)
            let y = Double(index / 640)
            var signal = 500.0 + Double((index * 37) % 23) - 11
            for (sx, sy) in stars {
                let dx = x - sx
                let dy = y - sy
                guard abs(dx) < 30, abs(dy) < 30 else { continue }
                signal += 15000 * exp(-(dx * dx + dy * dy) / 32.0)
            }
            values[index] = Int16(
                max(-32768, min(32767, (signal - 32768).rounded())))
        }
        let url = try SyntheticFrame.write(
            width: 640, height: 512,
            values: values,
            cards: SyntheticFrame.lightCards(),
            directory: directory,
            name: "field.fits")

        let result = try await StarAnalysisService.shared.analyze(
            path: url.path, options: .interactiveDefault)
        XCTAssertEqual(result.width, 640)
        XCTAssertEqual(result.height, 512)
        XCTAssertEqual(result.cells.count, 9)
        XCTAssertEqual(result.stars.count, 12, "every synthetic star is found")
        XCTAssertTrue(result.majorAxisOrientationsNormalized)
        XCTAssertNotNil(result.triangleTilt, "requested triangle must be present")
        XCTAssertEqual(result.triangleTilt?.angleDegrees, 0)

        // The overlay model builds without tripping any geometry gate.
        let model = StarAnalysisOverlayModel(result: result)
        XCTAssertEqual(model.cellGrid.count, 9)
        XCTAssertFalse(model.selectedStarIndices.isEmpty)
    }
}
