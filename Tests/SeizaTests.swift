import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Seiza

final class SeizaBuildInfoTests: XCTestCase {
    func testAboutDetailsReportTheLockedUpstreamCore() throws {
        let commit = SeizaCore.gitCommit
        XCTAssertNotEqual(SeizaCore.version, "unknown")
        XCTAssertEqual(commit.count, 40)
        XCTAssertTrue(commit.allSatisfy(\.isHexDigit))

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let lock = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Cargo.lock"),
            encoding: .utf8
        )
        XCTAssertTrue(lock.contains("name = \"seiza-cabi\""))
        XCTAssertTrue(lock.contains("#\(commit)"))
        XCTAssertEqual(
            AboutDetails.seizaCoreDescription,
            "Seiza Core \(SeizaCore.version)\nCommit \(commit)"
        )
    }
}

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

final class DocumentRegistrationTests: XCTestCase {
    func testFITSRegistrationUsesDedicatedDocumentIcon() throws {
        let documentTypes = try XCTUnwrap(
            Bundle.main.infoDictionary?["CFBundleDocumentTypes"]
                as? [[String: Any]]
        )
        let fitsType = try XCTUnwrap(documentTypes.first { declaration in
            let contentTypes = declaration["LSItemContentTypes"] as? [String]
            return contentTypes?.contains("fyi.seiza.fits") == true
        })
        let imageType = try XCTUnwrap(documentTypes.first { declaration in
            let contentTypes = declaration["LSItemContentTypes"] as? [String]
            return contentTypes?.contains("public.jpeg") == true
        })

        XCTAssertEqual(fitsType["CFBundleTypeIconFile"] as? String, "FITSFile")
        XCTAssertNil(imageType["CFBundleTypeIconFile"])
        XCTAssertNotNil(Bundle.main.url(forResource: "FITSFile", withExtension: "icns"))
    }

    func testQuickLookExtensionDeclaresFinderFITSPreviewSupport() throws {
        let plugInsURL = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let extensionURL = plugInsURL.appendingPathComponent("SeizaQuickLook.appex")
        let extensionBundle = try XCTUnwrap(Bundle(url: extensionURL))
        let extensionInfo = try XCTUnwrap(
            extensionBundle.infoDictionary?["NSExtension"] as? [String: Any]
        )
        let attributes = try XCTUnwrap(
            extensionInfo["NSExtensionAttributes"] as? [String: Any]
        )

        XCTAssertEqual(
            extensionInfo["NSExtensionPointIdentifier"] as? String,
            "com.apple.quicklook.preview"
        )
        XCTAssertEqual(attributes["QLIsDataBasedPreview"] as? Bool, false)
        XCTAssertEqual(attributes["QLSupportsSearchableItems"] as? Bool, false)
        XCTAssertEqual(
            attributes["QLSupportedContentTypes"] as? [String],
            ["fyi.seiza.fits"]
        )
        XCTAssertEqual(
            extensionInfo["NSExtensionPrincipalClass"] as? String,
            "SeizaQuickLook.PreviewViewController"
        )
    }
}

final class DisplayHistogramTests: XCTestCase {
    func testHistogramRequiresCompleteEightBitChannels() {
        let valid = [UInt64](repeating: 1, count: ImageHistogram.binCount)
        XCTAssertTrue(
            ImageHistogram(
                red: valid,
                green: valid,
                blue: valid,
                lowerBound: 0,
                upperBound: 255
            ).isValid
        )
        XCTAssertFalse(
            ImageHistogram(
                red: Array(valid.dropLast()),
                green: valid,
                blue: valid,
                lowerBound: 0,
                upperBound: 255
            ).isValid
        )
    }
}

final class ImageExportTests: XCTestCase {
    func testWritesPNGJPEGAndTIFFAtSourceDimensions() throws {
        let image = try makeTestImage()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for format in ImageExportFormat.allCases {
            let url = directory.appendingPathComponent("export.\(format.fileExtension)")
            try ImageFileWriter.write(image, to: url, format: format)

            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, format.contentType.identifier)
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(decoded.width, 2)
            XCTAssertEqual(decoded.height, 2)
        }
    }

    private func makeTestImage() throws -> CGImage {
        let pixels: [UInt8] = [
            255, 0, 0, 255,
            0, 255, 0, 255,
            0, 0, 255, 255,
            255, 255, 255, 255,
        ]
        let provider = try XCTUnwrap(
            CGDataProvider(data: Data(pixels) as CFData)
        )
        return try XCTUnwrap(
            CGImage(
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: 8,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        )
    }
}

final class RenderBoundaryTests: XCTestCase {
    func testSyntheticFITSRendersThroughSwiftBoundaryWithHistogram() throws {
        var fits = Data()
        for value in [
            "SIMPLE  =                    T",
            "BITPIX  =                   16",
            "NAXIS   =                    2",
            "NAXIS1  =                    2",
            "NAXIS2  =                    2",
            "BZERO   =                32768",
            "END",
        ] {
            let card = value.padding(toLength: 80, withPad: " ", startingAt: 0)
            fits.append(try XCTUnwrap(card.data(using: .ascii)))
        }
        fits.append(Data(repeating: 0x20, count: 2_880 - fits.count))
        for value in [Int16(0), 100, 1_000, 20_000] {
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) { fits.append(contentsOf: $0) }
        }
        fits.append(Data(repeating: 0, count: 5_760 - fits.count))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).fits")
        try fits.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let rendered = try SeizaCore.render(url: url, maxDimension: 4_096)
        XCTAssertEqual(rendered.image.width, 2)
        XCTAssertEqual(rendered.image.height, 2)
        let histogram = try XCTUnwrap(rendered.metadata.displayHistogram)
        XCTAssertTrue(histogram.isValid)
        XCTAssertEqual(histogram.red.reduce(0, +), 4)
        XCTAssertEqual(histogram.green.reduce(0, +), 4)
        XCTAssertEqual(histogram.blue.reduce(0, +), 4)
        let inputHistogram = try XCTUnwrap(rendered.metadata.inputHistogram)
        XCTAssertTrue(inputHistogram.isValid)
        XCTAssertEqual(inputHistogram.upperBound, 65_535)
        XCTAssertEqual(inputHistogram.red.reduce(0, +), 4)
    }
}

final class RGBStretchModeTests: XCTestCase {
    func testCABIValuesAndUserFacingNamesStayStable() {
        XCTAssertEqual(RGBStretchMode.allCases, [.auto, .linkedAuto, .linear])
        XCTAssertEqual(RGBStretchMode.auto.rawValue, 0)
        XCTAssertEqual(RGBStretchMode.linkedAuto.rawValue, 1)
        XCTAssertEqual(RGBStretchMode.linear.rawValue, 2)
        XCTAssertEqual(RGBStretchMode.auto.title, "Auto")
        XCTAssertEqual(RGBStretchMode.linkedAuto.title, "Linked Auto")
        XCTAssertEqual(RGBStretchMode.linear.title, "Linear")
    }
}

final class OverlayCatalogTests: XCTestCase {
    func testServerCatalogClassificationsRemainStable() {
        let expected: [(String, DeepSkyCatalog)] = [
            ("M 31", .messier),
            ("NGC 7000", .ngc),
            ("IC 434", .ic),
            ("Sh 2-240", .sharplessVDB),
            ("vdB 142", .sharplessVDB),
            ("LBN 331", .lbn),
            ("Ced 214", .cederblad),
            ("LDN 1622", .darkNebulae),
            ("B 33", .darkNebulae),
            ("SNR G184.6-05.8", .supernovaRemnants),
            ("UGC 2885", .ugc),
            ("PGC 2557", .pgc),
            ("Abell 1656", .other),
        ]
        for (name, catalog) in expected {
            XCTAssertEqual(DeepSkyCatalog.classify(name: name, kind: "nebula"), catalog)
        }
        XCTAssertNil(DeepSkyCatalog.classify(name: "Sirius", kind: "star"))
        XCTAssertNil(DeepSkyCatalog.classify(name: "SN 2025abc", kind: "transient"))
        XCTAssertEqual(
            DeepSkyCatalog.allCases.map(\.rawValue),
            [
                "messier", "ngc", "ic", "sharpless-vdb", "lbn", "cederblad",
                "dark-nebulae", "snr", "ugc", "pgc", "other-deep-sky",
            ]
        )
    }
}

final class CatalogSetupPayloadTests: XCTestCase {
    func testCatalogStatusDecodesSolverAndOverlayReadiness() throws {
        let data = Data(
            #"""
            {
              "directory": "/tmp/seiza-catalogs",
              "readyForSolving": true,
              "readyForOverlays": false,
              "starCatalog": {"available": true, "path": "/tmp/seiza-catalogs/stars-deep-gaia17.bin"},
              "blindIndex": {"available": true, "path": "/tmp/seiza-catalogs/blind-gaia16.idx"},
              "objects": {"available": true, "path": "/tmp/seiza-catalogs/objects.bin"},
              "transients": {"available": false, "path": null},
              "minorBodies": {"available": true, "path": "/tmp/seiza-catalogs/minor-bodies.bin"}
            }
            """#.utf8
        )

        let status = try JSONDecoder().decode(CatalogStatus.self, from: data)
        XCTAssertTrue(status.readyForSolving)
        XCTAssertFalse(status.readyForOverlays)
        XCTAssertTrue(status.starCatalog.available)
        XCTAssertFalse(status.transients.available)
    }

    func testVerificationProgressRemainsDeterminateAfterDownload() throws {
        let data = Data(
            #"""
            {
              "phase": "verifying",
              "message": "Verifying and installing stars-deep-gaia17.bin",
              "fileName": "stars-deep-gaia17.bin",
              "filesCompleted": 3,
              "filesTotal": 5,
              "bytesCompleted": 536870912,
              "bytesTotal": 1073741824,
              "writtenBytes": 536870912
            }
            """#.utf8
        )

        let progress = try JSONDecoder().decode(CatalogSetupProgress.self, from: data)
        XCTAssertEqual(progress.phase, .verifying)
        XCTAssertEqual(progress.fractionCompleted, 0.5)
        XCTAssertEqual(progress.filesCompleted, 3)
        XCTAssertEqual(progress.filesTotal, 5)
    }

    func testCatalogSetupPresetABIValuesStayStable() {
        XCTAssertEqual(CatalogSetupPreset.allCases, [.standardBlind, .deepestBlind, .all])
        XCTAssertEqual(CatalogSetupPreset.standardBlind.rawValue, 0)
        XCTAssertEqual(CatalogSetupPreset.deepestBlind.rawValue, 1)
        XCTAssertEqual(CatalogSetupPreset.all.rawValue, 2)
        XCTAssertTrue(CatalogSetupPreset.standardBlind.detail.contains("Recommended"))
    }
}

@MainActor
final class DocumentWindowLifecycleTests: XCTestCase {
    func testDroppedImageReusesWindowAndRekeysDocumentSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("first.png")
        let second = directory.appendingPathComponent("second.jpg")
        XCTAssertTrue(FileManager.default.createFile(atPath: first.path, contents: Data()))
        XCTAssertTrue(FileManager.default.createFile(atPath: second.path, contents: Data()))

        let delegate = AppDelegate()
        delegate.open(first)
        let window = try XCTUnwrap(delegate.documentWindow(for: first))
        defer { if window.isVisible { window.close() } }
        XCTAssertEqual(window.title, "first.png")

        delegate.replaceContents(of: window, with: [second])

        XCTAssertNil(delegate.documentWindow(for: first))
        XCTAssertTrue(delegate.documentWindow(for: second) === window)
        XCTAssertEqual(window.title, "second.jpg")

        window.close()
        XCTAssertNil(delegate.documentWindow(for: second))
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
                "stableId": "openngc:NGC1",
                "name": "NGC 1",
                "commonName": "Test Nebula",
                "kind": "nebula",
                "source": "deep_sky",
                "catalogSource": "OpenNGC",
                "x": 10.0,
                "y": 20.0,
                "semiMajorPixels": 30.0,
                "semiMinorPixels": 15.0,
                "angleDegrees": null,
                "prominence": 0.9,
                "raDegrees": 10.0,
                "decDegrees": 20.0,
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
              "captureTime": "2025-07-20T12:34:56Z",
              "overlayAvailability": {"deep_sky": true, "named_stars": true, "transients": true, "minor_bodies": true, "grid": true},
              "overlayUnavailableReasons": {},
              "overlayCounts": {"deep_sky": 1, "named_stars": 0, "transients": 0, "minor_bodies": 0},
              "wcs": {"crval": [10.0, 20.0], "crpix": [100.0, 100.0], "cd": [[-0.001, 0.0], [0.0, -0.001]], "sip": null}
            }
            """#.utf8
        )

        let result = try JSONDecoder().decode(SolveResult.self, from: data)
        XCTAssertEqual(result.matchedStars, 42)
        XCTAssertEqual(result.objectPositions[0].displayName, "NGC 1 · Test Nebula")
        XCTAssertEqual(result.objectPositions[0].deepSkyCatalog, .ngc)
        XCTAssertEqual(result.objectPositions[0].catalogSource, "OpenNGC")
        XCTAssertEqual(result.objectPositions[0].outlines[0].role, "brightness-level")
        XCTAssertEqual(result.objectPositions[0].outlines[0].contours[0].points[2], [13.0, 24.0])
        XCTAssertEqual(result.captureTime, "2025-07-20T12:34:56Z")
        XCTAssertEqual(result.overlayAvailability?["minor_bodies"], true)
        XCTAssertEqual(result.overlayCounts?["deep_sky"], 1)
    }
}
