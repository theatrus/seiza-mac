import AppKit
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

        for name in [
            "frame10.fits", "frame2.FIT", "integration.XISF", "preview.jpg",
            "notes.txt", ".hidden.png",
        ] {
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
        XCTAssertEqual(
            names,
            ["frame2.FIT", "frame10.fits", "integration.XISF", "preview.jpg"]
        )
    }

    func testSupportedExtensionMatchingIsCaseInsensitive() {
        XCTAssertTrue(ImageCollection.isSupportedImage(URL(fileURLWithPath: "/tmp/a.FTS")))
        XCTAssertTrue(ImageCollection.isSupportedImage(URL(fileURLWithPath: "/tmp/a.XISF")))
        XCTAssertTrue(ImageCollection.isSupportedImage(URL(fileURLWithPath: "/tmp/a.TIFF")))
        XCTAssertFalse(ImageCollection.isSupportedImage(URL(fileURLWithPath: "/tmp/a.svg")))
    }
}

final class DocumentRegistrationTests: XCTestCase {
    func testAstronomyRegistrationsUseDedicatedDocumentIcon() throws {
        let documentTypes = try XCTUnwrap(
            Bundle.main.infoDictionary?["CFBundleDocumentTypes"]
                as? [[String: Any]]
        )
        let fitsType = try XCTUnwrap(documentTypes.first { declaration in
            let contentTypes = declaration["LSItemContentTypes"] as? [String]
            return contentTypes?.contains("fyi.seiza.fits") == true
        })
        let xisfType = try XCTUnwrap(documentTypes.first { declaration in
            let contentTypes = declaration["LSItemContentTypes"] as? [String]
            return contentTypes?.contains("fyi.seiza.xisf") == true
        })
        let imageType = try XCTUnwrap(documentTypes.first { declaration in
            let contentTypes = declaration["LSItemContentTypes"] as? [String]
            return contentTypes?.contains("public.jpeg") == true
        })

        XCTAssertEqual(fitsType["CFBundleTypeIconFile"] as? String, "FITSFile")
        XCTAssertEqual(xisfType["CFBundleTypeIconFile"] as? String, "FITSFile")
        XCTAssertNil(imageType["CFBundleTypeIconFile"])
        XCTAssertNotNil(Bundle.main.url(forResource: "FITSFile", withExtension: "icns"))
    }

    func testQuickLookExtensionDeclaresFinderAstronomyPreviewSupport() throws {
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
            ["fyi.seiza.fits", "fyi.seiza.xisf"]
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

    func testPlotScaleUsesPopulatedInteriorBinsInsteadOfClippedEndpoints() {
        var bins = [UInt64](repeating: 0, count: ImageHistogram.binCount)
        bins[0] = 1_000_000
        for index in 1...100 {
            bins[index] = UInt64(index)
        }

        let ceiling = HistogramPlotScale.ceiling(for: [bins])

        XCTAssertGreaterThanOrEqual(ceiling, 90)
        XCTAssertLessThanOrEqual(ceiling, 100)
        XCTAssertEqual(
            HistogramPlotScale.normalizedHeight(
                count: UInt64(ceiling / 2),
                ceiling: ceiling
            ),
            0.5,
            accuracy: 0.02
        )
        XCTAssertEqual(
            HistogramPlotScale.normalizedHeight(
                count: 1_000_000,
                ceiling: ceiling
            ),
            1
        )
    }

    func testPlotScaleFallsBackToEndpointBinsForFullyClippedImages() {
        var bins = [UInt64](repeating: 0, count: ImageHistogram.binCount)
        bins[255] = 42

        XCTAssertEqual(HistogramPlotScale.ceiling(for: [bins]), 42)
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

    func testWritesSixteenBitPNGAndTIFFWithoutDownconversion() throws {
        let image = try makeTestImage16()
        let overlay = try makeTestImage()
        let composited = try ImageFileWriter.compositing(overlay, over: image)
        XCTAssertEqual(composited.bitsPerComponent, 16)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for (name, candidate) in [("plain", image), ("overlays", composited)] {
            for format in [ImageExportFormat.png, .tiff] {
                let url = directory.appendingPathComponent(
                    "\(name)-16.\(format.fileExtension)"
                )
                try ImageFileWriter.write(candidate, to: url, format: format)

                let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
                let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                XCTAssertEqual(decoded.bitsPerComponent, 16, "\(name) \(format.title)")
                XCTAssertEqual(decoded.width, 2)
                XCTAssertEqual(decoded.height, 2)
            }
        }
    }

    func testCopiesFullResolutionImageToMacPasteboard() throws {
        let image = try makeTestImage()
        let pasteboard = NSPasteboard(name: .init("fyi.seiza.tests.\(UUID().uuidString)"))

        try ImageClipboard.copy(image, to: pasteboard)

        let png = try XCTUnwrap(pasteboard.data(forType: .png))
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, image.width)
        XCTAssertEqual(decoded.height, image.height)
    }

    func testJPEGOnlyOffersEightBitExport() {
        XCTAssertEqual(ImageExportFormat.jpeg.supportedBitDepths, [.eight])
        XCTAssertEqual(ImageExportFormat.png.supportedBitDepths, [.sixteen, .eight])
        XCTAssertEqual(ImageExportFormat.tiff.supportedBitDepths, [.sixteen, .eight])
    }

    @MainActor
    func testChangingToJPEGForcesEightBitExport() {
        let options = ImageExportOptions(overlaysAvailable: false)
        XCTAssertEqual(options.bitDepth, .sixteen)
        options.format = .jpeg
        XCTAssertEqual(options.bitDepth, .eight)
    }

    func testPixelSamplerReturnsDisplayedLuminance() throws {
        let image = try makeTestImage()
        XCTAssertEqual(
            try XCTUnwrap(ImagePixelSampler.normalizedLuminance(
                image: image,
                x: 0,
                y: 0,
                radius: 0
            )),
            0.2126,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            try XCTUnwrap(ImagePixelSampler.normalizedLuminance(
                image: image,
                x: 1,
                y: 1,
                radius: 0
            )),
            1,
            accuracy: 0.0001
        )
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

    private func makeTestImage16() throws -> CGImage {
        let samples: [UInt16] = [
            1, 256, 32_768, 65_535,
            257, 16_384, 50_000, 65_535,
            2, 30_000, 60_000, 65_535,
            123, 32_767, 65_534, 65_535,
        ]
        let data = samples.withUnsafeBytes { Data($0) }
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        var bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        #if _endian(little)
        bitmapInfo.insert(.byteOrder16Little)
        #else
        bitmapInfo.insert(.byteOrder16Big)
        #endif
        return try XCTUnwrap(
            CGImage(
                width: 2,
                height: 2,
                bitsPerComponent: 16,
                bitsPerPixel: 64,
                bytesPerRow: 16,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: bitmapInfo,
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
        XCTAssertEqual(rendered.image.bitsPerComponent, 8)
        let histogram = try XCTUnwrap(rendered.metadata.displayHistogram)
        XCTAssertTrue(histogram.isValid)
        XCTAssertEqual(histogram.red.reduce(0, +), 4)
        XCTAssertEqual(histogram.green.reduce(0, +), 4)
        XCTAssertEqual(histogram.blue.reduce(0, +), 4)
        let inputHistogram = try XCTUnwrap(rendered.metadata.inputHistogram)
        XCTAssertTrue(inputHistogram.isValid)
        XCTAssertEqual(inputHistogram.upperBound, 65_535)
        XCTAssertEqual(inputHistogram.red.reduce(0, +), 4)
        XCTAssertEqual(rendered.metadata.stretchStages, 1)

        let rendered16 = try SeizaCore.render16(url: url, maxDimension: 4_096)
        XCTAssertEqual(rendered16.image.width, 2)
        XCTAssertEqual(rendered16.image.height, 2)
        XCTAssertEqual(rendered16.image.bitsPerComponent, 16)
        XCTAssertEqual(rendered16.image.bitsPerPixel, 64)
        XCTAssertEqual(rendered16.metadata.displayHistogram?.upperBound, 65_535)
        let rgba16Data = try XCTUnwrap(rendered16.image.dataProvider?.data as Data?)
        let rgba16Samples = rgba16Data.withUnsafeBytes {
            Array($0.bindMemory(to: UInt16.self))
        }
        XCTAssertTrue(
            rgba16Samples.enumerated().contains { index, sample in
                index % 4 != 3 && sample % 257 != 0
            },
            "The Swift boundary must preserve values finer than replicated RGBA8"
        )

        for stretchType in FITSStretchType.allCases {
            var configuration = FITSStretchConfiguration.default
            configuration.type = stretchType
            let variant = try SeizaCore.render(
                url: url,
                maxDimension: 4_096,
                processing: FITSImageProcessingConfiguration(
                    stretchStack: FITSStretchStack(stages: [configuration]),
                    extractsBackground: false
                )
            )
            XCTAssertEqual(variant.image.width, 2, stretchType.title)
            XCTAssertEqual(variant.image.height, 2, stretchType.title)
        }

        var linear = FITSStretchConfiguration.default
        linear.type = .linear
        linear.black = 0.02
        linear.white = 0.9
        let stacked = try SeizaCore.render(
            url: url,
            maxDimension: 4_096,
            processing: FITSImageProcessingConfiguration(
                stretchStack: FITSStretchStack(stages: [.default, linear]),
                extractsBackground: false
            )
        )
        XCTAssertEqual(stacked.metadata.stretchStages, 2)
    }

    @MainActor
    func testSyntheticXISFUsesTheFullAstronomyPipelineThroughSwiftBoundary() async throws {
        let url = try writeSyntheticXISF(
            width: 2,
            height: 2,
            values: [0.001, 0.25, 0.5, 1.0]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let processing = FITSImageProcessingConfiguration(
            stretchStack: FITSStretchStack(stages: [.identity]),
            extractsBackground: false
        )
        let rendered = try SeizaCore.render(
            url: url,
            maxDimension: 4_096,
            processing: processing
        )
        XCTAssertEqual(rendered.image.width, 2)
        XCTAssertEqual(rendered.image.height, 2)
        XCTAssertEqual(rendered.metadata.format, "XISF")
        XCTAssertEqual(rendered.metadata.headers["OBJECT"]?.description, "M42")
        XCTAssertEqual(rendered.metadata.stretchStages, 1)
        XCTAssertTrue(try XCTUnwrap(rendered.metadata.inputHistogram).isValid)

        let rendered16 = try SeizaCore.render16(
            url: url,
            maxDimension: 4_096,
            processing: processing
        )
        XCTAssertEqual(rendered16.image.bitsPerComponent, 16)
        XCTAssertEqual(rendered16.image.bitsPerPixel, 64)
        XCTAssertEqual(rendered16.metadata.format, "XISF")
        let rgba16Data = try XCTUnwrap(rendered16.image.dataProvider?.data as Data?)
        let rgba16Samples = rgba16Data.withUnsafeBytes {
            Array($0.bindMemory(to: UInt16.self))
        }
        XCTAssertTrue(
            rgba16Samples.enumerated().contains { index, sample in
                index % 4 != 3 && sample % 257 != 0
            },
            "XISF export must preserve values finer than replicated RGBA8"
        )

        let model = ImageDocumentModel(url: url, processingConfiguration: processing)
        try await waitUntil("initial XISF render") {
            if case .loaded = model.loadState { true } else { false }
        }
        XCTAssertTrue(model.supportsAstronomyProcessing)
    }

    func testBackgroundExtractionRunsBeforeStretchingThroughSwiftBoundary() throws {
        let width = 96
        let height = 72
        var values = [Int16]()
        values.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                values.append(Int16(2_000 + x * 120 + y * 45))
            }
        }
        let url = try writeSyntheticFITS(width: width, height: height, values: values)
        defer { try? FileManager.default.removeItem(at: url) }

        let stack = FITSStretchStack(stages: [.identity])
        let plain = try SeizaCore.render(
            url: url,
            processing: FITSImageProcessingConfiguration(
                stretchStack: stack,
                extractsBackground: false
            )
        )
        let corrected = try SeizaCore.render(
            url: url,
            processing: FITSImageProcessingConfiguration(
                stretchStack: stack,
                extractsBackground: true
            )
        )

        XCTAssertEqual(corrected.image.width, width)
        XCTAssertEqual(corrected.image.height, height)
        XCTAssertEqual(corrected.metadata.inputHistogram?.upperBound, 1)
        XCTAssertNotEqual(
            plain.image.dataProvider?.data as Data?,
            corrected.image.dataProvider?.data as Data?
        )
    }

    func testDeconvolutionRunsOnLinearPixelsBeforeStretchingThroughSwiftBoundary() throws {
        let size = 41
        let center = size / 2
        var values = [Int16](repeating: 500, count: size * size)
        values[center * size + center] = 20_000
        values[center * size + center - 1] = 10_000
        values[center * size + center + 1] = 10_000
        values[(center - 1) * size + center] = 10_000
        values[(center + 1) * size + center] = 10_000
        let url = try writeSyntheticFITS(width: size, height: size, values: values)
        defer { try? FileManager.default.removeItem(at: url) }

        let stack = FITSStretchStack(stages: [.identity])
        let plain = try SeizaCore.render(
            url: url,
            processing: FITSImageProcessingConfiguration(
                stretchStack: stack,
                extractsBackground: false
            )
        )
        let restored = try SeizaCore.render(
            url: url,
            processing: FITSImageProcessingConfiguration(
                stretchStack: stack,
                extractsBackground: false,
                deconvolution: .default
            )
        )

        XCTAssertEqual(restored.image.width, size)
        XCTAssertEqual(restored.image.height, size)
        XCTAssertNotEqual(
            plain.image.dataProvider?.data as Data?,
            restored.image.dataProvider?.data as Data?
        )
    }

    func testInteractivePreviewCacheReappliesEveryStretchEdit() throws {
        let width = 96
        let height = 72
        var values = [Int16]()
        values.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                values.append(Int16(2_000 + x * 120 + y * 45))
            }
        }
        let url = try writeSyntheticFITS(width: width, height: height, values: values)
        defer { try? FileManager.default.removeItem(at: url) }

        var firstStretch = FITSStretchConfiguration.default
        firstStretch.targetMedian = 0.21
        let first = try SeizaCore.render(
            url: url,
            maxDimension: 2_048,
            processing: FITSImageProcessingConfiguration(
                stretchStack: FITSStretchStack(stages: [firstStretch]),
                extractsBackground: false,
                interactivePreview: true
            )
        )

        var secondStretch = firstStretch
        secondStretch.targetMedian = 0.27
        let second = try SeizaCore.render(
            url: url,
            maxDimension: 2_048,
            processing: FITSImageProcessingConfiguration(
                stretchStack: FITSStretchStack(stages: [secondStretch]),
                extractsBackground: false,
                interactivePreview: true
            )
        )

        XCTAssertNotEqual(
            first.image.dataProvider?.data as Data?,
            second.image.dataProvider?.data as Data?
        )
    }

    func testInteractivePreviewReappliesEveryDeconvolutionEdit() throws {
        let size = 81
        let center = size / 2
        var values = [Int16](repeating: 500, count: size * size)
        values[center * size + center] = 20_000
        for offset in [-2, -1, 1, 2] {
            values[center * size + center + offset] = 8_000
            values[(center + offset) * size + center] = 8_000
        }
        let url = try writeSyntheticFITS(width: size, height: size, values: values)
        defer { try? FileManager.default.removeItem(at: url) }

        var firstDeconvolution = FITSDeconvolutionConfiguration.default
        firstDeconvolution.psfFWHMPixels = 2.0
        let first = try SeizaCore.render(
            url: url,
            maxDimension: 2_048,
            processing: FITSImageProcessingConfiguration(
                stretchStack: FITSStretchStack(stages: [.identity]),
                extractsBackground: false,
                deconvolution: firstDeconvolution,
                interactivePreview: true
            )
        )

        var secondDeconvolution = firstDeconvolution
        secondDeconvolution.psfFWHMPixels = 4.0
        let second = try SeizaCore.render(
            url: url,
            maxDimension: 2_048,
            processing: FITSImageProcessingConfiguration(
                stretchStack: FITSStretchStack(stages: [.identity]),
                extractsBackground: false,
                deconvolution: secondDeconvolution,
                interactivePreview: true
            )
        )

        XCTAssertNotEqual(
            first.image.dataProvider?.data as Data?,
            second.image.dataProvider?.data as Data?
        )
    }

    @MainActor
    func testLatestProgressivePreviewWinsAfterRapidEditsAndCommitsWithoutReload() async throws {
        let width = 96
        let height = 72
        var values = [Int16]()
        values.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                values.append(Int16(2_000 + x * 120 + y * 45))
            }
        }
        let url = try writeSyntheticFITS(width: width, height: height, values: values)
        defer { try? FileManager.default.removeItem(at: url) }

        let model = ImageDocumentModel(url: url)
        try await waitUntil("initial FITS render") {
            if case .loaded = model.loadState { true } else { false }
        }

        var latestStretch = FITSStretchConfiguration.default
        latestStretch.targetMedian = 0.27
        let expected = try SeizaCore.render(
            url: url,
            processing: FITSImageProcessingConfiguration(
                stretchStack: FITSStretchStack(stages: [latestStretch]),
                extractsBackground: false
            )
        )

        for targetMedian in [0.21, 0.23, 0.27] {
            var stretch = FITSStretchConfiguration.default
            stretch.targetMedian = targetMedian
            model.preview(
                stretchStack: FITSStretchStack(stages: [stretch]),
                extractsBackground: false
            )
        }

        let expectedPixels = expected.image.dataProvider?.data as Data?
        try await waitUntil("latest interactive preview") {
            !model.isPreviewRendering
                && model.image?.dataProvider?.data as Data? == expectedPixels
        }
        XCTAssertEqual(
            model.fullResolutionDisplayImage?.dataProvider?.data as Data?,
            expectedPixels
        )

        model.replaceStretchStack(
            with: FITSStretchStack(stages: [latestStretch]),
            extractsBackground: false
        )

        if case .loaded = model.loadState {
            XCTAssertEqual(model.exportImage?.dataProvider?.data as Data?, expectedPixels)
        } else {
            XCTFail("Saving a refined preview should not start another render")
        }
    }

    @MainActor
    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(5),
        condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for \(description)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func writeSyntheticFITS(
        width: Int,
        height: Int,
        values: [Int16]
    ) throws -> URL {
        XCTAssertEqual(values.count, width * height)
        var fits = Data()
        for value in [
            "SIMPLE  =                    T",
            "BITPIX  =                   16",
            "NAXIS   =                    2",
            String(format: "NAXIS1  = %20d", width),
            String(format: "NAXIS2  = %20d", height),
            "BZERO   =                32768",
            "END",
        ] {
            let card = value.padding(toLength: 80, withPad: " ", startingAt: 0)
            fits.append(try XCTUnwrap(card.data(using: .ascii)))
        }
        fits.append(Data(repeating: 0x20, count: 2_880 - fits.count))
        for value in values {
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) { fits.append(contentsOf: $0) }
        }
        let paddedLength = ((fits.count + 2_879) / 2_880) * 2_880
        fits.append(Data(repeating: 0, count: paddedLength - fits.count))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).fits")
        try fits.write(to: url)
        return url
    }

    private func writeSyntheticXISF(
        width: Int,
        height: Int,
        values: [Float32]
    ) throws -> URL {
        XCTAssertEqual(values.count, width * height)
        var samples = Data()
        for value in values {
            var bitPattern = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bitPattern) { samples.append(contentsOf: $0) }
        }

        let imageTemplate = """
        <Image id="image0" geometry="\(width):\(height):1" sampleFormat="Float32" bounds="0:1" colorSpace="Gray" location="attachment:@OFFSET@:\(samples.count)"><Property id="Observation:Object:Name" type="String">M42</Property></Image>
        """
        var attachmentOffset = 0
        var header = ""
        while true {
            let image = imageTemplate.replacingOccurrences(
                of: "@OFFSET@",
                with: String(attachmentOffset)
            )
            header = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><xisf version=\"1.0\" xmlns=\"http://www.pixinsight.com/xisf\">\(image)</xisf>"
            let nextOffset = 16 + header.utf8.count
            guard nextOffset != attachmentOffset else { break }
            attachmentOffset = nextOffset
        }

        var xisf = Data("XISF0100".utf8)
        var headerLength = UInt32(header.utf8.count).littleEndian
        withUnsafeBytes(of: &headerLength) { xisf.append(contentsOf: $0) }
        xisf.append(Data(repeating: 0, count: 4))
        xisf.append(Data(header.utf8))
        xisf.append(samples)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).xisf")
        try xisf.write(to: url)
        return url
    }
}

final class FITSStretchConfigurationTests: XCTestCase {
    func testImageEditCoordinatorSharesAvailabilityAndRequests() {
        let coordinator = ImageEditCommandCoordinator()
        var availabilityChanges = 0
        coordinator.availabilityDidChange = { availabilityChanges += 1 }

        coordinator.updateAvailability(canUndo: true, canRedo: false)
        coordinator.requestUndo()
        coordinator.requestRedo()

        XCTAssertTrue(coordinator.canUndo)
        XCTAssertFalse(coordinator.canRedo)
        XCTAssertEqual(coordinator.undoRequestNumber, 1)
        XCTAssertEqual(coordinator.redoRequestNumber, 0)
        XCTAssertEqual(availabilityChanges, 1)

        coordinator.updateAvailability(canUndo: false, canRedo: true)
        coordinator.requestUndo()
        coordinator.requestRedo()

        XCTAssertEqual(coordinator.undoRequestNumber, 1)
        XCTAssertEqual(coordinator.redoRequestNumber, 1)
        XCTAssertEqual(availabilityChanges, 2)
    }

    func testPreviewRenderPlanTracksVisiblePixelsAtTheCurrentZoom() {
        let fitPlan = ImagePreviewRenderPlan.make(
            sourceWidth: 12_000,
            sourceHeight: 8_000,
            zoom: 0.1,
            displayScale: 2
        )
        XCTAssertEqual(fitPlan.responsiveMaxDimension, 2_400)
        XCTAssertTrue(fitPlan.needsFullResolutionRefinement)

        let zoomedPlan = ImagePreviewRenderPlan.make(
            sourceWidth: 12_000,
            sourceHeight: 8_000,
            zoom: 0.25,
            displayScale: 2
        )
        XCTAssertEqual(zoomedPlan.responsiveMaxDimension, 6_000)
        XCTAssertTrue(zoomedPlan.needsFullResolutionRefinement)

        let sourceResolutionPlan = ImagePreviewRenderPlan.make(
            sourceWidth: 12_000,
            sourceHeight: 8_000,
            zoom: 0.5,
            displayScale: 2
        )
        XCTAssertEqual(sourceResolutionPlan.responsiveMaxDimension, 0)
        XCTAssertFalse(sourceResolutionPlan.needsFullResolutionRefinement)
    }

    func testPreviewRenderPlanFallsBackToTheBoundedBaselineWithoutMetadata() {
        let plan = ImagePreviewRenderPlan.make(
            sourceWidth: nil,
            sourceHeight: nil,
            zoom: 0.1,
            displayScale: 2
        )
        XCTAssertEqual(plan.responsiveMaxDimension, 2_048)
        XCTAssertTrue(plan.needsFullResolutionRefinement)
    }

    func testDefaultConfigurationMatchesTheUpstreamTaggedJSONSchema() throws {
        let configuration = FITSStretchConfiguration.default
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: configuration.jsonData) as? [String: Any]
        )
        let model = try XCTUnwrap(json["model"] as? [String: Any])

        XCTAssertEqual(model["type"] as? String, "auto-mtf")
        XCTAssertEqual(model["target_median"] as? Double, 0.2)
        XCTAssertEqual(model["shadows_clip"] as? Double, -2.8)
        XCTAssertEqual(json["color_strategy"] as? String, "unlinked")
        XCTAssertEqual(json["max_analysis_samples"] as? Int, 200_000)
        XCTAssertNil(configuration.validationMessage)
    }

    func testStretchFamiliesRemainGroupedAndEncodeTheirUpstreamNames() throws {
        XCTAssertEqual(FITSStretchType.automatic, [.autoMtf, .percentileAsinh])
        XCTAssertEqual(FITSStretchType.manual, [.linear, .asinh, .mtf, .ghs])
        XCTAssertEqual(FITSStretchType.utility, [.identity])

        let expectedNames = [
            "auto-mtf", "percentile-asinh", "linear", "asinh", "mtf", "ghs", "identity",
        ]
        let encodedNames = try FITSStretchType.allCases.map { type in
            var configuration = FITSStretchConfiguration.default
            configuration.type = type
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: configuration.jsonData) as? [String: Any]
            )
            let model = try XCTUnwrap(json["model"] as? [String: Any])
            return try XCTUnwrap(model["type"] as? String)
        }
        XCTAssertEqual(encodedNames, expectedNames)
    }

    func testInvalidDependentParametersAreRejectedBeforeRendering() {
        var configuration = FITSStretchConfiguration.default
        configuration.type = .ghs
        configuration.symmetryPoint = 0.25
        configuration.protectShadows = 0.5
        XCTAssertNotNil(configuration.validationMessage)

        configuration.protectShadows = 0.1
        configuration.protectHighlights = 0.9
        XCTAssertNil(configuration.validationMessage)
    }

    func testStretchStackEncodesAsAnOrderedJSONArray() throws {
        var second = FITSStretchConfiguration.default
        second.type = .linear
        second.black = 0.1
        second.white = 0.8
        let stack = FITSStretchStack(stages: [.default, second])
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: stack.jsonData) as? [[String: Any]]
        )

        XCTAssertEqual(json.count, 2)
        XCTAssertEqual((json[0]["model"] as? [String: Any])?["type"] as? String, "auto-mtf")
        XCTAssertEqual((json[1]["model"] as? [String: Any])?["type"] as? String, "linear")
    }

    func testProcessingConfigurationWrapsTheStackAndOptionalLinearSteps() throws {
        let withoutBackground = FITSImageProcessingConfiguration(
            stretchStack: FITSStretchStack(stages: [.default, .identity]),
            extractsBackground: false
        )
        let plainJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: withoutBackground.jsonData) as? [String: Any]
        )
        XCTAssertEqual((plainJSON["stretch"] as? [Any])?.count, 2)
        XCTAssertNil(plainJSON["background"])
        XCTAssertNil(plainJSON["deconvolution"])

        var deconvolution = FITSDeconvolutionConfiguration.default
        deconvolution.psfFWHMPixels = 2.8
        let withBackground = FITSImageProcessingConfiguration(
            stretchStack: .default,
            extractsBackground: true,
            deconvolution: deconvolution
        )
        let processedJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: withBackground.jsonData) as? [String: Any]
        )
        let background = try XCTUnwrap(processedJSON["background"] as? [String: Any])
        XCTAssertEqual(background["mode"] as? String, "subtract")
        let deconvolutionJSON = try XCTUnwrap(
            processedJSON["deconvolution"] as? [String: Any]
        )
        XCTAssertEqual(deconvolutionJSON["psf_fwhm_pixels"] as? Double, 2.8)
        XCTAssertEqual(deconvolutionJSON["iterations"] as? Int, 4)
        XCTAssertEqual(deconvolutionJSON["amount"] as? Double, 0.35)
        XCTAssertEqual(deconvolutionJSON["noise_fraction"] as? Double, 0.001)
        XCTAssertEqual(deconvolutionJSON["max_correction"] as? Double, 2.0)
        XCTAssertNotEqual(withBackground.cacheIdentifier, withoutBackground.cacheIdentifier)

        let interactivePreview = FITSImageProcessingConfiguration(
            stretchStack: .default,
            extractsBackground: true,
            deconvolution: deconvolution,
            interactivePreview: true
        )
        let previewJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: interactivePreview.jsonData) as? [String: Any]
        )
        XCTAssertEqual(previewJSON["interactive_preview"] as? Bool, true)
        XCTAssertNotEqual(interactivePreview.cacheIdentifier, withBackground.cacheIdentifier)
    }

    func testProcessingRecipeRoundTripsThroughTheMacPasteboard() throws {
        var ghs = FITSStretchConfiguration.default
        ghs.type = .ghs
        ghs.stretchFactor = 4.2
        ghs.localIntensity = 1.5
        ghs.symmetryPoint = 0.2
        ghs.protectShadows = 0.05
        ghs.protectHighlights = 0.9
        var deconvolution = FITSDeconvolutionConfiguration.default
        deconvolution.iterations = 3
        let processing = FITSImageProcessingConfiguration(
            stretchStack: FITSStretchStack(stages: [.default, ghs]),
            extractsBackground: true,
            deconvolution: deconvolution
        )
        let pasteboard = NSPasteboard(name: .init("fyi.seiza.tests.\(UUID().uuidString)"))

        try ImageProcessingClipboard.copy(processing, to: pasteboard)

        XCTAssertEqual(try ImageProcessingClipboard.read(from: pasteboard), processing)
        XCTAssertNotNil(pasteboard.string(forType: .string))
    }

    func testEveryStretchModelRoundTripsThroughRecipeJSON() throws {
        for type in FITSStretchType.allCases {
            var stage = FITSStretchConfiguration.default
            stage.type = type
            let processing = FITSImageProcessingConfiguration(
                stretchStack: FITSStretchStack(stages: [stage]),
                extractsBackground: false
            )

            let data = try JSONEncoder().encode(processing)
            let decoded = try JSONDecoder().decode(
                FITSImageProcessingConfiguration.self,
                from: data
            )

            XCTAssertEqual(decoded, processing, type.title)
        }
    }

    func testDeconvolutionConfigurationRejectsUnsafeOrInvalidValues() {
        var configuration = FITSDeconvolutionConfiguration.default
        XCTAssertNil(configuration.validationMessage)

        configuration.iterations = 0
        XCTAssertNotNil(configuration.validationMessage)
        configuration = .default
        configuration.psfFWHMPixels = .nan
        XCTAssertNotNil(configuration.validationMessage)
        configuration = .default
        configuration.amount = 1.1
        XCTAssertNotNil(configuration.validationMessage)
    }

    func testStretchHistorySupportsUndoRedoAndClearsDivergentRedo() {
        var history = FITSStretchHistory()
        var linear = FITSStretchConfiguration.default
        linear.type = .linear
        var asinh = FITSStretchConfiguration.default
        asinh.type = .asinh

        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.undo())
        history.apply(linear)
        history.apply(asinh)
        XCTAssertEqual(history.appliedStages.map(\.type), [.autoMtf, .linear, .asinh])

        XCTAssertTrue(history.undo())
        XCTAssertEqual(history.current.type, .linear)
        XCTAssertTrue(history.canRedo)
        XCTAssertTrue(history.redo())
        XCTAssertEqual(history.current.type, .asinh)

        XCTAssertTrue(history.undo())
        history.apply(.default)
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.appliedStages.map(\.type), [.autoMtf, .linear, .autoMtf])

        var identity = FITSStretchConfiguration.default
        identity.type = .identity
        history.replace(with: identity)
        XCTAssertEqual(history.appliedStages.map(\.type), [.identity])
        XCTAssertTrue(history.undo())
        XCTAssertEqual(history.appliedStages.map(\.type), [.autoMtf, .linear, .autoMtf])

        history.updateCurrent(identity)
        XCTAssertEqual(history.appliedStages.map(\.type), [.autoMtf, .linear, .identity])
        XCTAssertTrue(history.undo())
        XCTAssertEqual(history.appliedStages.map(\.type), [.autoMtf, .linear, .autoMtf])
    }

    func testStretchHistoryCanStartFromACarriedDirectoryRecipe() {
        var linear = FITSStretchConfiguration.default
        linear.type = .linear
        linear.black = 0.1
        linear.white = 0.8
        let stack = FITSStretchStack(stages: [.default, linear])

        let history = FITSStretchHistory(stack: stack)

        XCTAssertEqual(history.stack, stack)
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
    }

    @MainActor
    func testDocumentModelStartsFromTheCompleteCarriedProcessingRecipe() {
        var linear = FITSStretchConfiguration.default
        linear.type = .linear
        var deconvolution = FITSDeconvolutionConfiguration.default
        deconvolution.iterations = 3
        let processing = FITSImageProcessingConfiguration(
            stretchStack: FITSStretchStack(stages: [.default, linear]),
            extractsBackground: true,
            deconvolution: deconvolution
        )
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).fits")

        let model = ImageDocumentModel(
            url: missingURL,
            processingConfiguration: processing
        )

        XCTAssertEqual(model.processingConfiguration, processing)
        XCTAssertFalse(model.stretchHistory.canUndo)
    }

    @MainActor
    func testDocumentModelPreservesDirectoryStretchUndoAndRedoHistory() {
        var linear = FITSStretchConfiguration.default
        linear.type = .linear
        linear.black = 0.1
        linear.white = 0.9
        var history = FITSStretchHistory()
        history.apply(linear)
        XCTAssertTrue(history.undo())
        XCTAssertTrue(history.canRedo)
        XCTAssertTrue(history.redo())
        let processing = FITSImageProcessingConfiguration(
            stretchStack: history.stack,
            extractsBackground: false
        )
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).fits")

        let model = ImageDocumentModel(
            url: missingURL,
            processingConfiguration: processing,
            stretchHistory: history
        )

        XCTAssertTrue(model.stretchHistory.canUndo)
        XCTAssertFalse(model.stretchHistory.canRedo)
        model.undoStretch()
        XCTAssertEqual(model.stretchHistory.stack, .default)
        XCTAssertTrue(model.stretchHistory.canRedo)
    }

    func testStretchHistoryCommitsRemovedAndReorderedStagesAsOneUndoStep() {
        var history = FITSStretchHistory()
        var linear = FITSStretchConfiguration.default
        linear.type = .linear
        var asinh = FITSStretchConfiguration.default
        asinh.type = .asinh
        history.apply(linear)
        history.apply(asinh)

        history.replaceStack(with: [asinh, .default])
        XCTAssertEqual(history.appliedStages.map(\.type), [.asinh, .autoMtf])

        history.replaceStack(with: history.appliedStages)
        XCTAssertTrue(history.undo())
        XCTAssertEqual(history.appliedStages.map(\.type), [.autoMtf, .linear, .asinh])
        XCTAssertTrue(history.redo())
        XCTAssertEqual(history.appliedStages.map(\.type), [.asinh, .autoMtf])
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
