import XCTest

@testable import Seiza

final class CalibrationParityTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Case: Decodable {
            struct Frame: Decodable {
                var name: String
                var kind: String
                var gain: Int
                var measurement: DarkQualityMeasurement
                var grade: String
                var gradeCode: String?
            }
            var name: String
            var frames: [Frame]
            var assignments: [Int]
            var sessionCount: Int
            var reorderedIdentityEqual: Bool
        }
        var psfGuardRevision: String
        var calibrationVersion: String
        var cases: [Case]
        struct FlatQuality: Decodable {
            var measurements: [FlatQualityMeasurement]
            var grades: [String]
            var gradeCodes: [String?]
        }
        var flatQuality: FlatQuality
    }

    func testNativeScreeningMatchesCapturedPSFGuardGrades() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "psf-guard", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.psfGuardRevision, "79f5e31d53b8371e8fcd0b22a9b69692412cd8b4")
        XCTAssertEqual(fixture.calibrationVersion, "0.8.1")
        for testCase in fixture.cases {
            for frames in Dictionary(grouping: testCase.frames, by: { "\($0.kind):\($0.gain)" }).values {
                let kind = try XCTUnwrap(frames.first).kind
                let measurements = frames.map(\.measurement)
                let report = try kind == "bias"
                    ? CalibrationService.screenBias(measurements)
                    : CalibrationService.screenDarks(measurements)
                XCTAssertEqual(report.frames.map(\.grade), frames.map(\.grade), testCase.name)
                for (actual, expected) in zip(report.frames, frames) {
                    if let code = expected.gradeCode {
                        XCTAssertTrue(actual.findings.contains { $0.code == code }, expected.name)
                    } else {
                        XCTAssertTrue(actual.findings.isEmpty, expected.name)
                    }
                }
                // Persisting and screening stored measurements must preserve all
                // native fields, including the algorithm version and hot count.
                let restored = try JSONDecoder().decode([DarkQualityMeasurement].self,
                    from: JSONEncoder().encode(measurements))
                XCTAssertEqual(restored, measurements)
            }
        }
        let gains = try XCTUnwrap(fixture.cases.first { $0.name == "different-gains" })
        XCTAssertEqual(gains.assignments, [0, 1, 0])
        XCTAssertEqual(gains.sessionCount, 2)
        XCTAssertTrue(gains.reorderedIdentityEqual)
        let flats = try CalibrationService.screenFlats(fixture.flatQuality.measurements)
        XCTAssertEqual(flats.frames.map(\.grade), fixture.flatQuality.grades)
        for (actual, code) in zip(flats.frames, fixture.flatQuality.gradeCodes) {
            if let code { XCTAssertTrue(actual.findings.contains { $0.code == code }) }
        }
        // Selections and overrides in the fixture are reference evidence for
        // the future shared planner, not assertions of current Mac parity.
    }

    func testDarkMeasurementUsesPhysicalADUAndCanBeRescreenedWithoutTheFile() throws {
        let url = try SyntheticFrame.write(width: 64, height: 64,
            values: (0..<4096).map { Int16(500 + $0 % 7 - 3 - 32768) },
            cards: ["IMAGETYP= 'BIAS'"])
        defer { try? FileManager.default.removeItem(at: url) }
        let measurement = try CalibrationService.measureDark(.init(path: url.path))
        XCTAssertEqual(measurement.width, 64)
        XCTAssertEqual(measurement.height, 64)
        XCTAssertEqual(measurement.level, 500, accuracy: 1)
        XCTAssertGreaterThan(measurement.noise, 0)
        XCTAssertGreaterThan(measurement.algorithmVersion, 0)
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(try CalibrationService.screenBias([measurement, measurement]).frames.map(\.grade), ["ok", "ok"])
        XCTAssertThrowsError(try CalibrationService.measureDark(.init(path: url.path)))
        XCTAssertTrue(try CalibrationService.screenDarks([]).frames.isEmpty)
    }

    func testInvalidHotSigmaIsRejectedByTheCore() throws {
        let url = try SyntheticFrame.write(width: 8, height: 8, values: .init(repeating: -32000, count: 64))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try CalibrationService.measureDark(.init(path: url.path, hotSigma: 0)))
    }
}

/// These tests exercise the published C ABI, independently of the batch
/// driver's current single-set behavior. Expanded planning below is deliberately
/// uncalibrated: it proves session integration/replay, not multi-session planning.
final class CalibrationSessionBoundaryTests: XCTestCase {
    private func check(_ operation: (inout UnsafeMutablePointer<CChar>?) -> Bool) throws {
        var failure: UnsafeMutablePointer<CChar>?
        let success = operation(&failure)
        let message = CalibrationService.takeOwnedError(&failure, fallback: "Native call failed")
        guard success else { throw CalibrationServiceError.core(message) }
    }

    private func push(_ handle: OpaquePointer, _ url: URL) throws -> ImageStackDisposition {
        var failure: UnsafeMutablePointer<CChar>?
        let response = url.path.withCString { seiza_live_stacker_push_fits_json(handle, $0, &failure) }
        guard let response else {
            throw CalibrationServiceError.core(CalibrationService.takeOwnedError(&failure, fallback: "Push failed"))
        }
        defer { seiza_string_free(response) }
        CalibrationService.discardError(&failure)
        return try JSONDecoder().decode(ImageStackDisposition.self,
            from: Data(bytes: response, count: strlen(response)))
    }

    private func pixels(_ snapshot: OpaquePointer) throws -> [Float] {
        Array(UnsafeBufferPointer(start: try XCTUnwrap(seiza_stack_snapshot_image(snapshot)),
            count: seiza_stack_snapshot_data_length(snapshot)))
    }

    private func snapshot(_ handle: OpaquePointer) throws -> OpaquePointer {
        var failure: UnsafeMutablePointer<CChar>?
        guard let value = seiza_live_stacker_snapshot(handle, &failure) else {
            throw CalibrationServiceError.core(CalibrationService.takeOwnedError(&failure, fallback: "Snapshot failed"))
        }
        CalibrationService.discardError(&failure)
        return value
    }

    private func state(_ handle: OpaquePointer) throws -> LiveStackNativeState {
        var failure: UnsafeMutablePointer<CChar>?
        guard let response = seiza_live_stacker_state_json(handle, &failure) else {
            throw CalibrationServiceError.core(CalibrationService.takeOwnedError(&failure, fallback: "State failed"))
        }
        defer { seiza_string_free(response) }
        CalibrationService.discardError(&failure)
        return try JSONDecoder().decode(LiveStackNativeState.self,
            from: Data(bytes: response, count: strlen(response)))
    }

    func testSessionsABAAndMeasuredRotationSurviveCheckpointAndReplayOnBothCanvases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let width = 160, height = 128
        let global = SyntheticFrame.noisyStarField(width: 200, height: height)
        func crop(_ offset: Int) -> [Int16] {
            (0..<height).flatMap { y in Array(global[(y * 200 + offset)..<(y * 200 + offset + width)]) }
        }
        func cards(_ kind: String, gain: Int, rotation: Int) -> [String] {
            SyntheticFrame.lightCards().filter { !$0.hasPrefix("IMAGETYP") && !$0.hasPrefix("GAIN") }
                + ["IMAGETYP= '\(kind)'", "GAIN    = \(gain)", "ROTATANG= \(rotation)"]
        }
        func light(_ name: String, gain: Int, bias: Int, rotation: Int) throws -> URL {
            try SyntheticFrame.write(width: width, height: height,
                values: crop(gain == 200 ? 20 : 0).map { Int16(Int($0) + bias - 32768) },
                cards: cards("LIGHT", gain: gain, rotation: rotation), directory: root, name: name)
        }
        func master(_ name: String, kind: String, gain: Int, value: Int, rotation: Int) throws -> URL {
            try SyntheticFrame.write(width: width, height: height,
                values: .init(repeating: Int16(value - 32768), count: width * height),
                cards: cards(kind, gain: gain, rotation: rotation) + (kind == "FLAT" ? ["FLATNORM=                    T"] : []),
                directory: root, name: name)
        }
        let a = try light("a.fits", gain: 100, bias: 500, rotation: 0)
        let b = try light("b.fits", gain: 200, bias: 1500, rotation: 40)
        let again = try light("a-again.fits", gain: 100, bias: 500, rotation: 0)
        let wrong = try light("wrong.fits", gain: 200, bias: 1500, rotation: 40)
        let wrongRotation = try light("wrong-rotation.fits", gain: 200, bias: 1500, rotation: 40)
        let biasA = try master("bias-a.fits", kind: "BIAS", gain: 100, value: 500, rotation: 0)
        let biasB = try master("bias-b.fits", kind: "BIAS", gain: 200, value: 1500, rotation: 90)
        let flatA = try master("flat-a.fits", kind: "FLAT", gain: 100, value: 1, rotation: 0)
        let flatB = try master("flat-b.fits", kind: "FLAT", gain: 200, value: 1, rotation: 90)
        let sources = [a, b, again, wrong, wrongRotation, biasA, biasB, flatA, flatB]
        let before = try sources.map { try Data(contentsOf: $0) }

        for expanded in [false, true] {
            var options = ImageStackOptions()
            options.useGPU = false
            options.normalization = .none
            options.rejection = .none
            let json = String(decoding: try options.jsonData, as: UTF8.self)
            let handle: OpaquePointer
            if expanded {
                handle = try StackNativeOpener.openExpanded(paths: [a.path, b.path, again.path],
                    optionsJSON: json, calibration: ImageStackCalibration(), maximumMegasamples: 1,
                    cancellation: ImageStackCancellation()).handle
            } else {
                handle = try StackNativeOpener.open(candidates: [a.path], referenceImagePath: nil,
                    optionsJSON: json, calibration: ImageStackCalibration(bias: biasA, flat: flatA)).handle
            }
            defer { seiza_live_stacker_free(handle) }
            func apply(_ bias: URL, _ flat: URL, measured: Double? = nil) throws {
                // A tolerance reset also resets the angle basis. Set the basis
                // afterwards, as required by the published native contract.
                try check { seiza_live_stacker_set_match_tolerances(handle, nil, &$0) }
                try check { error in
                    seiza_live_stacker_set_light_rotation(handle,
                        UInt32(measured == nil ? SEIZA_LIGHT_ROTATION_RECORDED : SEIZA_LIGHT_ROTATION_MEASURED),
                        measured ?? 0, &error)
                }
                try check { error in
                    bias.path.withCString { bias in flat.path.withCString { flat in
                        seiza_live_stacker_set_calibration_fits(handle, bias, nil, flat, 0, &error)
                    } }
                }
            }
            if expanded {
                try apply(biasA, flatA)
                XCTAssertTrue(try push(handle, a).accepted)
            }
            try apply(biasB, flatB)
            let rotationRefused = try push(handle, wrongRotation)
            XCTAssertFalse(rotationRefused.accepted)
            XCTAssertTrue(rotationRefused.reason?.lowercased().contains("rotation") == true, rotationRefused.reason ?? "")
            try apply(biasB, flatB, measured: 90)
            XCTAssertTrue(try push(handle, b).accepted)
            try apply(biasA, flatA)
            XCTAssertTrue(try push(handle, again).accepted)
            let integratedState = try state(handle)
            XCTAssertEqual(integratedState.acceptedFrames, 3)
            XCTAssertNil(integratedState.reintegrationUnavailable)
            for url in [biasA, biasB, flatA, flatB] {
                XCTAssertEqual(integratedState.inputPaths.filter { LiveStackPath.equals($0, url.path) }.count, 1)
            }
            let original = try snapshot(handle)
            defer { seiza_stack_snapshot_free(original) }
            let online = try pixels(original)
            if expanded { XCTAssertGreaterThan(seiza_stack_snapshot_width(original), width) }
            // Wrong gain must still be refused; overriding quality/rotation must
            // never turn off hard sensor compatibility.
            let refused = try push(handle, wrong)
            XCTAssertFalse(refused.accepted)
            XCTAssertTrue(refused.reason?.lowercased().contains("gain") == true, refused.reason ?? "")
            let context = root.appendingPathComponent("\(expanded).context")
            try check { failure in context.path.withCString { seiza_live_stacker_save_context(handle, $0, &failure) } }
            var failure: UnsafeMutablePointer<CChar>?
            let restored = try XCTUnwrap(context.path.withCString { seiza_live_stacker_open_context($0, &failure) },
                CalibrationService.takeOwnedError(&failure, fallback: "Restore failed"))
            defer { seiza_live_stacker_free(restored) }
            XCTAssertTrue(try state(handle).describesSameCheckpoint(state(restored)))
            let replay = try XCTUnwrap(seiza_live_stacker_reintegrate(restored, 1000, 1000, nil, nil, nil, &failure),
                CalibrationService.takeOwnedError(&failure, fallback: "Replay failed"))
            defer { seiza_stack_snapshot_free(replay) }
            XCTAssertEqual(seiza_stack_snapshot_accepted_frames(replay), 3)
            let reproduced = try pixels(replay)
            XCTAssertEqual(online.count, reproduced.count)
            XCTAssertEqual(online.map(\.isFinite), reproduced.map(\.isFinite))
            let finite = zip(online, reproduced).filter { $0.isFinite && $1.isFinite }
            XCTAssertGreaterThan(finite.count, width * height / 2)
            XCTAssertLessThan(finite.map { abs($0 - $1) }.max() ?? .infinity, 0.01)
            // Both sessions encode the same underlying signal. A stale bias B
            // would leave a 1000 ADU error despite a superficially valid stack.
            // Expanded planning translates the reference within its canvas;
            // its center index is not the reference's original center pixel.
            // The median background is 100 ADU on either grid (stars are sparse).
            let background = online.filter { $0.isFinite && $0 > 0 }.sorted()
            XCTAssertFalse(background.isEmpty)
            if !background.isEmpty { XCTAssertEqual(background[background.count / 2], 100, accuracy: 10) }

            // A historical recipe remains necessary after returning to A. A
            // missing B master must fail replay instead of silently using A.
            let hidden = root.appendingPathComponent("bias-b-away.fits")
            try FileManager.default.moveItem(at: biasB, to: hidden)
            do {
                defer { try? FileManager.default.moveItem(at: hidden, to: biasB) }
                let unavailable = seiza_live_stacker_reintegrate(restored, 1000, 1000, nil, nil, nil, &failure)
                if let unavailable { seiza_stack_snapshot_free(unavailable) }
                XCTAssertNil(unavailable)
                let message = CalibrationService.takeOwnedError(&failure, fallback: "")
                XCTAssertTrue(message.contains(biasB.lastPathComponent), message)
            }
        }
        XCTAssertEqual(try sources.map { try Data(contentsOf: $0) }, before)
    }

    func testPreparedFileOpenCannotReplaceAFileInputSessionPlanner() throws {
        let url = try SyntheticFrame.write(width: 160, height: 128,
            values: SyntheticFrame.noisyStarField(), cards: SyntheticFrame.lightCards())
        defer { try? FileManager.default.removeItem(at: url) }
        var failure: UnsafeMutablePointer<CChar>?
        let handle = try XCTUnwrap(url.path.withCString { seiza_live_stacker_open_prepared_fits($0, nil, &failure) },
            CalibrationService.takeOwnedError(&failure, fallback: "Prepared open failed"))
        defer { seiza_live_stacker_free(handle) }
        XCTAssertFalse(seiza_live_stacker_set_calibration_fits(handle, nil, nil, nil, 0, &failure))
        XCTAssertFalse(CalibrationService.takeOwnedError(&failure, fallback: "").isEmpty)
        XCTAssertFalse(seiza_live_stacker_set_match_tolerances(handle, nil, &failure))
        XCTAssertFalse(CalibrationService.takeOwnedError(&failure, fallback: "").isEmpty)
        XCTAssertEqual(try state(handle).inputMode, "prepared-only")
    }
}
