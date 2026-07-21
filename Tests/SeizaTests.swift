import Foundation
import XCTest
@testable import Seiza

final class ImageCollectionTests: XCTestCase {
    func testMixedDirectoryFiltersAndNaturallySortsSupportedImages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for name in ["frame10.fits", "frame2.FIT", "preview.jpg", "notes.txt", ".hidden.png"] {
            XCTAssertTrue(FileManager.default.createFile(
                atPath: directory.appendingPathComponent(name).path,
                contents: Data()
            ))
        }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("nested.png", isDirectory: true),
            withIntermediateDirectories: true
        )

        let names = ImageCollection.collect(from: [directory]).map(\.lastPathComponent)
        XCTAssertEqual(names, ["frame2.FIT", "frame10.fits", "preview.jpg"])
    }

    func testSupportedExtensionMatchingIsCaseInsensitive() {
        XCTAssertTrue(ImageCollection.isSupportedImage(URL(fileURLWithPath: "/tmp/a.FTS")))
        XCTAssertTrue(ImageCollection.isSupportedImage(URL(fileURLWithPath: "/tmp/a.TIFF")))
        XCTAssertFalse(ImageCollection.isSupportedImage(URL(fileURLWithPath: "/tmp/a.svg")))
    }
}

final class SolvePayloadTests: XCTestCase {
    func testDecodesProjectedOpenNGCOutlinePayload() throws {
        let data = Data(
            #"""
            {
              "centerRaDegrees": 10.0,
              "centerDecDegrees": 20.0,
              "scaleArcsecPerPixel": 1.5,
              "matchedStars": 42,
              "rmsArcsec": 0.7,
              "detectedStars": 50,
              "elapsedMilliseconds": 120,
              "detectedStarPositions": [{"x": 1.0, "y": 2.0}],
              "catalogStarPositions": [{"x": 3.0, "y": 4.0, "magnitude": 5.0}],
              "objectPositions": [{
                "name": "NGC 1",
                "commonName": "Test Nebula",
                "kind": "nebula",
                "source": "OpenNGC",
                "x": 10.0,
                "y": 20.0,
                "semiMajorPixels": 30.0,
                "semiMinorPixels": 15.0,
                "angleDegrees": null,
                "prominence": 0.9,
                "outlines": [{
                  "geometryId": "openngc:NGC1#outline-1",
                  "sourceRecordId": "openngc:NGC1",
                  "role": "brightness-level",
                  "quality": "catalog",
                  "level": "1",
                  "contours": [{"closed": true, "points": [[11.0, 22.0], [12.0, 23.0], [13.0, 24.0]]}]
                }]
              }],
              "objectCatalogError": null,
              "wcs": {"crval": [10.0, 20.0], "crpix": [100.0, 100.0], "cd": [[-0.001, 0.0], [0.0, -0.001]], "sip": null}
            }
            """#.utf8
        )

        let result = try JSONDecoder().decode(SolveResult.self, from: data)
        XCTAssertEqual(result.matchedStars, 42)
        XCTAssertEqual(result.objectPositions[0].displayName, "NGC 1 · Test Nebula")
        XCTAssertEqual(result.objectPositions[0].outlines[0].role, "brightness-level")
        XCTAssertEqual(result.objectPositions[0].outlines[0].contours[0].points[2], [13.0, 24.0])
    }
}
