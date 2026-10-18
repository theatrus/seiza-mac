import XCTest

@testable import Seiza

// MARK: - Synthetic frames

/// Writes a BITPIX 16 FITS file with typed header cards, so the native
/// probe classifies roles and signatures the way real capture software's
/// output would.
enum SyntheticFrame {
    static func noisyStarField(width: Int = 160, height: Int = 128) -> [Int16] {
        starField(width: width, height: height).enumerated().map { index, value in
            var hash = UInt32(index) &+ 0x9e3779b9
            hash = (hash ^ (hash >> 16)) &* 0x85ebca6b
            hash = (hash ^ (hash >> 13)) &* 0xc2b2ae35
            hash ^= hash >> 16
            return value + Int16(hash % 61) - 30
        }
    }
    static func write(
        width: Int,
        height: Int,
        values: [Int16],
        cards extraCards: [String] = [],
        directory: URL? = nil,
        name: String? = nil
    ) throws -> URL {
        precondition(values.count == width * height)
        var fits = Data()
        var cards = [
            "SIMPLE  =                    T",
            "BITPIX  =                   16",
            "NAXIS   =                    2",
            String(format: "NAXIS1  = %20d", width),
            String(format: "NAXIS2  = %20d", height),
            "BZERO   =                32768",
        ]
        cards.append(contentsOf: extraCards)
        cards.append("END")
        for value in cards {
            let card = value.padding(toLength: 80, withPad: " ", startingAt: 0)
            fits.append(card.data(using: .ascii)!)
        }
        let headerLength = ((fits.count + 2_879) / 2_880) * 2_880
        fits.append(Data(repeating: 0x20, count: headerLength - fits.count))
        for value in values {
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) { fits.append(contentsOf: $0) }
        }
        let paddedLength = ((fits.count + 2_879) / 2_880) * 2_880
        fits.append(Data(repeating: 0, count: paddedLength - fits.count))

        let url = (directory ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(name ?? "\(UUID().uuidString).fits")
        try fits.write(to: url)
        return url
    }

    static func lightCards(
        filter: String = "Ha",
        exposureSeconds: Double = 30
    ) -> [String] {
        [
            "IMAGETYP= 'LIGHT'",
            "FILTER  = '\(filter)'",
            String(format: "EXPTIME = %20.1f", exposureSeconds),
            "INSTRUME= 'SyntheticCam'",
            "GAIN    =                  100",
            "OFFSET  =                   50",
            "XBINNING=                    1",
            "YBINNING=                    1",
        ]
    }

    static func starField(width: Int, height: Int) -> [Int16] {
        let stars: [(Double, Double)] = [
            (19.7, 16.4), (71.3, 28.1), (132.2, 34.8), (43.1, 49.7),
            (103.4, 58.3), (22.8, 70.2), (82.7, 76.5), (143.1, 87.8),
            (54.4, 96.2), (116.8, 104.1), (31.2, 113.0), (91.5, 118.4),
        ]
        return (0..<(width * height)).map { index in
            let x = Double(index % width)
            let y = Double(index / width)
            let signal = stars.enumerated().reduce(100.0) { value, entry in
                let (starIndex, position) = entry
                let dx = x - position.0
                let dy = y - position.1
                return value + (900.0 + Double(starIndex) * 130.0)
                    * exp(-(dx * dx + dy * dy) / 3.2)
            }
            return Int16(signal.rounded())
        }
    }
}

// MARK: - SNR analysis

private struct SharedReferenceFixture {
    let root: URL
    let common: URL
    let good: URL
    let second: URL
    let turned: URL
    var options: ImageStackOptions {
        var options = ImageStackOptions()
        options.normalization = .none
        options.rejection = .none
        return options
    }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let values = SyntheticFrame.noisyStarField(width: 160, height: 160)
        common = try SyntheticFrame.write(width: 176, height: 176,
            values: SyntheticFrame.noisyStarField(width: 176, height: 176).map { $0 * 2 },
            cards: ["SEIZAMST= 'LIGHT'"], directory: root, name: "common.fits")
        good = try SyntheticFrame.write(width: 160, height: 160, values: values,
            cards: SyntheticFrame.lightCards(), directory: root, name: "a-good.fits")
        second = try SyntheticFrame.write(width: 160, height: 160, values: values,
            cards: SyntheticFrame.lightCards(), directory: root, name: "b-good.fits")
        turned = try SyntheticFrame.write(width: 160, height: 160,
            values: (0..<values.count).map { values[(159 - $0 % 160) * 160 + $0 / 160] },
            cards: SyntheticFrame.lightCards(), directory: root, name: "c-turned.fits")
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

final class SharedStackReferenceTests: XCTestCase {
    func testRankingsMustContainEachScoredInputExactlyOnceAndWinnerFirst() throws {
        let score: [String: Any] = ["stars": 12, "medianStarArea": 2,
            "background": 10, "backgroundVariation": 1, "score": 20]
        func selection(_ ranking: [Int]) throws -> StackReferenceSelection {
            try JSONDecoder().decode(StackReferenceSelection.self, from: JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1, "referenceIndex": 1, "referencePath": "/b",
                "scores": [score, score, NSNull()], "ranking": ranking]))
        }
        XCTAssertNoThrow(try selection([1, 0]).validate(paths: ["/a", "/b", "/c"]))
        for invalid in [[1, 1], [1], [0, 1], [1, 2], [1, 0, 7]] {
            XCTAssertThrowsError(try selection(invalid).validate(paths: ["/a", "/b", "/c"]))
        }
    }

    func testNativeFallbackStartsEmptyAndPersistsSeparateReferences() async throws {
        let f = try SharedReferenceFixture()
        defer { f.remove() }
        let session = try LiveStackNativeSession.open(referencePath: f.turned.path,
            optionsJSON: String(decoding: try f.options.jsonData, as: UTF8.self),
            calibration: .init(), referenceImagePath: f.common.path,
            candidatePaths: [f.turned.path, f.good.path])
        XCTAssertEqual(session.channelReferencePath, f.good.path)
        XCTAssertEqual(session.referenceSelection?.skipped.map(\.path), [f.turned.path])
        var state = try await session.state()
        XCTAssertTrue(state.isValidFromCore)
        XCTAssertEqual(state.acceptedFrames, 0)
        XCTAssertEqual(state.referenceIntegrated, false)
        // Rust canonical paths and Foundation URLs spell macOS's /var alias
        // differently; compare both through the same identity conversion.
        XCTAssertEqual(StackInputProtection.referenceIdentity(state.referenceImagePath),
            StackInputProtection.referenceIdentity(f.common.path))
        XCTAssertEqual(state.width, 176)
        XCTAssertFalse(state.inputPaths.contains(f.common.path))
        for url in [f.good, f.second] {
            let pushed = try await session.push(path: url.path)
            XCTAssertEqual(pushed.disposition?.accepted, true, pushed.disposition?.reason ?? "")
        }
        state = try await session.saveContext(to: f.root.appendingPathComponent("stack.context").path)
        XCTAssertEqual(state.acceptedFrames, 2)
        await session.close()
        let resumed = try LiveStackNativeSession.resume(contextPath: f.root.appendingPathComponent("stack.context").path)
        let restored = try await resumed.state()
        XCTAssertTrue(state.describesSameCheckpoint(restored))
        let export = try await resumed.exportSnapshot()
        XCTAssertThrowsError(try export.writeFITS(to: f.common.path))
        let alias = f.root.appendingPathComponent("alias.fits")
        try FileManager.default.linkItem(at: f.common, to: alias)
        XCTAssertThrowsError(try export.writeFITS(to: alias.path))
        export.free()
        let replay = try await resumed.reintegrate(lowSigma: 0, highSigma: 0)
        XCTAssertEqual(replay.acceptedFrames, 2)
        XCTAssertThrowsError(try replay.writeFITS(to: f.common.path))
        replay.free()
        let finished = try await resumed.finish()
        XCTAssertThrowsError(try finished.writeFITS(to: f.common.path))
        let output = f.root.appendingPathComponent("finished.fits")
        try finished.writeFITS(to: output.path)
        finished.free()
        XCTAssertEqual(try CalibrationService.probe(path: output.path).signature.width, 176)
    }

    func testReadFailureDoesNotFallBackToAnotherChannelLight() throws {
        let f = try SharedReferenceFixture()
        defer { f.remove() }
        XCTAssertThrowsError(try LiveStackNativeSession.open(referencePath: "/missing.fits",
            optionsJSON: String(decoding: try f.options.jsonData, as: UTF8.self),
            calibration: .init(), referenceImagePath: f.common.path,
            candidatePaths: ["/missing.fits", f.good.path]))
    }

    func testManualReferenceDoesNotSilentlyFallBackAndCancellationDoesNotWrite() throws {
        let f = try SharedReferenceFixture()
        defer { f.remove() }
        let output = f.root.appendingPathComponent("manual.fits")
        let request = ImageStackRequest(inputs: [f.turned, f.good, f.second], output: output,
            options: f.options, calibration: .init(), referenceImage: f.common)
        XCTAssertThrowsError(try ImageStackEngine.stack(request: request, cancellation: .init()) { _ in })
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let cancellation = ImageStackCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try ImageStackEngine.stack(request: request, cancellation: cancellation) { _ in }) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testDirectorySharedGridCountsOnlyLightsAndProtectsAllBatchSources() throws {
        let f = try SharedReferenceFixture()
        defer { f.remove() }
        let original = try Data(contentsOf: f.common)
        let output = f.root.appendingPathComponent("output.fits")
        let result = try ImageStackEngine.stack(request: .init(inputs: [f.good, f.second],
            output: output, options: f.options, calibration: .init(), referenceImage: f.common,
            choosesReferenceAutomatically: true), cancellation: .init()) { _ in }
        XCTAssertEqual(result.acceptedFrames, 2)
        XCTAssertEqual(result.rejectedFrames, 0)
        XCTAssertEqual(result.dispositions.count, 2)
        XCTAssertTrue(result.referenceNote?.contains("common.fits") == true)
        XCTAssertEqual(try CalibrationService.probe(path: output.path).signature.width, 176)
        XCTAssertEqual(try Data(contentsOf: f.common), original)
        // The first output cannot overwrite a later group's alignment image.
        let first = ImageStackJob(group: .init(id: "Ha", filter: nil, inputs: [f.good, f.second]),
            request: .init(inputs: [f.good, f.second], output: f.common,
                options: f.options, calibration: .init()))
        let second = ImageStackJob(group: .init(id: "OIII", filter: nil, inputs: [f.good, f.second]),
            request: .init(inputs: [f.good, f.second], output: output,
                options: f.options, calibration: .init(), referenceImage: f.common))
        XCTAssertThrowsError(try ImageStackBatchEngine.stack(request: .init(jobs: [first, second]),
            cancellation: .init()) { _ in })
        XCTAssertEqual(try Data(contentsOf: f.common), original)
    }

    func testSharedImageCanBeExplicitlySelectedAsALight() throws {
        let f = try SharedReferenceFixture()
        defer { f.remove() }
        let result = try ImageStackEngine.stack(request: .init(inputs: [f.good, f.second],
            output: f.root.appendingPathComponent("same-reference.fits"), options: f.options,
            calibration: .init(), referenceImage: f.good), cancellation: .init()) { _ in }
        XCTAssertEqual(result.acceptedFrames, 2)
        XCTAssertEqual(result.dispositions.count, 2)
    }

    func testLiveFallbackUsesChosenChannelAndRestoresSharedGrid() async throws {
        let f = try SharedReferenceFixture()
        defer { f.remove() }
        var config = LiveStackRunConfiguration(watchFolder: f.root.path,
            sessionRootDirectory: f.root.appendingPathComponent("sessions"))
        config.referenceImagePath = f.common.path
        config.choosesReferenceAutomatically = true
        config.options = f.options
        config.monitorStabilityDuration = 0.01
        config.monitorScanInterval = 3600
        let run = try LiveStackCoordinator(configuration: config, referenceSelector: { urls in
            XCTAssertFalse(urls.contains(f.common))
            let index = try XCTUnwrap(urls.firstIndex(of: f.turned))
            let scores = urls.map { _ in ["stars": 12, "medianStarArea": 2,
                "background": 10, "backgroundVariation": 1, "score": 20] }
            let ranking = [index] + urls.indices.filter { $0 != index }
            return try JSONDecoder().decode(StackReferenceSelection.self, from: JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1, "referenceIndex": index, "referencePath": f.turned.path,
                "scores": scores, "ranking": ranking]))
        })
        try await run.start()
        let initial = await run.currentSnapshot()
        XCTAssertEqual(initial.acceptedFrames, 1)
        XCTAssertEqual(initial.channelReferencePath, f.good.path)
        XCTAssertEqual(initial.referenceImagePath, StackInputProtection.referenceIdentity(f.common.path))
        XCTAssertTrue(initial.attention.contains { $0.message.contains("c-turned.fits") })
        try await run.pauseAndSave()
        await run.dispose()
        config.referenceImagePath = nil // A reopened window has no picker selection yet.
        let restored = try LiveStackCoordinator(configuration: config, referenceSelector: { _ in
            XCTFail("A resumed stack must retain its channel reference")
            throw CancellationError()
        })
        try await restored.start()
        let snapshot = await restored.currentSnapshot()
        XCTAssertEqual(snapshot.acceptedFrames, 1)
        XCTAssertEqual(snapshot.channelReferencePath, f.good.path)
        XCTAssertEqual(snapshot.referenceImagePath, StackInputProtection.referenceIdentity(f.common.path))
        do {
            _ = try await restored.saveSnapshot(to: f.common.path)
            XCTFail("Must protect shared alignment image")
        } catch { XCTAssertTrue(error.localizedDescription.contains("alignment image")) }
        await restored.dispose()

        config.referenceImagePath = f.good.path
        config.initialReferencePath = f.second.path
        config.choosesReferenceAutomatically = false
        let different = try LiveStackCoordinator(configuration: config)
        try await different.start()
        let fresh = await different.currentSnapshot()
        XCTAssertEqual(fresh.channelReferencePath, f.second.path)
        XCTAssertEqual(fresh.referenceImagePath, StackInputProtection.referenceIdentity(f.good.path))
        XCTAssertTrue(fresh.attention.contains { $0.message.contains("did not match this run") })
        await different.dispose()
    }
}

final class StackSnrAnalysisTests: XCTestCase {
    func testAnalyzerRatesEveryDepthAgainstTheDeepestSignal() {
        let analysis = StackSnrAnalyzer.analyze([
            StackSnrMeasurement(frames: 1, noise: 8, background: 1, signal: 8),
            StackSnrMeasurement(frames: 4, noise: 5, background: 1, signal: 8),
        ])
        XCTAssertEqual(analysis.points.map(\.snr), [1.0, 1.6])
        XCTAssertEqual(analysis.noiseImprovement, 1.6, accuracy: 1e-12)
        XCTAssertEqual(analysis.idealImprovement, 2.0, accuracy: 1e-12)
        XCTAssertEqual(analysis.efficiency, 0.8, accuracy: 1e-12)
    }

    func testAnalyzerKeepsTheLastReadingAtADepthAndDropsUnusable() {
        let analysis = StackSnrAnalyzer.analyze([
            StackSnrMeasurement(frames: 1, noise: 10, background: 1, signal: 10),
            StackSnrMeasurement(frames: 1, noise: 8, background: 1, signal: 8),
            StackSnrMeasurement(frames: 2, noise: 0, background: 1, signal: 8),
            StackSnrMeasurement(
                frames: 4, noise: .nan, background: 1, signal: 8),
            StackSnrMeasurement(frames: 4, noise: 4, background: 1, signal: 8),
        ])
        XCTAssertEqual(analysis.points.map(\.frames), [1, 4])
        XCTAssertEqual(analysis.noiseImprovement, 2.0, accuracy: 1e-12)
    }

    func testAnalyzerIsEmptyWithoutAUsableDeepSignal() {
        XCTAssertEqual(StackSnrAnalyzer.analyze([]), .empty)
        let negativeSignal = StackSnrAnalyzer.analyze([
            StackSnrMeasurement(frames: 1, noise: 2, background: 1, signal: -3)
        ])
        XCTAssertEqual(negativeSignal, .empty)
    }

    func testNativeScheduleIsTheDoublingLadderPlusTheFinalDepth() {
        XCTAssertEqual(
            StackSnrMeasurementSchedule.depths(totalFrames: 10), [1, 2, 4, 8, 10])
        XCTAssertEqual(StackSnrMeasurementSchedule.depths(totalFrames: 1), [1])
        XCTAssertEqual(StackSnrMeasurementSchedule.depths(totalFrames: 0), [])
    }

    func testLiveScheduleMeasuresPowersOfTwoOncePerDepth() {
        XCTAssertTrue(StackSnrMeasurementSchedule.isLiveMeasurementDue(
            acceptedFrames: 4, measuredDepths: [1, 2]))
        XCTAssertFalse(StackSnrMeasurementSchedule.isLiveMeasurementDue(
            acceptedFrames: 4, measuredDepths: [1, 2, 4]))
        XCTAssertFalse(StackSnrMeasurementSchedule.isLiveMeasurementDue(
            acceptedFrames: 3, measuredDepths: []))
        XCTAssertTrue(StackSnrMeasurementSchedule.isLiveMeasurementDue(
            acceptedFrames: 3, measuredDepths: [], includeCurrentDepth: true))
        XCTAssertFalse(StackSnrMeasurementSchedule.isLiveMeasurementDue(
            acceptedFrames: 0, measuredDepths: [], includeCurrentDepth: true))
    }

    func testCumulativeExposureRequiresEveryAcceptedExposure() {
        XCTAssertEqual(
            LiveStackExposureMath.cumulativeExposure([30, 30, 60]), 120)
        XCTAssertNil(LiveStackExposureMath.cumulativeExposure([30, nil]))
        XCTAssertNil(LiveStackExposureMath.cumulativeExposure([30, 0]))
        XCTAssertNil(LiveStackExposureMath.cumulativeExposure([]))
    }

    func testPlotLayoutAnchorsTheIdealAtTheShallowestPoint() {
        let points = [
            StackSnrPlotPoint(frames: 1, snr: 1, noise: 8, exposureSeconds: 0),
            StackSnrPlotPoint(frames: 4, snr: 1.6, noise: 5, exposureSeconds: 0),
        ]
        let geometry = StackSnrPlotLayout.create(
            points: points, width: 300, height: 200)
        XCTAssertEqual(geometry.measured.count, 2)
        XCTAssertEqual(geometry.ideal.count, 2)
        XCTAssertEqual(geometry.measured[0], geometry.ideal[0])
        XCTAssertLessThan(geometry.measured[0].x, geometry.measured[1].x)
        // The ideal reaches 2.0 at four frames while the measurement reaches
        // 1.6, so the ideal sits higher (smaller y) on the right edge.
        XCTAssertLessThan(geometry.ideal[1].y, geometry.measured[1].y)
        XCTAssertEqual(geometry.minimumFrames, 1)
        XCTAssertEqual(geometry.maximumFrames, 4)
    }

    func testPlotLayoutIsEmptyForDegenerateInput() {
        XCTAssertTrue(StackSnrPlotLayout.create(
            points: [], width: 300, height: 200).isEmpty)
        let points = [
            StackSnrPlotPoint(frames: 1, snr: 1, noise: 8, exposureSeconds: 0)
        ]
        XCTAssertTrue(StackSnrPlotLayout.create(
            points: points, width: 20, height: 200).isEmpty)
        XCTAssertFalse(StackSnrPlotLayout.create(
            points: points, width: 300, height: 200).isEmpty)
    }
}

// MARK: - Filter and calibration identities

final class LiveStackFilterIdentityTests: XCTestCase {
    func testHeaderFilterWinsOverFilename() {
        var probe = CalibrationFrameProbe(
            path: "/captures/M42_Ha_001.fits", role: "light")
        probe.signature.filter = "Luminance"
        let identity = LiveStackFilterIdentity.fromProbe(probe)
        XCTAssertEqual(identity.key, "luminance")
        XCTAssertEqual(identity.source, .header)
    }

    func testFilenameFilterIsTheFallback() {
        let probe = CalibrationFrameProbe(
            path: "/captures/M42_Ha_001.fits", role: "light")
        let identity = LiveStackFilterIdentity.fromProbe(probe)
        XCTAssertEqual(identity.key, "hydrogen-alpha")
        XCTAssertEqual(identity.source, .filename)
    }

    func testKnownAliasesShareOneIdentity() {
        let short = LiveStackFilterIdentity.fromName("L", source: .header)
        let long = LiveStackFilterIdentity.fromName("Luminance", source: .header)
        XCTAssertTrue(short.matches(long))
        XCTAssertEqual(short.displayName, "Luminance")
    }

    func testUnknownNamesStayDistinct() {
        let clear = LiveStackFilterIdentity.fromName("Clear", source: .header)
        let ha = LiveStackFilterIdentity.fromName("Ha", source: .header)
        XCTAssertFalse(clear.matches(ha))
    }

    func testStoredNameRoundTrip() {
        XCTAssertEqual(
            LiveStackFilterIdentity.fromStoredName(nil), .unfiltered)
        XCTAssertEqual(
            LiveStackFilterIdentity.fromStoredName("  "), .unfiltered)
        let stored = LiveStackFilterIdentity.fromStoredName("H-alpha")
        XCTAssertEqual(stored.key, "hydrogen-alpha")
    }
}

final class LiveStackCalibrationIdentityTests: XCTestCase {
    private func signature(
        camera: String? = "Cam",
        width: Int64? = 100,
        gain: Int64? = 100
    ) -> CalibrationFrameSignature {
        var value = CalibrationFrameSignature()
        value.camera = camera
        value.width = width
        value.gain = gain
        return value
    }

    func testAKnownFieldChangeIsNamed() {
        var candidate = signature()
        candidate.gain = 200
        let reason = LiveStackCalibrationIdentity.mismatchReason(
            reference: signature(), candidate: candidate)
        XCTAssertEqual(reason, "The candidate gain does not match the reference.")
    }

    func testAMissingCandidateFieldIsNamed() {
        var candidate = signature()
        candidate.width = nil
        let reason = LiveStackCalibrationIdentity.mismatchReason(
            reference: signature(), candidate: candidate)
        XCTAssertEqual(reason, "The candidate does not report width.")
    }

    func testASparseReferenceAcceptsARicherCandidate() {
        var reference = signature()
        reference.gain = nil
        reference.camera = nil
        XCTAssertNil(LiveStackCalibrationIdentity.mismatchReason(
            reference: reference, candidate: signature()))
    }

    func testExposureAndTemperatureAreNotCompared() {
        var reference = signature()
        reference.exposureSeconds = 30
        reference.cameraTempC = -10
        var candidate = signature()
        candidate.exposureSeconds = 120
        candidate.cameraTempC = 5
        XCTAssertNil(LiveStackCalibrationIdentity.mismatchReason(
            reference: reference, candidate: candidate))
    }

    func testCameraComparisonIgnoresCaseAndWhitespace() {
        var candidate = signature()
        candidate.camera = " c a m "
        XCTAssertNil(LiveStackCalibrationIdentity.mismatchReason(
            reference: signature(), candidate: candidate))
    }
}

final class CalibrationEligibilityTests: XCTestCase {
    func testReasonsInPriorityOrder() {
        var probe = CalibrationFrameProbe(path: "/a.fits", role: "light")
        probe.isMaster = true
        XCTAssertEqual(
            CalibrationLightEligibility.ineligibilityReason(probe),
            "the frame is already a master")
        probe.isMaster = false
        probe.role = "flat"
        XCTAssertEqual(
            CalibrationLightEligibility.ineligibilityReason(probe),
            "the frame is not a light frame")
        probe.role = "light"
        probe.calibrationState.darkSubtracted = true
        XCTAssertEqual(
            CalibrationLightEligibility.ineligibilityReason(probe),
            "the light frame is already preprocessed")
        probe.calibrationState.darkSubtracted = false
        XCTAssertNil(CalibrationLightEligibility.ineligibilityReason(probe))
    }

    func testEnrichmentFillsOnlyAMissingFilter() {
        var probe = CalibrationFrameProbe(
            path: "/captures/M42_Ha_001.fits", role: "light")
        XCTAssertEqual(
            CalibrationTargetMetadata.enrich(probe).signature.filter, "Ha")
        probe.signature.filter = " Luminance "
        XCTAssertEqual(
            CalibrationTargetMetadata.enrich(probe).signature.filter,
            " Luminance ")
    }
}

// MARK: - Cache and session paths

final class CalibrationCachePathTests: XCTestCase {
    func testLibraryIdentityIsStableAcrossCaseAndTrailingSeparators() {
        let a = CalibrationCachePaths.directoryIdentity(for: "/data/Calibration")
        let b = CalibrationCachePaths.directoryIdentity(for: "/data/calibration/")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 12)
        XCTAssertTrue(a.allSatisfy(\.isHexDigit))
    }

    func testDifferentLibrariesGetDifferentDirectories() {
        XCTAssertNotEqual(
            CalibrationCachePaths.directoryIdentity(for: "/data/library-a"),
            CalibrationCachePaths.directoryIdentity(for: "/data/library-b"))
    }
}

final class LiveStackSessionPathTests: XCTestCase {
    func testWatchFolderIdentityIgnoresCaseAndTrailingSeparators() {
        let a = LiveStackSessionPaths.forWatchFolder("/captures/M 101")
        let b = LiveStackSessionPaths.forWatchFolder("/captures/m 101/")
        XCTAssertEqual(a.lastPathComponent, b.lastPathComponent)
        XCTAssertEqual(a.deletingLastPathComponent().lastPathComponent, "LiveStacks")
        XCTAssertNotEqual(
            a.lastPathComponent,
            LiveStackSessionPaths.forWatchFolder("/captures/M 51").lastPathComponent)
    }

    func testGroupDirectoryNameSanitizesTheGroupId() {
        let name = LiveStackSessionPaths.safeGroupDirectoryName("live stack:α")
        XCTAssertFalse(name.contains(" "))
        XCTAssertFalse(name.contains(":"))
        let identity = name.split(separator: "-").last.map(String.init) ?? ""
        XCTAssertEqual(identity.count, 10)
    }
}

// MARK: - Session store

final class LiveStackSessionStoreTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("seiza-live-store-\(UUID().uuidString)")
    }

    private func syntheticNativeState(
        acceptedFrames: Int = 2,
        inputPaths: [String] = ["/captures/a.fits", "/captures/b.fits"]
    ) -> LiveStackNativeState {
        LiveStackNativeState(
            schemaVersion: 1,
            coreVersion: "0.18.5",
            configurationFingerprint: String(repeating: "ab", count: 32),
            width: 160,
            height: 128,
            channels: 1,
            acceptedFrames: acceptedFrames,
            rejectedFrames: 0,
            inputMode: "calibrate-and-prepare",
            inputPaths: inputPaths)
    }

    private func syntheticState(sessionId: String = "abc123") -> LiveStackPersistedState {
        LiveStackPersistedState(
            sessionId: sessionId,
            groupId: "live",
            groupTitle: "Live stack — test",
            filterName: "H-alpha",
            watchFolder: "/captures",
            stackOptionsJSON: "{}",
            calibrationHistory: [
                LiveStackCalibrationEpoch(startsAtAcceptedFrame: 1)
            ],
            exportedPaths: ["/output/snapshot.fits"],
            frames: [
                LiveStackPersistedFrame(
                    path: "/captures/a.fits",
                    disposition: .accepted,
                    reason: "Reference frame",
                    exposureSeconds: 30,
                    length: 1_000,
                    lastWriteUnixNanoseconds: 42),
                LiveStackPersistedFrame(
                    path: "/captures/x.fits",
                    disposition: .ignored,
                    reason: "Flat calibration frame"),
            ],
            snrSamples: [
                LiveStackPersistedSnrSample(
                    acceptedFrames: 2,
                    cumulativeExposureSeconds: 60,
                    noise: 0.5,
                    background: 0.1,
                    signal: 4,
                    channelNoise: [0.5],
                    measuredAtUTC: Date()),
            ])
    }

    @discardableResult
    private func publish(
        _ store: LiveStackSessionStore,
        state: LiveStackPersistedState,
        nativeState: LiveStackNativeState
    ) async throws -> LiveStackSessionStore.StoredGeneration {
        try await store.publish(state: state) { contextPath in
            try Data("synthetic-context".utf8)
                .write(to: URL(fileURLWithPath: contextPath))
            return nativeState
        }
    }

    func testPublishAndRestoreRoundTrip() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LiveStackSessionStore(
            sessionRootDirectory: root, groupId: "live")
        let nativeState = syntheticNativeState()
        let stored = try await publish(
            store, state: syntheticState(), nativeState: nativeState)
        XCTAssertEqual(stored.generation, 1)

        let candidates = await store.restoreCandidates()
        XCTAssertEqual(candidates.count, 1)
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertFalse(candidate.usedPreviousGeneration)
        XCTAssertEqual(candidate.manifest.state.filterName, "H-alpha")
        XCTAssertEqual(candidate.manifest.state.frames.count, 2)
        XCTAssertEqual(
            candidate.manifest.state.frames[0].exposureSeconds, 30)
        XCTAssertEqual(candidate.manifest.state.snrSamples.count, 1)
        let accepted = await store.tryAcceptRestoredGeneration(
            candidate, actual: nativeState)
        XCTAssertTrue(accepted)
        await store.close()
    }

    func testAcceptRejectsAMismatchedCheckpoint() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LiveStackSessionStore(
            sessionRootDirectory: root, groupId: "live")
        try await publish(
            store, state: syntheticState(), nativeState: syntheticNativeState())
        let candidates = await store.restoreCandidates()
        let candidate = try XCTUnwrap(candidates.first)
        let accepted = await store.tryAcceptRestoredGeneration(
            candidate, actual: syntheticNativeState(acceptedFrames: 5))
        XCTAssertFalse(accepted)
        await store.close()
    }

    func testACorruptContextFallsBackToThePreviousGeneration() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LiveStackSessionStore(
            sessionRootDirectory: root, groupId: "live")
        try await publish(
            store, state: syntheticState(),
            nativeState: syntheticNativeState(acceptedFrames: 1))
        let second = try await publish(
            store, state: syntheticState(), nativeState: syntheticNativeState())
        try Data("torn".utf8).write(to: second.contextURL)

        let candidates = await store.restoreCandidates()
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].generation, 1)
        XCTAssertTrue(candidates[0].usedPreviousGeneration)
        await store.close()
    }

    func testRetirementHidesOnlyTheRetiredSession() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LiveStackSessionStore(
            sessionRootDirectory: root, groupId: "live")
        try await publish(
            store, state: syntheticState(sessionId: "first"),
            nativeState: syntheticNativeState())
        try await store.retire(sessionId: "first")
        let retired = await store.restoreCandidates()
        XCTAssertTrue(retired.isEmpty)

        try await publish(
            store, state: syntheticState(sessionId: "second"),
            nativeState: syntheticNativeState())
        let candidates = await store.restoreCandidates()
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].manifest.state.sessionId, "second")
        XCTAssertEqual(candidates[0].generation, 2)
        await store.close()
    }

    func testOnlyOneActiveOwnerPerGroupDirectory() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LiveStackSessionStore(
            sessionRootDirectory: root, groupId: "live")
        XCTAssertThrowsError(
            try LiveStackSessionStore(sessionRootDirectory: root, groupId: "live")
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("active live-stack session"))
        }
        await store.close()
    }
}

// MARK: - Folder monitor tracker

final class StackFileCandidateTrackerTests: XCTestCase {
    private var configuration: StackFileCandidateTracker.Configuration {
        var value = StackFileCandidateTracker.Configuration()
        value.minimumStableDuration = 10
        value.initialRetryDelay = 5
        value.maximumRetryDelay = 100
        return value
    }

    private func observe(
        _ tracker: StackFileCandidateTracker,
        path: String = "/captures/a.fits",
        length: Int64 = 100,
        modified: Int64 = 1,
        identity: String? = "1:100",
        at seconds: TimeInterval
    ) {
        tracker.observe(
            path: path,
            length: length,
            lastWriteUnixNanoseconds: modified,
            fileIdentity: identity,
            now: Date(timeIntervalSinceReferenceDate: seconds))
    }

    private func due(
        _ tracker: StackFileCandidateTracker, at seconds: TimeInterval
    ) -> [StackFileCandidate] {
        tracker.dueCandidates(now: Date(timeIntervalSinceReferenceDate: seconds))
    }

    func testAFileNeedsTwoObservationsAndTheStabilityWindow() {
        let tracker = StackFileCandidateTracker(configuration: configuration)
        observe(tracker, at: 0)
        XCTAssertTrue(due(tracker, at: 11).isEmpty, "one observation is not enough")
        observe(tracker, at: 5)
        XCTAssertTrue(due(tracker, at: 9).isEmpty, "the window has not elapsed")
        let candidates = due(tracker, at: 11)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].attempt, 1)
    }

    func testAChangeRestartsTheWindowAndBumpsTheRevision() {
        let tracker = StackFileCandidateTracker(configuration: configuration)
        observe(tracker, at: 0)
        observe(tracker, at: 5)
        let first = due(tracker, at: 11)[0]
        tracker.complete(first, disposition: .retryableFailure,
            now: Date(timeIntervalSinceReferenceDate: 11))
        observe(tracker, length: 200, at: 12)
        XCTAssertFalse(tracker.isCandidateCurrent(first))
        observe(tracker, length: 200, at: 16)
        let second = due(tracker, at: 30)
        XCTAssertEqual(second.count, 1)
        XCTAssertGreaterThan(second[0].revision, first.revision)
    }

    func testRetryableFailuresBackOffExponentially() {
        let tracker = StackFileCandidateTracker(configuration: configuration)
        observe(tracker, at: 0)
        observe(tracker, at: 5)
        let first = due(tracker, at: 11)[0]
        tracker.complete(first, disposition: .retryableFailure,
            now: Date(timeIntervalSinceReferenceDate: 11))
        XCTAssertTrue(due(tracker, at: 15).isEmpty, "5 s backoff pending")
        let retry = due(tracker, at: 17)
        XCTAssertEqual(retry.count, 1)
        XCTAssertEqual(retry[0].attempt, 2)
        tracker.complete(retry[0], disposition: .retryableFailure,
            now: Date(timeIntervalSinceReferenceDate: 17))
        XCTAssertTrue(due(tracker, at: 26).isEmpty, "10 s backoff pending")
        XCTAssertEqual(due(tracker, at: 28).count, 1)
    }

    func testDurableTerminalsStayTerminal() {
        let tracker = StackFileCandidateTracker(configuration: configuration)
        observe(tracker, at: 0)
        observe(tracker, at: 5)
        let candidate = due(tracker, at: 11)[0]
        tracker.complete(candidate, disposition: .rejected,
            now: Date(timeIntervalSinceReferenceDate: 11))
        observe(tracker, length: 500, modified: 9, at: 200)
        observe(tracker, length: 500, modified: 9, at: 220)
        XCTAssertTrue(due(tracker, at: 400).isEmpty)
    }

    func testAnUnreadableTerminalReopensOnIdentityChange() {
        let tracker = StackFileCandidateTracker(configuration: configuration)
        observe(tracker, at: 0)
        observe(tracker, at: 5)
        let candidate = due(tracker, at: 11)[0]
        tracker.complete(candidate, disposition: .unreadable,
            now: Date(timeIntervalSinceReferenceDate: 11))
        XCTAssertTrue(due(tracker, at: 40).isEmpty)
        observe(tracker, identity: "1:200", at: 41)
        observe(tracker, identity: "1:200", at: 46)
        let reopened = due(tracker, at: 60)
        XCTAssertEqual(reopened.count, 1)
        XCTAssertEqual(reopened[0].attempt, 1)
    }

    func testAnUnreadableTerminalReopensAfterTheMaximumRetryDelay() {
        let tracker = StackFileCandidateTracker(configuration: configuration)
        observe(tracker, at: 0)
        observe(tracker, at: 5)
        let candidate = due(tracker, at: 11)[0]
        tracker.complete(candidate, disposition: .unreadable,
            now: Date(timeIntervalSinceReferenceDate: 11))
        observe(tracker, at: 50)
        XCTAssertTrue(due(tracker, at: 70).isEmpty, "the delay has not elapsed")
        observe(tracker, at: 120)
        observe(tracker, at: 130)
        XCTAssertEqual(due(tracker, at: 145).count, 1)
    }

    func testASecondPathWithATerminalIdentityIsIgnored() {
        let tracker = StackFileCandidateTracker(configuration: configuration)
        observe(tracker, at: 0)
        observe(tracker, at: 5)
        let candidate = due(tracker, at: 11)[0]
        tracker.complete(candidate, disposition: .accepted,
            now: Date(timeIntervalSinceReferenceDate: 11))
        observe(tracker, path: "/captures/renamed.fits", at: 20)
        observe(tracker, path: "/captures/renamed.fits", at: 25)
        XCTAssertTrue(due(tracker, at: 40).isEmpty)
    }

    func testReservationsBlockAndCommitBecomesTerminal() {
        let tracker = StackFileCandidateTracker(configuration: configuration)
        tracker.reserve("/captures/out.fits")
        observe(tracker, path: "/captures/out.fits", at: 0)
        observe(tracker, path: "/captures/out.fits", at: 5)
        XCTAssertTrue(due(tracker, at: 30).isEmpty)
        tracker.commitReservation(
            "/captures/out.fits", now: Date(timeIntervalSinceReferenceDate: 31))
        observe(tracker, path: "/captures/out.fits", at: 40)
        observe(tracker, path: "/captures/out.fits", at: 45)
        XCTAssertTrue(due(tracker, at: 60).isEmpty)
    }

    func testCandidatesKeepTheOriginalPathCase() {
        let tracker = StackFileCandidateTracker(configuration: configuration)
        observe(tracker, path: "/Captures/M31_Ha_001.FITS", at: 0)
        observe(tracker, path: "/Captures/M31_Ha_001.FITS", at: 5)
        let candidates = due(tracker, at: 11)
        XCTAssertEqual(candidates.map(\.path), ["/Captures/M31_Ha_001.FITS"])
    }

    func testClearingPendingDispositionsReoffersStrandedCandidates() {
        let tracker = StackFileCandidateTracker(configuration: configuration)
        observe(tracker, at: 0)
        observe(tracker, at: 5)
        XCTAssertEqual(due(tracker, at: 11).count, 1)
        // The offer was yielded but never completed (a cancelled ingestion
        // loop); without a reset the file would be skipped forever.
        XCTAssertTrue(due(tracker, at: 12).isEmpty)
        tracker.clearPendingDispositions()
        XCTAssertEqual(due(tracker, at: 13).count, 1)
    }

    func testRetryNowReopensOnlyUnreadableTerminals() {
        let tracker = StackFileCandidateTracker(configuration: configuration)
        observe(tracker, at: 0)
        observe(tracker, at: 5)
        let candidate = due(tracker, at: 11)[0]
        tracker.complete(candidate, disposition: .unreadable,
            now: Date(timeIntervalSinceReferenceDate: 11))
        tracker.retryNow("/captures/a.fits")
        observe(tracker, at: 20)
        observe(tracker, at: 26)
        XCTAssertEqual(due(tracker, at: 40).count, 1)
    }
}

// MARK: - Native matching

final class CalibrationMatchingNativeTests: XCTestCase {
    func testNativeDefaultTolerances() {
        let defaults = CalibrationMatchTolerances.nativeDefaults()
        XCTAssertEqual(defaults.exposureSeconds, 0.05, accuracy: 1e-9)
        XCTAssertEqual(defaults.exposureFraction, 0.001, accuracy: 1e-9)
        XCTAssertEqual(defaults.darkTemperatureC, 3, accuracy: 1e-9)
        XCTAssertEqual(defaults.rotationDeg, 2, accuracy: 1e-9)
        XCTAssertEqual(defaults.flatSessionSeconds, 86_400)
    }

    private func opticalSignature(rotation: Double) -> CalibrationFrameSignature {
        var value = CalibrationFrameSignature()
        value.filter = "Ha"
        value.focalLengthMm = 750
        value.rotationDeg = rotation
        return value
    }

    func testRotationWithinTheDefaultToleranceMatches() throws {
        let tolerances = CalibrationMatchTolerances.nativeDefaults()
        XCTAssertTrue(try CalibrationMatchingService.opticsMatch(
            reference: opticalSignature(rotation: 120),
            candidate: opticalSignature(rotation: 121.23),
            tolerances: tolerances))
        XCTAssertFalse(try CalibrationMatchingService.opticsMatch(
            reference: opticalSignature(rotation: 120),
            candidate: opticalSignature(rotation: 122.5),
            tolerances: tolerances))
    }

    func testEmptySignaturesAreNotASensorMatch() throws {
        XCTAssertFalse(try CalibrationMatchingService.sensorMatches(
            reference: CalibrationFrameSignature(),
            candidate: CalibrationFrameSignature()))
    }

    func testSensorMismatchDescriptionNamesTheField() throws {
        var reference = CalibrationFrameSignature()
        reference.width = 100
        reference.height = 100
        reference.channels = 1
        reference.gain = 100
        var candidate = reference
        candidate.gain = 200
        let description = try CalibrationMatchingService.describeSensorMismatch(
            reference: reference, candidate: candidate)
        XCTAssertTrue(description.lowercased().contains("gain"))
        XCTAssertTrue(description.contains("100"))
        XCTAssertTrue(description.contains("200"))
    }
}

// MARK: - Native session and probe

final class LiveStackNativeSessionTests: XCTestCase {
    func testAutomaticReferenceScoringLeavesSourcesUntouched() throws {
        let url = try SyntheticFrame.write(width: 160, height: 128,
            values: SyntheticFrame.noisyStarField(),
            cards: SyntheticFrame.lightCards())
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try Data(contentsOf: url)
        let missing = url.deletingLastPathComponent().appendingPathComponent("missing-\(UUID()).fits")
        let selection = try StackReferenceSelector.choose([missing, url])
        XCTAssertEqual(selection.referenceIndex, 1)
        XCTAssertNil(selection.scores[0])
        XCTAssertGreaterThan(try XCTUnwrap(selection.scores[1]).stars, 0)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertThrowsError(try StackReferenceSelector.choose([missing]))
        XCTAssertThrowsError(try StackReferenceSelector.choose([]))
    }

    func testEveryAdvancedRecipeOpensAndResumesThroughCABI() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let values = SyntheticFrame.noisyStarField()
        let reference = try SyntheticFrame.write(width: 160, height: 128, values: values,
            cards: SyntheticFrame.lightCards() + ["BAYERPAT= 'RGGB'"], directory: directory)
        let second = try SyntheticFrame.write(width: 160, height: 128, values: values,
            cards: SyntheticFrame.lightCards() + ["BAYERPAT= 'RGGB'"], directory: directory)
        let before = try Data(contentsOf: reference)
        for model in StackRegistrationModel.allCases {
            for demosaic in StackDemosaic.allCases {
                var options = ImageStackOptions()
                options.registrationModel = model
                options.demosaic = demosaic
                options.interpolation = .lanczos3
                options.weighting = .inverseNoiseVariance
                options.cfaIntegration = .bayerDrizzle
                options.suppressesHotPixels = true
                options.normalization = .localBackground
                options.localTileSize = 64
                let session = try LiveStackNativeSession.open(referencePath: reference.path,
                    optionsJSON: String(decoding: try options.jsonData, as: UTF8.self),
                    calibration: ImageStackCalibration())
                let outcome = try await session.push(path: second.path)
                XCTAssertTrue(try XCTUnwrap(outcome.disposition).accepted, outcome.disposition?.reason ?? "")
                let context = directory.appendingPathComponent("checkpoint.seiza-stack")
                let saved = try await session.saveContext(to: context.path)
                let restored = try LiveStackNativeSession.resume(contextPath: context.path)
                let state = try await restored.state()
                XCTAssertTrue(saved.describesSameCheckpoint(state))
                let preview = try await restored.renderPreview(
                    configJSON: LiveStackRunConfiguration.defaultPreviewProcessingJSON, maxDimension: 64)
                XCTAssertNotNil(preview.makeCGImage())
                await restored.close()
                await session.close()
            }
        }
        XCTAssertEqual(try Data(contentsOf: reference), before)
    }

    func testProbeReadsRoleFilterAndExposure() throws {
        let url = try SyntheticFrame.write(
            width: 160, height: 128,
            values: SyntheticFrame.starField(width: 160, height: 128),
            cards: SyntheticFrame.lightCards(filter: "Ha", exposureSeconds: 30))
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = try CalibrationService.probe(path: url.path)
        XCTAssertEqual(probe.role, "light")
        XCTAssertFalse(probe.isMaster)
        XCTAssertEqual(probe.signature.filter, "Ha")
        XCTAssertEqual(probe.signature.exposureSeconds, 30)
        XCTAssertEqual(probe.signature.width, 160)
        XCTAssertEqual(probe.signature.gain, 100)
        XCTAssertTrue(probe.calibrationState.isRaw)
    }

    func testLiveSessionRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("seiza-live-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let values = SyntheticFrame.starField(width: 160, height: 128)
        let reference = try SyntheticFrame.write(
            width: 160, height: 128, values: values,
            cards: SyntheticFrame.lightCards(), directory: directory,
            name: "light-001.fits")
        let second = try SyntheticFrame.write(
            width: 160, height: 128, values: values,
            cards: SyntheticFrame.lightCards(), directory: directory,
            name: "light-002.fits")

        // Byte-identical synthetic frames have no usable normalization
        // dispersion, so this round trip stacks unnormalized like the
        // directory-stack boundary test.
        var options = ImageStackOptions()
        options.normalization = .none
        options.rejection = .none
        let optionsJSON = String(decoding: try options.jsonData, as: UTF8.self)
        let session = try LiveStackNativeSession.open(
            referencePath: reference.path,
            optionsJSON: optionsJSON,
            calibration: ImageStackCalibration())

        var counts = try await session.counts()
        XCTAssertEqual(counts.acceptedFrames, 1)

        let outcome = try await session.push(path: second.path)
        let disposition = try XCTUnwrap(outcome.disposition)
        XCTAssertTrue(disposition.accepted, disposition.reason ?? "")
        counts = try await session.counts()
        XCTAssertEqual(counts.acceptedFrames, 2)

        let state = try await session.state()
        XCTAssertEqual(state.acceptedFrames, 2)
        XCTAssertEqual(state.inputPaths.count, 2)
        XCTAssertEqual(state.configurationFingerprint.count, 64)

        // A bounded preview renders from the live accumulator.
        let preview = try await session.renderPreview(
            configJSON: LiveStackRunConfiguration.defaultPreviewProcessingJSON,
            maxDimension: 64)
        XCTAssertEqual(preview.rgba.count, preview.width * preview.height * 4)
        XCTAssertNotNil(preview.makeCGImage())

        // Depth measurement is allowed to answer "cannot measure" on a tiny
        // synthetic frame, but it must not fail.
        _ = try await session.measureDepth()

        // A checkpoint context round-trips into an equivalent stacker.
        let contextURL = directory.appendingPathComponent("checkpoint.seiza-stack")
        let savedState = try await session.saveContext(to: contextURL.path)
        XCTAssertTrue(savedState.describesSameCheckpoint(state))
        let resumed = try LiveStackNativeSession.resume(contextPath: contextURL.path)
        let resumedState = try await resumed.state()
        XCTAssertTrue(savedState.describesSameCheckpoint(resumedState))
        await resumed.close()

        // A non-destructive export leaves the session usable.
        let exportURL = directory.appendingPathComponent("snapshot.fits")
        let export = try await session.exportSnapshot()
        XCTAssertEqual(export.acceptedFrames, 2)
        try export.writeFITS(to: exportURL.path)
        export.free()
        let exportSize = try FileManager.default.attributesOfItem(
            atPath: exportURL.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(exportSize, 0)

        // Frames pushed from files can be integrated again. The result is a
        // separate snapshot and leaves the live stacker usable.
        XCTAssertNil(state.reintegrationUnavailable)
        let steps = ReintegrationSteps()
        let reintegrated = try await session.reintegrate(
            lowSigma: 0, highSigma: 0
        ) { step in
            steps.append(step)
        }
        XCTAssertEqual(reintegrated.acceptedFrames, 2)
        let reintegratedURL = directory.appendingPathComponent("reintegrated.fits")
        try reintegrated.writeFITS(to: reintegratedURL.path)
        reintegrated.free()
        let reintegratedSize = try FileManager.default.attributesOfItem(
            atPath: reintegratedURL.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(reintegratedSize, 0)
        let recorded = steps.all
        XCTAssertEqual(recorded.first?.pass, 0)
        XCTAssertEqual(recorded.last?.pass, 2)
        XCTAssertTrue(recorded.allSatisfy { $0.count == 2 })
        counts = try await session.counts()
        XCTAssertEqual(counts.acceptedFrames, 2)

        // Finishing consumes the session and writes the final stack.
        let outputURL = directory.appendingPathComponent("final.fits")
        let snapshot = try await session.finish()
        XCTAssertEqual(snapshot.acceptedFrames, 2)
        try snapshot.writeFITS(to: outputURL.path)
        snapshot.free()
        let finalSize = try FileManager.default.attributesOfItem(
            atPath: outputURL.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(finalSize, 0)
    }
}

private final class ReintegrationSteps: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [LiveStackReintegrationProgress] = []

    func append(_ step: LiveStackReintegrationProgress) {
        lock.withLock { steps.append(step) }
    }

    var all: [LiveStackReintegrationProgress] {
        lock.withLock { steps }
    }
}

// MARK: - Native state decoding

final class LiveStackNativeStateDecodingTests: XCTestCase {
    private func stateJSON(_ extra: String = "") -> Data {
        let fingerprint = String(repeating: "ab", count: 32)
        let json = """
            {"schemaVersion":1,"coreVersion":"0.18.18",
            "configurationFingerprint":"\(fingerprint)",
            "width":160,"height":128,"channels":1,
            "acceptedFrames":2,"rejectedFrames":0,
            "inputMode":"calibrate-and-prepare",
            "inputPaths":["/a.fits","/b.fits"]\(extra)}
            """
        return Data(json.utf8)
    }

    func testReadsTheReintegrationReason() throws {
        let state = try JSONDecoder().decode(
            LiveStackNativeState.self,
            from: stateJSON(",\"reintegrationUnavailable\":\"Saved by an older Seiza.\""))
        XCTAssertEqual(state.reintegrationUnavailable, "Saved by an older Seiza.")
        XCTAssertTrue(state.isValidFromCore)
    }

    func testNullAndMissingReasonsMeanReplayable() throws {
        let explicit = try JSONDecoder().decode(
            LiveStackNativeState.self,
            from: stateJSON(",\"reintegrationUnavailable\":null"))
        XCTAssertNil(explicit.reintegrationUnavailable)
        // Manifests written before the field existed still decode.
        let old = try JSONDecoder().decode(LiveStackNativeState.self, from: stateJSON())
        XCTAssertNil(old.reintegrationUnavailable)
        XCTAssertTrue(old.isValidFromCore)
    }

    func testTheReasonDoesNotAffectCheckpointIdentity() throws {
        let old = try JSONDecoder().decode(LiveStackNativeState.self, from: stateJSON())
        let current = try JSONDecoder().decode(
            LiveStackNativeState.self,
            from: stateJSON(",\"reintegrationUnavailable\":\"Frames were supplied as pixels.\""))
        XCTAssertTrue(old.describesSameCheckpoint(current))
        XCTAssertTrue(current.describesSameCheckpoint(old))
    }

    func testEmptyStateRequiresAnExternalReferenceAndReferenceRolesMatchOnRestore() throws {
        let old = try JSONDecoder().decode(LiveStackNativeState.self, from: stateJSON())
        var shared = old
        shared.acceptedFrames = 0
        XCTAssertFalse(shared.isValidFromCore)
        shared.referenceIntegrated = false
        XCTAssertFalse(shared.isValidFromCore)
        shared.referenceImagePath = "/shared.fits"
        XCTAssertTrue(shared.isValidFromCore)
        var other = shared
        other.referenceImagePath = "/another.fits"
        XCTAssertFalse(shared.describesSameCheckpoint(other))
        other = shared
        other.referenceIntegrated = true
        XCTAssertFalse(other.isValidFromCore)
        XCTAssertFalse(shared.describesSameCheckpoint(other))
        shared.acceptedFrames = old.acceptedFrames
        XCTAssertFalse(old.describesSameCheckpoint(shared))
    }
}

// MARK: - Target selection tolerance

final class CalibrationTargetSelectionTests: XCTestCase {
    func testIneligibleFramesAreSetAsideWithAWarningNotRefused() {
        var master = CalibrationFrameProbe(path: "/frames/master.fits", role: "light")
        master.isMaster = true
        var preprocessed = CalibrationFrameProbe(
            path: "/frames/processed.fits", role: "light")
        preprocessed.calibrationState.darkSubtracted = true
        let flat = CalibrationFrameProbe(path: "/frames/flat.fits", role: "flat")
        let light = CalibrationFrameProbe(path: "/frames/light.fits", role: "light")

        let partition = CalibrationTargetSelection.partition(
            [master, preprocessed, flat, light])
        XCTAssertEqual(partition.eligible.map(\.path), ["/frames/light.fits"])
        XCTAssertEqual(partition.warnings.count, 3)
        XCTAssertTrue(partition.warnings[0].contains("master.fits"))
        XCTAssertTrue(partition.warnings[0].contains("already a master"))
        XCTAssertTrue(partition.warnings[1].contains("already preprocessed"))
        XCTAssertTrue(partition.warnings[2].contains("not a light frame"))
    }

    func testAnAllEligibleGroupProducesNoWarnings() {
        let lights = (1...3).map {
            CalibrationFrameProbe(path: "/frames/light-\($0).fits", role: "light")
        }
        let partition = CalibrationTargetSelection.partition(lights)
        XCTAssertEqual(partition.eligible.count, 3)
        XCTAssertTrue(partition.warnings.isEmpty)
    }
}

final class LiveStackReferenceScanTests: XCTestCase {
    func testReferenceScanSkipsMastersAndPreprocessedFrames() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("seiza-reference-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let values = SyntheticFrame.starField(width: 160, height: 128)
        // Oldest first: a declared master, then a preprocessed light, then
        // an unreadable file, then the raw light the scan should anchor on.
        _ = try SyntheticFrame.write(
            width: 160, height: 128, values: values,
            cards: ["SEIZAMST= 'LIGHT'"] + SyntheticFrame.lightCards(),
            directory: directory, name: "a-master.fits")
        _ = try SyntheticFrame.write(
            width: 160, height: 128, values: values,
            cards: ["BIASSUB =                    T"] + SyntheticFrame.lightCards(),
            directory: directory, name: "b-processed.fits")
        try Data("not a fits file".utf8).write(
            to: directory.appendingPathComponent("c-truncated.fits"))
        let raw = try SyntheticFrame.write(
            width: 160, height: 128, values: values,
            cards: SyntheticFrame.lightCards(),
            directory: directory, name: "d-light.fits")

        let reference = try LiveStackWindowModel.findReferenceLight(
            inFolder: directory.path, includeSubdirectories: false)
        XCTAssertEqual(reference?.path, LiveStackPath.normalize(raw.path))
        XCTAssertEqual(reference?.role, "light")
        XCTAssertEqual(reference?.isMaster, false)
    }
}

// MARK: - Calibration preparation end to end

final class CalibrationPreparationServiceTests: XCTestCase {
    private func sensorCards() -> [String] {
        [
            "INSTRUME= 'SyntheticCam'",
            "GAIN    =                  100",
            "OFFSET  =                   50",
            "XBINNING=                    1",
            "YBINNING=                    1",
        ]
    }

    private func noisyField(seed: UInt64) -> [Int16] {
        var state = seed
        return SyntheticFrame.starField(width: 160, height: 128).map { value in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Int16(truncatingIfNeeded: Int(state >> 33) % 21 - 10)
            return value &+ noise
        }
    }

    func testPreparesMastersInDependencyOrderAndReusesTheCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("seiza-calibration-\(UUID().uuidString)")
        let library = root.appendingPathComponent("library")
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(
            at: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var seed: UInt64 = 1
        func write(_ name: String, cards: [String]) throws {
            seed += 1
            _ = try SyntheticFrame.write(
                width: 160, height: 128, values: noisyField(seed: seed),
                cards: cards, directory: library, name: name)
        }
        for index in 1...2 {
            try write("bias-\(index).fits", cards: ["IMAGETYP= 'BIAS'"] + sensorCards())
            try write(
                "dark-\(index).fits",
                cards: [
                    "IMAGETYP= 'DARK'",
                    "EXPTIME =                 30.0",
                ] + sensorCards())
            try write(
                "darkflat-\(index).fits",
                cards: [
                    "IMAGETYP= 'DARKFLAT'",
                    "EXPTIME =                  2.0",
                ] + sensorCards())
            try write(
                "flat-\(index).fits",
                cards: [
                    "IMAGETYP= 'FLAT'",
                    "FILTER  = 'Ha'",
                    "EXPTIME =                  2.0",
                ] + sensorCards())
        }

        let light = try SyntheticFrame.write(
            width: 160, height: 128,
            values: SyntheticFrame.starField(width: 160, height: 128),
            cards: SyntheticFrame.lightCards(filter: "Ha", exposureSeconds: 30),
            directory: root, name: "light-001.fits")
        let reference = try CalibrationService.probe(path: light.path)

        let service = CalibrationPreparationService()
        let request = CalibrationPreparationRequest(
            reference: reference,
            sourcePaths: [library.path],
            cacheDirectory: cache)

        let first = try await service.prepare(request)
        defer { first.release() }
        XCTAssertNotNil(
            first.calibration.bias, first.warnings.joined(separator: " | "))
        XCTAssertNotNil(first.calibration.dark)
        XCTAssertNotNil(first.calibration.flat)
        for kind in ["bias", "dark", "dark-flat", "flat"] {
            let summary = try XCTUnwrap(
                first.summaries.first { $0.kind == kind }, kind)
            let masterPath = try XCTUnwrap(summary.masterPath, kind)
            XCTAssertTrue(FileManager.default.fileExists(atPath: masterPath), kind)
            XCTAssertFalse(summary.cacheReused, kind)
            XCTAssertEqual(summary.fingerprint?.count, 64, kind)
            let build = try XCTUnwrap(summary.build, kind)
            XCTAssertEqual(build.kind, kind)
            XCTAssertEqual(build.inputFrames, 2, kind)
        }
        // The flat's pedestal comes from the dark-flat, not the 30 s dark.
        let flat = try XCTUnwrap(first.summaries.first { $0.kind == "flat" })
        XCTAssertTrue(flat.build?.biasSubtracted ?? false)
        XCTAssertTrue(flat.build?.normalized ?? false)

        // A second preparation over the unchanged library reuses every master.
        let second = try await service.prepare(request)
        defer { second.release() }
        for kind in ["bias", "dark", "dark-flat", "flat"] {
            let summary = try XCTUnwrap(
                second.summaries.first { $0.kind == kind }, kind)
            XCTAssertTrue(summary.cacheReused, kind)
        }
        XCTAssertEqual(first.calibration.flat, second.calibration.flat)
        XCTAssertFalse(second.reviewNotes.contains { $0.hasPrefix("Flat quality:") })
        var reviewedRequest = request
        reviewedRequest.options.flatQuality.enabled = true
        let reviewed = try await service.prepare(reviewedRequest)
        defer { reviewed.release() }
        XCTAssertTrue(reviewed.reviewNotes.contains { $0.hasPrefix("Flat quality: 2 frames reviewed;") }, "\(reviewed.reviewNotes)")
        XCTAssertFalse(reviewed.warnings.contains { $0.contains("review could not be completed") })
        let structured = try XCTUnwrap(reviewed.flatQualityReviews.first)
        XCTAssertEqual(structured.paths.count, 2)
        XCTAssertEqual(structured.report.frames.count, 2)
        XCTAssertFalse(structured.dustNotes.contains { $0.hasPrefix("Flat quality:") })

        XCTAssertEqual(reviewed.calibration.flat, second.calibration.flat, "Review must not change frame selection or cache identity")
        XCTAssertTrue(try XCTUnwrap(reviewed.summaries.first { $0.kind == "flat" }).cacheReused)
        let summary = await LiveStackWindowModel.describeCalibration(reviewed)
        XCTAssertTrue(summary.contains("Flat quality: 2 frames reviewed;"))
        XCTAssertFalse(summary.contains("Dust detections across all frames:"), "Keep the full report in its review sheet")
    }

    func testAnIneligibleTargetIsRejectedBeforeAnyWork() async {
        var master = CalibrationFrameProbe(path: "/frames/master.fits", role: "light")
        master.isMaster = true
        let service = CalibrationPreparationService()
        let request = CalibrationPreparationRequest(
            reference: master,
            sourcePaths: ["/frames"],
            cacheDirectory: FileManager.default.temporaryDirectory)
        do {
            _ = try await service.prepare(request)
            XCTFail("an ineligible reference must be rejected")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("already a master"),
                error.localizedDescription)
        }
    }

    func testWarningTextDeduplicatesAndCapsAtTwelve() {
        let warnings = (0..<20).map { "warning \($0)" } + ["warning 0"]
        let text = CalibrationPreparationWarningText.format(warnings)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 13)
        XCTAssertEqual(lines.last, "…and 8 more warning(s).")
    }
}

// MARK: - Coordinator end to end

final class LiveStackCoordinatorTests: XCTestCase {
    func testChangingLivePreviewStretchDoesNotChangeTheLinearStack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let watch = root.appendingPathComponent("lights")
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let light = try SyntheticFrame.write(width: 160, height: 128,
            values: SyntheticFrame.noisyStarField(), cards: SyntheticFrame.lightCards(), directory: watch)
        var config = LiveStackRunConfiguration(watchFolder: watch.path,
            sessionRootDirectory: root.appendingPathComponent("sessions"))
        config.initialReferencePath = light.path
        config.monitorScanInterval = 3600
        let coordinator = try LiveStackCoordinator(configuration: config)
        try await coordinator.start()
        try await coordinator.pauseAndSave()
        let before = await coordinator.currentSnapshot()
        let original = root.appendingPathComponent("original.fits")
        _ = try await coordinator.saveSnapshot(to: original.path)
        for type in LiveStackRunConfiguration.previewStretchTypes {
            try await coordinator.setPreviewStretch(type)
            let snapshot = await coordinator.currentSnapshot()
            XCTAssertEqual(snapshot.acceptedFrames, before.acceptedFrames)
            XCTAssertGreaterThan(snapshot.previewRevision, before.previewRevision)
            XCTAssertNotNil(snapshot.preview)
        }
        let after = root.appendingPathComponent("after.fits")
        _ = try await coordinator.saveSnapshot(to: after.path)
        XCTAssertEqual(try Data(contentsOf: original), try Data(contentsOf: after))
        await coordinator.dispose()
    }

    func testAutomaticReferenceFiltersCandidatesAndRestoresBeforeScoring() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let watch = root.appendingPathComponent("lights")
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, filter) in [("a.fits", "Ha"), ("b.fits", "Ha"), ("c.fits", "OIII")] {
            _ = try SyntheticFrame.write(width: 160, height: 128, values: SyntheticFrame.noisyStarField(),
                cards: SyntheticFrame.lightCards(filter: filter), directory: watch, name: name)
        }
        var config = LiveStackRunConfiguration(watchFolder: watch.path,
            sessionRootDirectory: root.appendingPathComponent("sessions"))
        config.choosesReferenceAutomatically = true
        config.monitorStabilityDuration = 0.01
        config.monitorScanInterval = 3600
        let coordinator = try LiveStackCoordinator(configuration: config, referenceSelector: { urls in
            XCTAssertEqual(urls.map(\.lastPathComponent), ["a.fits", "b.fits"])
            return try StackReferenceSelector.choose(urls)
        })
        try await coordinator.start()
        let first = await coordinator.currentSnapshot()
        XCTAssertEqual(first.acceptedFrames, 1)
        XCTAssertEqual(first.filter?.key, "hydrogen-alpha")
        try await coordinator.pauseAndSave()
        await coordinator.dispose()
        let restored = try LiveStackCoordinator(configuration: config, referenceSelector: { _ in
            XCTFail("A restored stack must not score a new reference")
            throw CancellationError()
        })
        try await restored.start()
        let resumed = await restored.currentSnapshot()
        XCTAssertEqual(resumed.acceptedFrames, 1)
        await restored.dispose()
    }

    func testChangedAutomaticReferenceFallsBackToWatching() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let light = try SyntheticFrame.write(width: 160, height: 128, values: SyntheticFrame.noisyStarField(),
            cards: SyntheticFrame.lightCards(), directory: root)
        var config = LiveStackRunConfiguration(watchFolder: root.path,
            sessionRootDirectory: root.appendingPathComponent("sessions"))
        config.choosesReferenceAutomatically = true
        config.monitorStabilityDuration = 0.01
        config.monitorScanInterval = 3600
        let coordinator = try LiveStackCoordinator(configuration: config, referenceSelector: { urls in
            let result = try StackReferenceSelector.choose(urls)
            var changed = try Data(contentsOf: light)
            changed.append(0)
            try changed.write(to: light)
            return result
        })
        try await coordinator.start()
        let snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.acceptedFrames, 0)
        XCTAssertEqual(snapshot.state, .waitingForLight)
        XCTAssertTrue(snapshot.attention.contains { $0.message.contains("changed during scoring") })
        await coordinator.dispose()
    }

    func testMonitorExclusionsCoverMastersButNotTheInitialReference() throws {
        var configuration = LiveStackRunConfiguration(
            watchFolder: "/captures",
            sessionRootDirectory: URL(fileURLWithPath: "/tmp/sessions"))
        configuration.initialReferencePath = "/captures/reference.fits"
        configuration.calibration = ImageStackCalibration(
            bias: URL(fileURLWithPath: "/masters/bias.fits"),
            dark: URL(fileURLWithPath: "/masters/dark.fits"))
        let excluded = configuration.monitorExcludedPaths()
        XCTAssertEqual(excluded.count, 2)
        XCTAssertFalse(excluded.contains("/captures/reference.fits"))
    }

    func testLiveRunAcceptsCheckpointsResumesAndFinishes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("seiza-live-e2e-\(UUID().uuidString)")
        let watch = root.appendingPathComponent("captures")
        let sessions = root.appendingPathComponent("sessions")
        let output = root.appendingPathComponent("stack.fits")
        try FileManager.default.createDirectory(
            at: watch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let values = SyntheticFrame.starField(width: 160, height: 128)
        _ = try SyntheticFrame.write(
            width: 160, height: 128, values: values,
            cards: SyntheticFrame.lightCards(), directory: watch,
            name: "light-001.fits")

        var configuration = LiveStackRunConfiguration(
            watchFolder: watch.path,
            sessionRootDirectory: sessions)
        configuration.resumeExisting = false
        configuration.monitorScanInterval = 0.15
        configuration.monitorStabilityDuration = 0.1
        // Byte-identical synthetic frames have no usable normalization
        // dispersion; the lifecycle under test does not depend on it.
        configuration.options.normalization = .none
        configuration.options.rejection = .none

        let coordinator = try LiveStackCoordinator(configuration: configuration)
        try await coordinator.start()
        try await waitUntil("the reference is accepted") {
            await coordinator.currentSnapshot().acceptedFrames == 1
        }

        _ = try SyntheticFrame.write(
            width: 160, height: 128, values: values,
            cards: SyntheticFrame.lightCards(), directory: watch,
            name: "light-002.fits")
        try await waitUntil("the second light is accepted") {
            await coordinator.currentSnapshot().acceptedFrames == 2
        }

        // A calibration frame arriving in the folder is ignored, not stacked.
        _ = try SyntheticFrame.write(
            width: 160, height: 128, values: values,
            cards: ["IMAGETYP= 'FLAT'"], directory: watch,
            name: "flat-001.fits")
        try await waitUntil("the flat is ignored") {
            await coordinator.currentSnapshot().ignoredFrames == 1
        }
        var snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.acceptedFrames, 2)
        XCTAssertEqual(snapshot.filter?.key, "hydrogen-alpha")

        try await coordinator.pauseAndSave()
        snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.state, .paused)
        XCTAssertNotNil(snapshot.checkpointGeneration)
        await coordinator.dispose()

        // A new coordinator resumes the checkpoint exactly.
        var resumeConfiguration = configuration
        resumeConfiguration.resumeExisting = true
        let resumed = try LiveStackCoordinator(configuration: resumeConfiguration)
        try await resumed.start()
        try await waitUntil("the restored stack is watching") {
            let current = await resumed.currentSnapshot()
            return current.acceptedFrames == 2 && current.state == .watching
        }

        // A third light joins the restored accumulator.
        _ = try SyntheticFrame.write(
            width: 160, height: 128, values: values,
            cards: SyntheticFrame.lightCards(), directory: watch,
            name: "light-003.fits")
        try await waitUntil("the third light is accepted") {
            await resumed.currentSnapshot().acceptedFrames == 3
        }

        let result = try await resumed.finish(to: output.path)
        XCTAssertEqual(result.acceptedFrames, 3)
        let size = try FileManager.default.attributesOfItem(
            atPath: output.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 0)
        snapshot = await resumed.currentSnapshot()
        XCTAssertEqual(snapshot.state, .completed)
        await resumed.dispose()
    }

    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(30),
        condition: () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for \(description)")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

// MARK: - Published 0.34 flat-quality bridge

final class FlatQualityTests: XCTestCase {
    func testCopiedReviewIncludesFindingsBeyondFiftyFlaggedFlats() {
        let verdict = FlatQualityReport.Verdict(grade: "poor", findings: [
            .init(code: "clipped", grade: "poor", value: 0.08, limit: 0.01)
        ])
        let paths = (1...52).map { "/flats/flat-\($0).fits" }
        let report = FlatQualityReport(schemaVersion: 1, frames: Array(repeating: verdict, count: paths.count),
            master: .init(grade: "ok", findings: []), steadyFeatures: 0, changingFeatures: 0, carriedFeatures: 0)
        let review = FlatQualityReview(paths: paths, measurements: [], report: report)
        let copied = review.notes.joined(separator: "\n\n")
        XCTAssertTrue(copied.contains("flat-1.fits (poor): Clipped pixels: 8.00% (limit 1.00%)"))
        XCTAssertTrue(copied.contains("flat-52.fits (poor): Clipped pixels: 8.00% (limit 1.00%)"))
        XCTAssertEqual(review.notes.filter { $0.hasPrefix("flat-") }.count, 52)
        XCTAssertFalse(copied.contains("additional flagged flats"))
    }

    func testReviewSeparatesFrameIssuesFromDustDetails() throws {
        let json = #"{"schemaVersion":1,"frames":[{"grade":"ok","findings":[]},{"grade":"suspect","findings":[{"code":"dim","grade":"suspect","value":0.0381,"limit":0.1}]},{"grade":"poor","findings":[{"code":"clipped","grade":"poor","value":0.2,"limit":0.01}]}],"master":{"grade":"suspect","findings":[]},"steadyFeatures":2,"changingFeatures":1,"carriedFeatures":1}"#
        let report = try JSONDecoder().decode(FlatQualityReport.self, from: Data(json.utf8))
        let review = FlatQualityReview(paths: ["/flats/good.fits", "/flats/dim.fits", "/flats/clipped.fits"], measurements: [], report: report)
        XCTAssertEqual(review.suspectCount, 1)
        XCTAssertEqual(review.poorCount, 1)
        XCTAssertEqual(review.flaggedIndices, [1, 2])
        XCTAssertEqual(review.filename(at: 1), "dim.fits")
        XCTAssertTrue(review.notes.contains { $0.contains("3.81%") })
        XCTAssertTrue(review.notes.contains { $0.contains("Combined master") })
        XCTAssertFalse(review.dustNotes.contains { $0.contains("dim.fits") || $0.contains("Combined master") })
        XCTAssertTrue(review.dustNotes.contains { $0.contains("2 steady, 1 changing") })
    }

    func testOptionsRequireCompleteGeometryOnlyWhenEnabled() throws {
        var options = FlatQualityOptions()
        options.fullScale = 0; options.useOptics = true
        XCTAssertNil(options.validationMessage)
        options.enabled = true
        XCTAssertNotNil(options.validationMessage)
        options.fullScale = 65535
        XCTAssertNotNil(options.validationMessage)
        options.focalRatio = 5; options.pixelSizeUm = 3.76
        XCTAssertNil(options.validationMessage)
        options.obstruction = 1
        XCTAssertNotNil(options.validationMessage)
        options.useOptics = false
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            FlatQualityMeasureRequest(path: "/flat.fits", options: options))) as! [String: Any]
        XCTAssertNil(object["focalRatio"]); XCTAssertNil(object["pixelSizeUm"]); XCTAssertNil(object["obstruction"])
        XCTAssertEqual(object["largeFeatures"] as? Bool, true)
    }

    func testNativeMeasurementPreservesDustGeometryAndScreening() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flat-quality-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let width = 256, height = 256
        // Keep fixture arithmetic simple for Xcode 16's type checker.
        var values: [Int16] = []
        values.reserveCapacity(width * height)
        for i in 0..<(width * height) {
            let x: Int = i % width
            let y: Int = i / width
            let dx: Int = x - 128
            let dy: Int = y - 128
            let radiusSquared: Int = dx * dx + dy * dy
            let shadow: Int = radiusSquared < 35 * 35 ? 800 : 0
            let noise: Int = i % 11 - 5
            let sample: Int = 40000 - 32768 - shadow + noise
            values.append(Int16(sample))
        }
        let file = try SyntheticFrame.write(width: width, height: height, values: values,
            cards: ["IMAGETYP= 'FLAT'"], directory: directory, name: "dust-disk.fits")
        var options = FlatQualityOptions()
        options.enabled = true; options.useOptics = true; options.focalRatio = 5; options.pixelSizeUm = 3.76
        let measured = try CalibrationService.measureFlat(FlatQualityMeasureRequest(path: file.path, options: options))
        XCTAssertEqual(measured.algorithmVersion, 2)
        XCTAssertEqual(measured.width, width); XCTAssertEqual(measured.height, height)
        XCTAssertEqual(measured.fullScale, 65535)
        let disk = try XCTUnwrap(measured.features.first { $0.shape == "disk" })
        XCTAssertEqual(disk.x, 128, accuracy: 5); XCTAssertEqual(disk.y, 128, accuracy: 5)
        XCTAssertGreaterThan(try XCTUnwrap(disk.distanceMm), 1)
        XCTAssertLessThan(try XCTUnwrap(disk.distanceMm), 2)
        let kept = try JSONDecoder().decode(FlatQualityMeasurement.self, from: JSONEncoder().encode(measured))
        XCTAssertEqual(kept.features.first { $0.shape == "disk" }?.distanceMm, disk.distanceMm)
        let report = try CalibrationService.screenFlats([kept, kept, kept])
        XCTAssertEqual(report.frames.count, 3)
        XCTAssertEqual(report.changingFeatures, 0)
        XCTAssertEqual(report.carriedFeatures, 0)
        let notes = report.reviewNotes(paths: [file.path, file.path, file.path], measurements: [kept, kept, kept])
        XCTAssertTrue(notes.contains { $0.contains("disk:") })
        XCTAssertTrue(notes.contains { $0.contains("Vignetting regions") })
        XCTAssertTrue(notes.contains { $0.contains("mm in front of the sensor") })
        XCTAssertTrue(notes.contains { $0.contains("selection is unchanged") })
        var wrongSize = kept; wrongSize.width = width + 1
        XCTAssertThrowsError(try CalibrationService.screenFlats([kept, wrongSize]))
        options.fullScale = 0
        XCTAssertThrowsError(try CalibrationService.measureFlat(FlatQualityMeasureRequest(path: file.path, options: options)))
    }
}

final class LiveStackFilterSessionTests: XCTestCase {
    private func setup() throws -> (URL, URL, LiveStackRunConfiguration) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let watch = root.appendingPathComponent("captures")
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        var config = LiveStackRunConfiguration(watchFolder: watch.path,
            sessionRootDirectory: root.appendingPathComponent("sessions"))
        config.includeSubdirectories = true
        config.monitorScanInterval = 0.02
        config.monitorStabilityDuration = 0.01
        config.checkpointAcceptedFrameInterval = 1
        config.maximumReadAttempts = 1
        return (root, watch, config)
    }
    private func light(_ name: String, filter: String?, in directory: URL) throws -> URL {
        var cards = SyntheticFrame.lightCards(filter: filter ?? "")
        if filter == nil { cards.removeAll { $0.hasPrefix("FILTER") } }
        return try SyntheticFrame.write(width: 160, height: 128,
            values: SyntheticFrame.noisyStarField(), cards: cards, directory: directory, name: name)
    }
    private func waitFor(_ session: LiveStackFilterSession,
                         _ condition: (LiveStackFilterSessionSnapshot) -> Bool) async throws -> LiveStackFilterSessionSnapshot {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let state = await session.currentSnapshot()
            if condition(state) { return state }
            try await Task.sleep(for: .milliseconds(20))
        }
        let state = await session.currentSnapshot()
        XCTFail("Timed out: \(state.status), groups: \(state.groups.map { "\($0.filter.key)=\($0.snapshot.acceptedFrames):\($0.snapshot.statusMessage)" })")
        throw CancellationError()
    }

    func testRecursiveGroupsFinishIndependentlyAndResumeWithoutSources() async throws {
        let (root, watch, config) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = watch.appendingPathComponent("night")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try light("first.fits", filter: "Ha", in: watch)
        _ = try light("second.fits", filter: "OIII", in: nested)
        _ = try light("unknown.fits", filter: nil, in: nested)
        let session = try LiveStackFilterSession(configuration: config)
        try await session.start()
        let state = try await waitFor(session) { $0.groups.count == 3 && $0.groups.allSatisfy { $0.snapshot.acceptedFrames == 1 } }
        XCTAssertEqual(Set(state.groups.map(\.id)), ["hydrogen-alpha", "oxygen-iii", "unfiltered"])
        try await session.setPreviewStretch(.layered)
        // Parent snapshots arrive through an AsyncStream; query the completed
        // child render rather than racing that stream's UI notification.
        let optionalReferenceChild = await session.coordinator(for: "unfiltered")
        let referenceChild = try XCTUnwrap(optionalReferenceChild)
        let referenceSnapshot = await referenceChild.currentSnapshot()
        let expectedPreview = try XCTUnwrap(referenceSnapshot.preview?.rgba)
        let other = try LiveStackFilterSession(configuration: config)
        do { try await other.start(); XCTFail("A second window must not own the registry") } catch {}
        await other.dispose()
        do {
            _ = try await session.saveSnapshot(for: "hydrogen-alpha", to: nested.appendingPathComponent("output.fits").path)
            XCTFail("Outputs inside the capture tree must be rejected")
        } catch {}
        let alias = root.appendingPathComponent("other-filter-alias.fits")
        try FileManager.default.linkItem(at: nested.appendingPathComponent("second.fits"), to: alias)
        do { _ = try await session.saveSnapshot(for: "hydrogen-alpha", to: alias.path); XCTFail("Other filters' input aliases are protected") } catch {}
        let registryAlias = root.appendingPathComponent("registry-alias.fits")
        try FileManager.default.linkItem(at: config.sessionRootDirectory.appendingPathComponent("filters.json"), to: registryAlias)
        do { _ = try await session.saveSnapshot(for: "hydrogen-alpha", to: registryAlias.path); XCTFail("Registry aliases are protected") } catch {}
        let output = root.appendingPathComponent("ha.fits")
        _ = try await session.finish("hydrogen-alpha", to: output.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        _ = try light("second-oxygen.fits", filter: "OIII", in: nested)
        _ = try light("new-sulfur.fits", filter: "SII", in: nested)
        _ = try light("later-ha.fits", filter: "Ha", in: nested)
        let expanded = try await waitFor(session) { state in
            state.groups.count == 4 && state.groups.first { $0.id == "oxygen-iii" }?.snapshot.acceptedFrames == 2
                && state.groups.first { $0.id == "sulfur-ii" }?.snapshot.acceptedFrames == 1
                && state.groups.first { $0.id == "sulfur-ii" }?.snapshot.preview != nil
        }
        XCTAssertEqual(expanded.groups.first { $0.id == "sulfur-ii" }?.snapshot.preview?.rgba, expectedPreview,
            "A newly discovered group inherits the session's current Layered preview")
        try await session.pauseAndSave()
        await session.dispose()
        try FileManager.default.removeItem(at: watch)
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        let resumed = try LiveStackFilterSession(configuration: config)
        try await resumed.start()
        let restored = try await waitFor(resumed) { state in
            state.groups.count == 4 && state.groups.first { $0.id == "oxygen-iii" }?.snapshot.acceptedFrames == 2
                && state.groups.first { $0.id == "unfiltered" }?.snapshot.acceptedFrames == 1
        }
        let completed = try XCTUnwrap(restored.groups.first { $0.id == "hydrogen-alpha" })
        XCTAssertTrue(completed.completed)
        XCTAssertEqual(completed.snapshot.acceptedFrames, 1)
        XCTAssertEqual(completed.outputPath, output.path)
        try await resumed.pauseAndSave()
        await resumed.dispose()
    }

    func testCalibrationFailureIsIsolatedToItsFilter() async throws {
        actor Attempts {
            var count = 0
            func record() { count += 1 }
        }
        let (root, watch, originalConfig) = try setup()
        var config = originalConfig
        config.choosesReferenceAutomatically = true
        let attempts = Attempts()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try light("a.fits", filter: "Ha", in: watch)
        _ = try light("b.fits", filter: "OIII", in: watch)
        let session = try LiveStackFilterSession(configuration: config) { probe in
            if LiveStackFilterIdentity.fromProbe(probe).key == "oxygen-iii" {
                await attempts.record()
                throw LiveStackRunError.invalidConfiguration("Test calibration failure for oxygen")
            }
            return ImageStackCalibration()
        }
        try await session.start()
        let state = try await waitFor(session) { state in
            state.groups.first { $0.id == "hydrogen-alpha" }?.snapshot.acceptedFrames == 1
                && state.groups.first { $0.id == "oxygen-iii" }?.snapshot.state == .faulted
        }
        XCTAssertEqual(state.groups.first { $0.id == "oxygen-iii" }?.snapshot.acceptedFrames, 0)
        XCTAssertEqual(state.groups.first { $0.id == "oxygen-iii" }?.snapshot.unreadableFrames, 0)
        XCTAssertTrue(state.groups.first { $0.id == "oxygen-iii" }?.snapshot.attention.contains {
            $0.message.contains("Test calibration failure")
        } ?? false)
        let count = await attempts.count
        XCTAssertEqual(count, 1, "Automatic reference selection must not retry a calibration failure through first-light fallback")
        try await session.pauseAndSave()
        await session.dispose()
    }

    @MainActor
    func testPauseAndCloseSuppressQueuedCalibrationReviews() async throws {
        for close in [false, true] {
            let (root, watch, _) = try setup()
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try light("ha.fits", filter: "Ha", in: watch)
            _ = try light("oxygen.fits", filter: "OIII", in: watch)
            let library = root.appendingPathComponent("empty-library")
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            let model = LiveStackWindowModel(initialFolder: watch)
            model.separatesFilters = true
            model.calibrationMode = .automatic
            model.calibrationLibrary = library
            var closed = false
            model.requestClose = { closed = true }
            model.start()
            let reviewDeadline = Date().addingTimeInterval(15)
            while model.pendingWarnings == nil, Date() < reviewDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNotNil(model.pendingWarnings, "The first filter should request calibration review")
            if close { XCTAssertFalse(model.canCloseImmediately()) }
            else { model.pauseOrResume() }
            let stopDeadline = Date().addingTimeInterval(5)
            while !(close ? closed : model.allFiltersPaused && !model.isBusy), Date() < stopDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNil(model.pendingWarnings, "A queued filter must not open another review while stopping")
            if close { XCTAssertTrue(closed) }
            else {
                XCTAssertTrue(model.allFiltersPaused)
                XCTAssertFalse(model.isBusy)
                _ = model.canCloseImmediately()
            }
            // Drain a review if the assertion failed, so regression failures
            // cannot leave a native operation/lease waiting in the test app.
            model.resolveWarnings(proceed: false)
            let closeDeadline = Date().addingTimeInterval(5)
            while !closed, Date() < closeDeadline {
                model.resolveWarnings(proceed: false)
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    func testCancelledCalibrationPausesOnlyThatFilterWithoutRetryingReview() async throws {
        actor Attempts {
            var count = 0
            func record() { count += 1 }
        }
        let (root, watch, originalConfig) = try setup()
        var config = originalConfig
        config.choosesReferenceAutomatically = true
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try light("a.fits", filter: "Ha", in: watch)
        _ = try light("b.fits", filter: "OIII", in: watch)
        let attempts = Attempts()
        let session = try LiveStackFilterSession(configuration: config) { probe in
            if LiveStackFilterIdentity.fromProbe(probe).key == "oxygen-iii" {
                await attempts.record()
                throw CancellationError()
            }
            return ImageStackCalibration()
        }
        try await session.start()
        let state = try await waitFor(session) { state in
            state.groups.first { $0.id == "hydrogen-alpha" }?.snapshot.acceptedFrames == 1
                && state.groups.first { $0.id == "oxygen-iii" }?.snapshot.state == .paused
        }
        let oxygen = try XCTUnwrap(state.groups.first { $0.id == "oxygen-iii" })
        XCTAssertEqual(oxygen.snapshot.unreadableFrames, 0)
        XCTAssertEqual(oxygen.snapshot.acceptedFrames, 0)
        XCTAssertTrue(oxygen.snapshot.attention.contains { $0.message.contains("cancelled") })
        try await Task.sleep(for: .milliseconds(100))
        let count = await attempts.count
        XCTAssertEqual(count, 1)
        try await session.pauseAndSave()
        await session.dispose()
    }

    func testRegistryRejectsUnsupportedOrInconsistentIdentity() async throws {
        let (root, _, config) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: config.sessionRootDirectory, withIntermediateDirectories: true)
        let registry = config.sessionRootDirectory.appendingPathComponent("filters.json")
        let data = Data("{\"schemaVersion\":1,\"filters\":[{\"name\":\"Ha\",\"key\":\"oxygen-iii\",\"completed\":false,\"acceptedFrames\":0}]}".utf8)
        try data.write(to: registry)
        let session = try LiveStackFilterSession(configuration: config)
        do { try await session.start(); XCTFail("An inconsistent filter identity must fail") } catch {}
        await session.dispose()
    }
}
