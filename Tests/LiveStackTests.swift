import XCTest

@testable import Seiza

// MARK: - Synthetic frames

/// Writes a BITPIX 16 FITS file with typed header cards, so the native
/// probe classifies roles and signatures the way real capture software's
/// output would.
enum SyntheticFrame {
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
