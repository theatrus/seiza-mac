import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import XCTest
@testable import Seiza

final class ParallaxTests: XCTestCase {
    func testCompositeSolveWinsAndExistingWCSIsReused() throws {
        let (files, original) = try fixture()
        defer { withExtendedLifetime(files) {} }
        let expected = try XCTUnwrap(original.inputs.wcs)
        var request = original
        request.inputs.wcs = nil
        request.scene.minimumScaleArcsecPerPixel = 0.7
        request.scene.maximumScaleArcsecPerPixel = 2.5
        var paths: [String] = []
        var messages: [String] = []
        let resolved = try ParallaxCore.resolvingWCS(request, cancellation: ParallaxCancellation(), events: {
            if let message = $0.message { messages.append(message) }
        }) { url, catalog, minimum, maximum in
            paths.append(url.path)
            XCTAssertEqual(catalog?.path, request.inputs.catalogDirectory)
            XCTAssertEqual(minimum, 0.7); XCTAssertEqual(maximum, 2.5)
            return expected
        }
        XCTAssertEqual(paths, [request.inputs.image])
        XCTAssertFalse(messages.contains { $0.contains("Retrying") })
        XCTAssertNil(request.inputs.wcs, "Resolving must not mutate the caller's request")
        let reused = try ParallaxCore.resolvingWCS(resolved, cancellation: ParallaxCancellation(), events: { _ in
            XCTFail("Existing WCS must not start a solve")
        }) { _, _, _, _ in
            XCTFail("Existing WCS must not be solved again"); return expected
        }
        XCTAssertEqual(reused.inputs.wcs?.crval, expected.crval)
    }

    func testStarsFallbackPreservesInputsAndPreparesWithRecoveredWCS() throws {
        let (files, original) = try fixture()
        defer { withExtendedLifetime(files) {} }
        let expected = try XCTUnwrap(original.inputs.wcs)
        var request = original
        request.inputs.image = files.directory.appendingPathComponent("unreadable-source.png").path
        request.inputs.wcs = nil
        var paths: [String] = []
        var messages: [String] = []
        let resolved = try ParallaxCore.resolvingWCS(request, cancellation: ParallaxCancellation(), events: {
            if let message = $0.message { messages.append(message) }
        }) { url, _, _, _ in
            paths.append(url.path)
            if url.path == request.inputs.image { throw SeizaCoreError.message("no source match") }
            return expected
        }
        XCTAssertEqual(paths, [request.inputs.image, try XCTUnwrap(request.inputs.stars)])
        XCTAssertEqual(resolved.inputs.image, request.inputs.image)
        XCTAssertEqual(resolved.inputs.starless, request.inputs.starless)
        XCTAssertEqual(resolved.inputs.stars, request.inputs.stars)
        XCTAssertTrue(messages.contains { $0.contains("no source match") && $0.contains("Retrying") })
        XCTAssertTrue(messages.contains { $0.contains("recovered from the stars layer") })
        // The native preparation must honor the recovered WCS and render the
        // separated pair without reopening or re-solving the failed composite.
        let video = try ParallaxCore.prepare(resolved, cancellation: ParallaxCancellation(), events: { _ in })
        XCTAssertEqual(video.summary.wcs.crval, expected.crval)
        XCTAssertEqual(try video.frame(0).width, 66)
    }

    func testFailedSolveDoesNotRetryUnavailableUnalignedOrIdenticalStars() throws {
        let (files, original) = try fixture()
        defer { withExtendedLifetime(files) {} }
        for scenario in ["unavailable", "unaligned", "identical"] {
            var request = original
            request.inputs.wcs = nil
            if scenario == "unavailable" { request.inputs.stars = nil }
            if scenario == "identical" { request.inputs.stars = request.inputs.image }
            var calls = 0
            XCTAssertThrowsError(try ParallaxCore.resolvingWCS(request, allowStarsFallback: scenario != "unaligned",
                cancellation: ParallaxCancellation(), events: { _ in }, solve: { _, _, _, _ in
                    calls += 1; throw SeizaCoreError.message("no match")
                })) { XCTAssertEqual($0.localizedDescription, "no match") }
            XCTAssertEqual(calls, 1, scenario)
        }
        var request = original
        request.inputs.wcs = nil
        var calls = 0
        XCTAssertThrowsError(try ParallaxCore.resolvingWCS(request, cancellation: ParallaxCancellation(), events: { _ in }, solve: { _, _, _, _ in
            calls += 1; throw SeizaCoreError.message(calls == 1 ? "source failure" : "stars failure")
        })) {
            XCTAssertTrue($0.localizedDescription.contains("Source: source failure"))
            XCTAssertTrue($0.localizedDescription.contains("Stars: stars failure"))
        }
        XCTAssertEqual(calls, 2)
    }

    func testSolveCancellationDoesNotRetryOrPublishLateWCS() throws {
        let (files, original) = try fixture()
        defer { withExtendedLifetime(files) {} }
        var request = original
        request.inputs.wcs = nil
        for returnsLateWCS in [false, true] {
            let cancellation = ParallaxCancellation()
            var calls = 0
            XCTAssertThrowsError(try ParallaxCore.resolvingWCS(request, cancellation: cancellation, events: { _ in }, solve: { _, _, _, _ in
                calls += 1; cancellation.cancel()
                if returnsLateWCS { return original.inputs.wcs! }
                throw SeizaCoreError.message("interrupted")
            })) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(calls, 1)
        }
    }

    func testOnlineActivityReportsWaitsCacheAwareCountsAndCancellation() {
        let start = Date(timeIntervalSince1970: 1000)
        var activity = ParallaxActivity(message: "Loading images…", now: start)
        activity.receive(ParallaxEvent(kind: "note", message: "fetching Gaia DR3 distances within 1.61 deg of (315.1375, +67.7775) in 4 cone(s)", fraction: nil), now: start.addingTimeInterval(5))
        XCTAssertEqual(activity.regions, 4)
        XCTAssertNil(activity.waitingMessage(at: start.addingTimeInterval(10)))
        XCTAssertTrue(activity.waitingMessage(at: start.addingTimeInterval(25))!.contains("0:20 since its last update"))
        activity.receive(ParallaxEvent(kind: "note", message: "  1 cone(s) fetched", fraction: nil), now: start.addingTimeInterval(30))
        XCTAssertEqual(activity.downloaded, 1)
        XCTAssertTrue(activity.detail(at: start.addingTimeInterval(35)).contains("1 new sky regions downloaded"))
        // Three cached regions plus one fresh response can finish a four-region
        // field. Never present fresh-download counts as overall completion.
        activity.receive(ParallaxEvent(kind: "note", message: "10574 Gaia stars", fraction: nil), now: start.addingTimeInterval(40))
        XCTAssertTrue(activity.networkPhase!.contains("Hipparcos"))
        activity.receive(ParallaxEvent(kind: "note", message: "5384 matched to Gaia, 5339 with a distance", fraction: nil), now: start.addingTimeInterval(50))
        XCTAssertNil(activity.networkPhase)
        XCTAssertNil(activity.waitingMessage(at: start.addingTimeInterval(80)))
        activity.receive(ParallaxEvent(kind: "warning", message: "A catalogue warning", fraction: nil), now: start.addingTimeInterval(60))
        XCTAssertTrue(activity.entries.last!.warning)
        activity.cancellationRequested = true
        XCTAssertTrue(activity.detail(at: start.addingTimeInterval(70)).contains("Cancel requested"))
        activity.finishedAt = start.addingTimeInterval(71)
        XCTAssertNil(activity.waitingMessage(at: start.addingTimeInterval(100)))
        let fresh = ParallaxActivity(message: "Next operation", now: start.addingTimeInterval(120))
        XCTAssertNil(fresh.regions); XCTAssertFalse(fresh.cancellationRequested)
        XCTAssertEqual(fresh.entries.count, 1)
    }

    func testPlannerStopsPreserveUnwrappedMotionAndIncomingTiming() throws {
        let json = #"{"schemaVersion":1,"focus":[100,80],"focusName":"Target","seconds":7,"tour":[{"name":"Whole Image","dolly":0,"zoom":1,"rotateDegrees":20,"pan":0,"travel":99,"hold":1},{"name":"Target","focus":[100,80],"dolly":0.4,"zoom":1.2,"rotateDegrees":380,"pan":0.6,"travel":4,"hold":2,"depthParsecs":2790}]}"#
        let plan = try JSONDecoder().decode(ParallaxTourPlan.self, from: Data(json.utf8))
        var composition = ParallaxComposition()
        composition.motion = .tour; composition.stops = plan.tour; composition.scene.distanceFocus = plan.focus
        XCTAssertEqual(composition.duration, 7)
        XCTAssertEqual(composition.arrival(at: 1), 5)
        composition.stops[1].name = "Renamed"
        let request = ParallaxRequest(inputs: ParallaxInputs(image: "/source.png"), scene: composition.scene, video: composition.videoSettings(preview: false))
        let encoded = try JSONSerialization.jsonObject(with: Data(ParallaxCore.json(request).utf8)) as! [String: Any]
        let stops = encoded["tour"] as! [[String: Any]]
        XCTAssertEqual(stops[1]["rotateDegrees"] as? Double, 380)
        XCTAssertEqual(stops[1]["pan"] as? Double, 0.6)
        XCTAssertNil(stops[1]["id"])
        XCTAssertEqual(stops[1]["depthParsecs"] as? Double, 2790)
        XCTAssertNil(stops[0]["depthParsecs"], "Stops without a depth continue to follow the scene")
        XCTAssertNil(encoded["autoTour"])
        XCTAssertEqual(encoded["distanceFocus"] as? [Double], [100, 80])
        composition.setTravelTurn(at: 1, clockwise: true)
        XCTAssertEqual(composition.stops[1].rotateDegrees, -340)
        composition.setTravelTurn(at: 1, clockwise: false)
        XCTAssertEqual(composition.stops[1].rotateDegrees, 380)
        composition.stops[1].hold = 0
        XCTAssertEqual(composition.duration, 5)
        composition.stops[1].pan = .nan
        XCTAssertNotNil(composition.validationMessage)
    }

    func testPreparedTourRendersRandomFramesAndPaddedBGRA() throws {
        let (files, request) = try fixture()
        defer { withExtendedLifetime(files) {} }
        var warnings: [String] = []
        let video = try ParallaxCore.prepare(request, cancellation: ParallaxCancellation()) {
            if $0.kind == "warning", let message = $0.message { warnings.append(message) }
        }
        XCTAssertEqual(video.summary.frames, 12)
        XCTAssertEqual(video.summary.width, 66)
        XCTAssertEqual(video.summary.backgroundDistanceParsecs, 400)
        XCTAssertFalse(warnings.isEmpty, "Offline fallback and 8-bit input must be reported")
        let last = try video.frame(11)
        _ = try video.frame(0)
        XCTAssertEqual(try video.frame(11).dataProvider?.data as Data?, last.dataProvider?.data as Data?)
        XCTAssertThrowsError(try video.frame(12))

        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 66, 48, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferBytesPerRowAlignmentKey: 128] as CFDictionary, &buffer), kCVReturnSuccess)
        let bgra = try XCTUnwrap(buffer)
        XCTAssertGreaterThan(CVPixelBufferGetBytesPerRow(bgra), 66 * 4)
        try video.render(11, into: bgra)
        CVPixelBufferLockBaseAddress(bgra, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(bgra, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(bgra)).assumingMemoryBound(to: UInt8.self)
        let rgba = try XCTUnwrap(last.dataProvider?.data as Data?)
        let stride = CVPixelBufferGetBytesPerRow(bgra)
        for y in 0..<48 {
            for x in 0..<66 {
                let i = (y * 66 + x) * 4, j = y * stride + x * 4
                XCTAssertEqual(base[j], rgba[i + 2]); XCTAssertEqual(base[j + 1], rgba[i + 1])
                XCTAssertEqual(base[j + 2], rgba[i]); XCTAssertEqual(base[j + 3], 255)
            }
        }
    }

    private func fixture() throws -> (ParallaxFiles, ParallaxRequest) {
        let files = try ParallaxFiles()
        let width = 96, height = 64
        let starless = files.directory.appendingPathComponent("starless.png")
        let stars = files.directory.appendingPathComponent("stars.png")
        var background = Data(count: width * height * 4)
        var starData = background
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                background[i] = UInt8(30 + x); background[i + 1] = UInt8(20 + y)
                background[i + 2] = 70; background[i + 3] = 255
                let r2 = Double((x - 35) * (x - 35) + (y - 27) * (y - 27))
                let light = UInt8(240 * exp(-r2 / 4))
                starData[i] = light; starData[i + 1] = light; starData[i + 2] = light; starData[i + 3] = 255
            }
        }
        try ImageFileWriter.write(XCTUnwrap(SeizaCore.makeRGBA8Image(data: background, width: width, height: height)), to: starless, format: .png)
        try ImageFileWriter.write(XCTUnwrap(SeizaCore.makeRGBA8Image(data: starData, width: width, height: height)), to: stars, format: .png)
        var request = ParallaxRequest(inputs: ParallaxInputs(image: starless.path, starless: starless.path, stars: stars.path,
            wcs: WCSResult(crval: [56.75, 24.12], crpix: [48, 32], cd: [[-0.001, 0], [0, 0.001]], sip: nil),
            catalogDirectory: files.directory.path))
        request.scene.distanceParsecs = 400; request.video.size = "66x48"; request.video.fps = 24
        request.video.tour = [ParallaxStop(travel: 0, hold: 0.1),
                        ParallaxStop(name: "Point", focus: [35, 27], dolly: 0.3, rotateDegrees: 360, pan: 0.3, travel: 0.3, hold: 0.1)]
        return (files, request)
    }

    func testFramingSummaryReportsEdgesAndRecoversAfterRefit() throws {
        let (files, original) = try fixture()
        defer { withExtendedLifetime(files) {} }
        var request = original
        request.video.tour = []; request.video.seconds = 0.5
        request.video.focus = [0, 0]; request.video.start = "focus"
        var warnings: [String] = []
        let video = try ParallaxCore.prepare(request, cancellation: ParallaxCancellation()) {
            if $0.kind == "warning", let message = $0.message { warnings.append(message) }
        }
        XCTAssertFalse(video.summary.fit.inside)
        XCTAssertNotNil(video.summary.fit.edgeWarning)
        XCTAssertTrue(warnings.contains { $0.contains("some frames show past its edge") })
        var settings = request.video
        settings.focus = [47.5, 31.5]; settings.start = "whole"
        let fitted = try ParallaxCore.reconfigure(video, settings: settings, cancellation: ParallaxCancellation(), events: { _ in })
        XCTAssertTrue(fitted.summary.fit.inside)
        XCTAssertNil(fitted.summary.fit.edgeWarning)
        XCTAssertFalse(video.summary.fit.inside, "A refit must not mutate the original handle")
        XCTAssertEqual(try fitted.frame(0).width, 66)
    }

    func testCameraValidationMatchesNativeBoundsAndRejectsOutsideStops() throws {
        let (files, request) = try fixture()
        defer { withExtendedLifetime(files) {} }
        let video = try ParallaxCore.prepare(request, cancellation: ParallaxCancellation(), events: { _ in })
        for key in [\ParallaxComposition.zoom, \ParallaxComposition.growthLimit] {
            var composition = ParallaxComposition()
            composition[keyPath: key] = 0.5
            XCTAssertNotNil(composition.validationMessage)
            XCTAssertThrowsError(try ParallaxCore.reconfigure(video, settings: composition.videoSettings(preview: false), cancellation: ParallaxCancellation(), events: { _ in })) {
                XCTAssertTrue($0.localizedDescription.contains("at least 1"))
            }
            composition[keyPath: key] = 1
            XCTAssertNil(composition.validationMessage)
        }
        var settings = request.video
        settings.tour[1].focus = [96, 32]
        XCTAssertThrowsError(try ParallaxCore.reconfigure(video, settings: settings, cancellation: ParallaxCancellation(), events: { _ in })) {
            XCTAssertTrue($0.localizedDescription.contains("tour stop 2"))
            XCTAssertTrue($0.localizedDescription.contains("outside"))
        }
        XCTAssertEqual(try video.frame(0).width, 66)
    }

    func testCancellationDuringPreparationStopsBeforeDistanceLookup() throws {
        let (files, request) = try fixture()
        defer { withExtendedLifetime(files) {} }
        let signal = ParallaxCancellation()
        var messages: [String] = []
        XCTAssertThrowsError(try ParallaxCore.prepare(request, cancellation: signal) { event in
            guard let message = event.message else { return }
            messages.append(message)
            if message.contains("stars found in the stars image") { signal.cancel() }
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(signal.isCancelled)
        XCTAssertFalse(messages.contains { $0.contains("matched to Gaia") })
        // The cancelled preparation releases its owners without invalidating inputs.
        let retry = try ParallaxCore.prepare(request, cancellation: ParallaxCancellation(), events: { _ in })
        XCTAssertEqual(try retry.frame(0).width, 66)
    }

    func testMissingCatalogueAndUnsupportedGlyphsWarnWithoutLosingScene() throws {
        let (files, original) = try fixture()
        defer { withExtendedLifetime(files) {} }
        var request = original
        request.inputs.objects = files.directory.appendingPathComponent("missing-objects.bin").path
        let video = try ParallaxCore.prepare(request, cancellation: ParallaxCancellation(), events: { _ in })
        var settings = request.video
        settings.overlay = true; settings.watermark = .text("Iris 🌌")
        var warnings: [String] = []
        let labelled = try ParallaxCore.reconfigure(video, settings: settings, cancellation: ParallaxCancellation()) {
            if $0.kind == "warning", let message = $0.message { warnings.append(message) }
        }
        XCTAssertTrue(warnings.contains { $0.contains("no catalogued objects labelled") })
        XCTAssertTrue(warnings.contains { $0.contains("typeface") && $0.contains("🌌") })
        XCTAssertEqual(labelled.summary.detectedStars, video.summary.detectedStars)
        XCTAssertEqual(try labelled.frame(0).width, 66)
    }

    func testNativeH264PreservesFramesTimingOrientationAndColor() async throws {
        try await verifyMovie(codec: .h264)
    }

    func testTourRoundTripKeepsHeldSpinPushAndGlideSeparateFromTravelRoll() throws {
        var composition = ParallaxComposition()
        composition.motion = .tour; composition.tourGlide = 0.35
        composition.stops[1].rotateDegrees = 45
        composition.stops[1].push = 0.6
        composition.stops[1].title = "The Iris Nebula"
        composition.tourTitles = true; composition.tourLoop = true
        composition.setSpin(at: 1, clockwise: true)
        XCTAssertEqual(composition.stops[1].rotateDegrees, 45)
        XCTAssertEqual(composition.stops[1].spinDegrees, -360)
        let plan = ParallaxTourPlan(focus: [20, 30], focusName: "Scene", seconds: composition.duration,
                                   tour: composition.stops, tourGlide: composition.tourGlide,
                                   tourTitles: composition.tourTitles, tourLoop: composition.tourLoop)
        let decoded = try JSONDecoder().decode(ParallaxTourPlan.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(decoded.tour[1].spinDegrees, -360)
        XCTAssertEqual(decoded.tour[1].push, 0.6)
        XCTAssertEqual(decoded.tourGlide, 0.35)
        XCTAssertEqual(decoded.tour[1].rotateDegrees, 45)
        XCTAssertEqual(decoded.tour[1].title, "The Iris Nebula")
        XCTAssertEqual(decoded.tourTitles, true); XCTAssertEqual(decoded.tourLoop, true)
        XCTAssertNotEqual(decoded.tour[1].id, composition.stops[1].id)
        let old = try JSONDecoder().decode(ParallaxStop.self, from: Data(#"{"rotateDegrees":720,"hold":2}"#.utf8))
        XCTAssertEqual(old.rotateDegrees, 720); XCTAssertEqual(old.spinDegrees, 0); XCTAssertEqual(old.push, 0)
        XCTAssertNil(old.title)
    }

    func testLoopDurationMatchesNativeClosureAndTitlesRefitWithoutSceneChanges() throws {
        let (files, original) = try fixture()
        defer { withExtendedLifetime(files) {} }
        var composition = ParallaxComposition()
        composition.motion = .tour; composition.stops = original.video.tour
        composition.tourLoop = true; composition.tourTitles = true
        composition.stops[1].title = "Target"
        composition.stops[1].hold = 2
        composition.width = 640; composition.height = 360; composition.fps = 24
        var request = original; request.video = composition.videoSettings(preview: false)
        let video = try ParallaxCore.prepare(request, cancellation: ParallaxCancellation(), events: { _ in })
        XCTAssertEqual(video.summary.frames, Int((composition.duration * 24).rounded()))
        XCTAssertEqual(video.summary.fit.stops.count, composition.stops.count + 1)
        XCTAssertEqual(composition.loopClosingDuration, 3.3, accuracy: 0.0001)
        let titledFrame = try video.frame(30).dataProvider!.data! as Data
        var settings = request.video; settings.tourTitles = false
        let untitled = try ParallaxCore.reconfigure(video, settings: settings, cancellation: ParallaxCancellation(), events: { _ in })
        XCTAssertNotEqual(titledFrame, try untitled.frame(30).dataProvider!.data! as Data)
        XCTAssertEqual(untitled.summary.detectedStars, video.summary.detectedStars)

        var closing = composition.stops[0]; closing.id = UUID(); closing.travel = 0.7
        closing.rotateDegrees = 720 // Orientation is normalized by upstream.
        composition.stops.append(closing)
        XCTAssertEqual(composition.loopClosingDuration, 0)
        let closed = try ParallaxCore.reconfigure(video, settings: composition.videoSettings(preview: false), cancellation: ParallaxCancellation(), events: { _ in })
        XCTAssertEqual(closed.summary.frames, Int((composition.duration * 24).rounded()))
        XCTAssertEqual(closed.summary.fit.stops.count, composition.stops.count)
        composition.motion = .flyIn
        XCTAssertFalse(composition.videoSettings(preview: false).tourTitles)
        XCTAssertFalse(composition.videoSettings(preview: false).tourLoop)
    }

    func testLoopKeepsMovingWhenItsStopsProvideNoNaturalDrift() throws {
        let (files, original) = try fixture()
        defer { withExtendedLifetime(files) {} }
        var request = original
        request.video.size = "320x240"
        request.video.tour = [ParallaxStop(travel: 0, hold: 1), ParallaxStop(travel: 1, hold: 1)]
        request.video.tourLoop = true
        request.video.tourGlide = 0
        let video = try ParallaxCore.prepare(request, cancellation: ParallaxCancellation(), events: { _ in })
        let opening = try video.frame(0).dataProvider!.data! as Data
        XCTAssertNotEqual(opening, try video.frame(12).dataProvider!.data! as Data,
                          "The lens must drift through a loop join even when both whole-image stops coincide")
        // Loop frames omit the duplicated endpoint. The wrap is one normal
        // frame interval, so compare its change with the adjacent intervals.
        let second = try video.frame(1).dataProvider!.data! as Data
        let last = try video.frame(video.summary.frames - 1).dataProvider!.data! as Data
        let penultimate = try video.frame(video.summary.frames - 2).dataProvider!.data! as Data
        func difference(_ a: Data, _ b: Data) -> Double {
            zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
        }
        XCTAssertLessThanOrEqual(difference(last, opening),
                                 2 * max(difference(opening, second), difference(penultimate, last)) + 0.01,
                                 "Wrapping must not produce a larger jump than normal camera motion")
        XCTAssertTrue(video.summary.fit.inside)
    }

    func testCompleteReconfigurationSettingsExcludeSceneFields() throws {
        let composition = ParallaxComposition()
        let data = try JSONEncoder().encode(composition.videoSettings(preview: false))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["start", "dolly", "truck", "truckAngleDegrees", "pan", "zoom", "zoomEnd", "rotateDegrees",
                    "easing", "quality", "growthLimit", "fadeFrom", "tour", "tourGlide", "tourTitles", "tourLoop", "seconds", "fps", "size",
                    "overlay", "overlayDensity", "labels", "labelColor", "watermark", "cardSeconds"] {
            XCTAssertNotNil(object[key], key)
        }
        XCTAssertNil(object["introCard"]); XCTAssertNil(object["outroCard"])
        for key in ["image", "wcs", "distanceFocus", "distanceParsecs", "smallStars", "online", "catalogDirectory", "autoTour", "dustMap",
                    "autoPlanes", "distanceOverrides", "planes"] {
            XCTAssertNil(object[key], key)
        }
        XCTAssertEqual(object["watermark"] as? Bool, false)
    }

    func testExplicitStopDepthSurvivesTourRoundTripAndValidates() throws {
        let data = Data(#"{"schemaVersion":1,"focus":[100,80],"focusName":"Reference","seconds":7,"tour":[{"hold":1},{"focus":[100,80],"hold":2,"travel":4,"depthParsecs":150}]}"#.utf8)
        let imported = try JSONDecoder().decode(ParallaxTourPlan.self, from: data)
        var composition = ParallaxComposition()
        composition.motion = .tour; composition.stops = imported.tour
        composition.stops[1].title = "Edited title"
        let saved = ParallaxTourPlan(focus: imported.focus, focusName: imported.focusName,
            seconds: composition.duration, tour: composition.stops)
        let restored = try JSONDecoder().decode(ParallaxTourPlan.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(restored.tour[1].depthParsecs, 150)
        XCTAssertEqual(restored.tour[1].title, "Edited title")
        XCTAssertNil(restored.tour[0].depthParsecs)
        XCTAssertNil(composition.validationMessage)
        for depth in [0, -1, Double.infinity, Double.nan] {
            composition.stops[1].depthParsecs = depth
            XCTAssertEqual(composition.validationMessage, "Stop depths must be positive, finite parsec values.")
        }
        composition.stops[1].depthParsecs = nil
        XCTAssertNil(composition.validationMessage)
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(composition.videoSettings(preview: false))) as? [String: Any])
        XCTAssertNil((settings["tour"] as? [[String: Any]])?[1]["depthParsecs"])
    }

    func testExplicitDepthReachesNativeFitAndCanReturnToSceneDepth() throws {
        let (files, request) = try fixture()
        defer { withExtendedLifetime(files) {} }
        let scene = try ParallaxCore.prepare(request, cancellation: ParallaxCancellation(), events: { _ in })
        var settings = request.video
        settings.tour = [ParallaxStop(travel: 0, hold: 0.1),
            ParallaxStop(name: "Explicit", focus: [35, 27], dolly: 0.3, pan: 0.3, travel: 0.3, hold: 0.1, depthParsecs: 150)]
        var warnings: [String] = []
        let explicit = try ParallaxCore.reconfigure(scene, settings: settings, cancellation: ParallaxCancellation()) {
            if $0.kind == "warning", let message = $0.message { warnings.append(message) }
        }
        XCTAssertTrue(warnings.contains { $0.contains("stop 2") && $0.contains("150 pc") }, "\(warnings)")
        XCTAssertEqual(explicit.summary.backgroundDistanceParsecs, scene.summary.backgroundDistanceParsecs)
        XCTAssertEqual(try explicit.frame(explicit.summary.frames - 1).width, scene.summary.width)
        settings.tour[1].depthParsecs = nil; warnings = []
        let following = try ParallaxCore.reconfigure(scene, settings: settings, cancellation: ParallaxCancellation()) {
            if $0.kind == "warning", let message = $0.message { warnings.append(message) }
        }
        XCTAssertFalse(warnings.contains { $0.contains("is framed at") }, "\(warnings)")
        XCTAssertEqual(following.summary.backgroundFocus, scene.summary.backgroundFocus)
        XCTAssertEqual(try following.frame(following.summary.frames - 1).width, scene.summary.width)
    }

    func testCreditLogoAndCardsEncodeForTheNativeCore() throws {
        var composition = ParallaxComposition()
        func settings() throws -> [String: Any] {
            let data = try JSONEncoder().encode(composition.videoSettings(preview: false))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        // The credit alone stays plain text, as before.
        XCTAssertEqual(try settings()["watermark"] as? Bool, false)
        composition.creditEnabled = true
        XCTAssertEqual(try settings()["watermark"] as? String, "Rendered with seiza.fyi")
        // A logo, or a corner of the user's, sends the whole watermark.
        composition.logoPath = "/logo.png"; composition.watermarkCorner = "topLeft"
        let styled = try XCTUnwrap(try settings()["watermark"] as? [String: Any])
        XCTAssertEqual(styled["text"] as? String, "Rendered with seiza.fyi")
        XCTAssertEqual(styled["image"] as? String, "/logo.png")
        XCTAssertEqual(styled["corner"] as? String, "topLeft")
        XCTAssertEqual(styled["size"] as? Double, 0.06); XCTAssertEqual(styled["opacity"] as? Double, 0.8)
        composition.creditEnabled = false
        XCTAssertNil(try XCTUnwrap(try settings()["watermark"] as? [String: Any])["text"])
        composition.watermarkOpacity = 2
        XCTAssertNotNil(composition.validationMessage)
        composition.watermarkOpacity = 0.8; composition.cardSeconds = 0
        XCTAssertNotNil(composition.validationMessage)
        composition.cardSeconds = 4
        XCTAssertNil(composition.validationMessage)
        // Cards travel with the settings, a stop's with the stop.
        composition.motion = .tour; composition.introCard = "/start.png"; composition.stops[1].card = "/stop.png"
        let object = try settings()
        XCTAssertEqual(object["introCard"] as? String, "/start.png"); XCTAssertNil(object["outroCard"])
        XCTAssertEqual(object["cardSeconds"] as? Double, 4)
        let tour = try XCTUnwrap(object["tour"] as? [[String: Any]])
        XCTAssertNil(tour[0]["card"]); XCTAssertEqual(tour[1]["card"] as? String, "/stop.png")
        let decoded = try JSONDecoder().decode(ParallaxStop.self, from: JSONEncoder().encode(composition.stops[1]))
        XCTAssertEqual(decoded.card, "/stop.png")
        // A stop the fit flies less far is reported.
        let fit = try JSONDecoder().decode(ParallaxFit.self, from: Data(#"""
            {"zoom":{"asked":1,"used":1},"pan":{"asked":0,"used":0},"lead":{"asked":1,"used":1},
             "truck":{"asked":0,"used":0},"inside":true,"stops":[
             {"zoom":{"asked":1,"used":1},"pan":{"asked":0,"used":0}},
             {"zoom":{"asked":3.2,"used":4},"pan":{"asked":0.12,"used":0.66},"dolly":{"asked":0.88,"used":0.34}}]}
            """#.utf8))
        XCTAssertTrue(fit.adjustments.contains("Stop 2 dolly: 0.88 → 0.34"), "\(fit.adjustments)")
    }

    func testCardsAndLogoAreDrawnOverTheFrames() throws {
        let (files, request) = try fixture()
        defer { withExtendedLifetime(files) {} }
        func png(_ name: String, width: Int, height: Int, color: [UInt8]) throws -> String {
            var data = Data(count: width * height * 4)
            for i in 0..<(width * height) { for channel in 0..<4 { data[i * 4 + channel] = color[channel] } }
            let url = files.directory.appendingPathComponent(name)
            try ImageFileWriter.write(XCTUnwrap(SeizaCore.makeRGBA8Image(data: data, width: width, height: height)),
                                      to: url, format: .png)
            return url.path
        }
        var composition = ParallaxComposition()
        composition.introCard = try png("card.png", width: 66, height: 48, color: [0, 0, 255, 255])
        composition.cardSeconds = 0.2
        composition.logoPath = try png("logo.png", width: 40, height: 10, color: [0, 255, 0, 255])
        composition.watermarkCorner = "topLeft"; composition.watermarkSize = 0.25; composition.watermarkOpacity = 1
        var carded = request
        carded.video.introCard = composition.introCard; carded.video.cardSeconds = composition.cardSeconds
        carded.video.watermark = composition.watermark
        var warnings: [String] = []
        let video = try ParallaxCore.prepare(carded, cancellation: ParallaxCancellation()) {
            if $0.kind == "warning", let message = $0.message { warnings.append(message) }
        }
        func pixel(_ frame: Int, _ x: Int, _ y: Int) throws -> [UInt8] {
            let data = try XCTUnwrap(video.frame(frame).dataProvider?.data as Data?)
            let i = (y * 66 + x) * 4
            return [data[i], data[i + 1], data[i + 2]]
        }
        let last = video.summary.frames - 1
        XCTAssertEqual(try pixel(0, 50, 40), [0, 0, 255], "The opening card covers the first frame")
        XCTAssertNotEqual(try pixel(last, 50, 40), [0, 0, 255], "and is gone by the end")
        XCTAssertEqual(try pixel(last, 20, 16), [0, 255, 0], "The logo sits a label's height in from the top-left corner")
        XCTAssertTrue(warnings.contains { $0.contains("transparency") }, "An opaque card is warned of: \(warnings)")
    }

    func testDustMapsSwapReadBackAndWriteWithoutPreparingAgain() throws {
        let (files, request) = try fixture()
        defer { withExtendedLifetime(files) {} }
        let original = try ParallaxCore.prepare(request, cancellation: ParallaxCancellation(), events: { _ in })
        XCTAssertNotEqual(original.summary.dustGiven, true)
        // One star is too few to count dust from.
        XCTAssertNil(try original.dustMap(width: 4, height: 3))
        XCTAssertNil(try original.dustMap(width: 4, height: 3, counted: true))
        XCTAssertFalse(try original.writeDustMap(to: files.directory.appendingPathComponent("none.png")))
        let originalPixels = try XCTUnwrap(original.frame(0).dataProvider?.data as Data?)

        // Scene data remains usable without its source rasters. Swapping and
        // resetting dust must not rerun preparation or mutate the old handle.
        try FileManager.default.removeItem(atPath: request.inputs.starless!)
        try FileManager.default.removeItem(atPath: request.inputs.stars!)

        // Opaque everywhere, at half the image's size.
        let painted = files.directory.appendingPathComponent("painted.png")
        let white = Data(repeating: 255, count: 48 * 32 * 4)
        try ImageFileWriter.write(XCTUnwrap(SeizaCore.makeRGBA8Image(data: white, width: 48, height: 32)), to: painted, format: .png)
        let opaque = try ParallaxCore.withDustMap(original, path: painted.path, cancellation: ParallaxCancellation(), events: { _ in })
        XCTAssertEqual(opaque.summary.dustGiven, true)
        XCTAssertEqual(opaque.summary.detectedStars, original.summary.detectedStars)
        for value in try XCTUnwrap(opaque.dustMap(width: 4, height: 3)) { XCTAssertEqual(value, 1, accuracy: 1e-4) }

        // Each format offered by the save panel writes a reusable map.
        for ext in ["png", "tiff", "fits", "xisf"] {
            let written = files.directory.appendingPathComponent("dust.\(ext)")
            XCTAssertTrue(try opaque.writeDustMap(to: written))
            let again = try ParallaxCore.withDustMap(original, path: written.path, cancellation: ParallaxCancellation(), events: { _ in })
            XCTAssertEqual(again.summary.dustGiven, true)
            for value in try XCTUnwrap(again.dustMap(width: 8, height: 6)) { XCTAssertEqual(value, 1, accuracy: 1e-4) }
            XCTAssertEqual(try again.frame(0).width, 66)
        }

        // Back to the counted dust, of which there is none here.
        let counted = try ParallaxCore.withDustMap(opaque, path: nil, cancellation: ParallaxCancellation(), events: { _ in })
        XCTAssertNotEqual(counted.summary.dustGiven, true)
        XCTAssertNil(try counted.dustMap(width: 4, height: 3))
        XCTAssertThrowsError(try ParallaxCore.withDustMap(original, path: files.directory.appendingPathComponent("missing.png").path,
            cancellation: ParallaxCancellation(), events: { _ in }))
        let cancelled = ParallaxCancellation(); cancelled.cancel()
        XCTAssertThrowsError(try ParallaxCore.withDustMap(opaque, path: nil, cancellation: cancelled, events: { _ in })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(try original.frame(0).dataProvider?.data as Data?, originalPixels)
        XCTAssertEqual(try counted.frame(0).dataProvider?.data as Data?, originalPixels)
    }

    func testDepthPlanesTravelInTheRequestAndComeBackFromTheSummary() throws {
        var composition = ParallaxComposition()
        composition.scene.autoPlanes = true
        composition.scene.setDistance(150, for: "vdB 2")
        composition.scene.setDistance(2790, for: "Sh2-170")
        // A second distance for the same object replaces the first.
        composition.scene.setDistance(160, for: "vdB 2")
        XCTAssertEqual(composition.scene.distanceOverrides, [ParallaxDistanceOverride(object: "vdB 2", distanceParsecs: 160),
                                                            ParallaxDistanceOverride(object: "Sh2-170", distanceParsecs: 2790)])
        XCTAssertEqual(composition.scene.givenDistance(for: "vdB 2"), 160)
        let request = ParallaxRequest(inputs: ParallaxInputs(image: "/source.png"), scene: composition.scene,
                                      video: composition.videoSettings(preview: false))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ParallaxCore.json(request).utf8)) as? [String: Any])
        XCTAssertEqual(encoded["autoPlanes"] as? Bool, true)
        let given = try XCTUnwrap(encoded["distanceOverrides"] as? [[String: Any]])
        XCTAssertEqual(given.map { $0["object"] as? String }, ["vdB 2", "Sh2-170"])
        XCTAssertEqual(given.first?["distanceParsecs"] as? Double, 160)
        composition.scene.clearDistance(for: "vdB 2")
        XCTAssertNil(composition.scene.givenDistance(for: "vdB 2"))
        XCTAssertEqual(composition.scene.distanceOverrides.map(\.object), ["Sh2-170"])
        XCTAssertNil(composition.validationMessage)
        composition.scene.setDistance(-5, for: "Sh2-170")
        XCTAssertNotNil(composition.validationMessage)

        // A plane its catalogued object places names it; a given mask or a
        // cloud the star counts place does not, with the field null or absent.
        let planes = try JSONDecoder().decode([ParallaxPlane].self, from: Data(#"""
            [{"name":"vdB 2","distanceParsecs":716.7,"basis":"measured, parallax","coverage":0.002,"absorbs":false,"object":"vdB 2"},
             {"name":"dust cloud 1","distanceParsecs":300,"basis":"Gaia star counts, 70 stars in front, 270-330 pc","coverage":0.05,"absorbs":true,"object":null},
             {"name":"knot","distanceParsecs":150,"basis":"given","coverage":0.01,"absorbs":true}]
            """#.utf8))
        XCTAssertEqual(planes.map(\.object), ["vdB 2", nil, nil])
        XCTAssertEqual(planes.map(\.absorbs), [false, true, true])
        XCTAssertEqual(planes[0].distanceParsecs, 716.7)
    }

    func testAutomaticPlanesPrepareWithoutAnObjectCatalogue() throws {
        let (files, original) = try fixture()
        defer { withExtendedLifetime(files) {} }
        var request = original
        request.inputs.objects = files.directory.appendingPathComponent("missing-objects.bin").path
        request.scene.autoPlanes = true
        let video = try ParallaxCore.prepare(request, cancellation: ParallaxCancellation(), events: { _ in })
        XCTAssertEqual(video.summary.planes, [])
        XCTAssertEqual(try video.frame(0).width, 66)
        // A distance by name needs the catalogue to find the object.
        request.scene.distanceOverrides = [ParallaxDistanceOverride(object: "NGC 7023", distanceParsecs: 150)]
        XCTAssertThrowsError(try ParallaxCore.prepare(request, cancellation: ParallaxCancellation(), events: { _ in }))
    }

    private func planeMask(in files: ParallaxFiles, name: String = "cloud", width: Int = 48, height: Int = 32) throws -> URL {
        var pixels = Data(count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value: UInt8 = (x - width / 2) * (x - width / 2) + (y - height / 2) * (y - height / 2) < 36 ? 255 : 0
                let i = (y * width + x) * 4
                pixels[i] = value; pixels[i + 1] = value; pixels[i + 2] = value; pixels[i + 3] = 255
            }
        }
        let url = files.directory.appendingPathComponent(name + ".png")
        try ImageFileWriter.write(XCTUnwrap(SeizaCore.makeRGBA8Image(data: pixels, width: width, height: height)), to: url, format: .png)
        return url
    }

    private func planeFixture() throws -> (ParallaxFiles, ParallaxRequest) {
        let (files, request) = try fixture()
        // The core drops a region with no distinct light to lift. Give the
        // selected mask a bright cloud over the smooth background.
        var pixels = Data(count: 96 * 64 * 4)
        for y in 0..<64 {
            for x in 0..<96 {
                let r2 = Double((x - 48) * (x - 48) + (y - 32) * (y - 32))
                let cloud = UInt8(120 * exp(-r2 / 40))
                let i = (y * 96 + x) * 4
                pixels[i] = 20 + cloud; pixels[i + 1] = 30 + cloud; pixels[i + 2] = 25 + cloud; pixels[i + 3] = 255
            }
        }
        try ImageFileWriter.write(XCTUnwrap(SeizaCore.makeRGBA8Image(data: pixels, width: 96, height: 64)),
            to: URL(fileURLWithPath: request.inputs.starless!), format: .png)
        return (files, request)
    }

    func testCustomMaskPlaneEncodingValidationAndNativePreparation() throws {
        let (files, original) = try planeFixture()
        let mask = try planeMask(in: files)
        var composition = ParallaxComposition()
        let plane = ParallaxMaskPlane(mask: mask.path, distanceParsecs: 150, name: "My cloud")
        composition.scene.planes = [plane]
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(composition.scene)) as? [String: Any])
        let row = try XCTUnwrap((encoded["planes"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["mask"] as? String, mask.path)
        XCTAssertEqual(row["distanceParsecs"] as? Double, 150)
        XCTAssertEqual(row["name"] as? String, "My cloud")
        XCTAssertNil(row["id"], "The native strict JSON contract must not receive editor UUIDs")
        let restored = try JSONDecoder().decode(ParallaxSceneSettings.self, from: JSONEncoder().encode(composition.scene))
        XCTAssertEqual(restored.planes.first?.mask, mask.path)
        XCTAssertEqual(restored.planes.first?.distanceParsecs, 150)
        for value in [0, -1, Double.infinity, Double.nan] {
            composition.scene.planes[0].distanceParsecs = value
            XCTAssertNotNil(composition.validationMessage)
        }
        composition.scene.planes[0] = plane
        composition.scene.planes[0].name = "  "
        XCTAssertNotNil(composition.validationMessage)
        composition.scene.planes[0] = plane
        XCTAssertNil(composition.validationMessage)

        var request = original
        request.scene.planes = [plane]
        XCTAssertFalse(request.scene.autoPlanes)
        let video = try ParallaxCore.prepare(request, cancellation: ParallaxCancellation(), events: { _ in })
        let actual = try XCTUnwrap(video.summary.planes?.first)
        XCTAssertEqual(actual.name, "My cloud"); XCTAssertEqual(actual.distanceParsecs, 150)
        XCTAssertEqual(actual.basis, "given"); XCTAssertNil(actual.object)
        XCTAssertGreaterThan(actual.coverage, 0.05); XCTAssertLessThan(actual.coverage, 0.1)
        XCTAssertEqual(try video.frame(0).width, 66)

        request.scene.planes[0].mask = try planeMask(in: files, name: "square", width: 32, height: 32).path
        XCTAssertThrowsError(try ParallaxCore.prepare(request, cancellation: ParallaxCancellation(), events: { _ in })) {
            XCTAssertTrue($0.localizedDescription.contains("My cloud"), $0.localizedDescription)
            XCTAssertTrue($0.localizedDescription.contains("shape"), $0.localizedDescription)
        }
        request.scene.planes[0].mask = files.directory.appendingPathComponent("missing.png").path
        XCTAssertThrowsError(try ParallaxCore.prepare(request, cancellation: ParallaxCancellation(), events: { _ in }))
        XCTAssertEqual(try video.frame(0).width, 66, "Failed preparations leave the immutable prior handle usable")
    }

    @MainActor
    func testNamedDistanceEntryValidatesAndUpdatesExistingNames() async throws {
        let (files, request) = try fixture()
        defer { withExtendedLifetime(files) {} }
        let session = ParallaxSession(sourceURL: URL(fileURLWithPath: request.inputs.image), processing: .default, wcs: request.inputs.wcs)
        defer { session.close() }
        try await waitUntil { !session.isBusy }
        XCTAssertTrue(session.addDistanceOverride(object: "  NGC 7000  ", parsecs: 600))
        XCTAssertEqual(session.unlistedDistances, [ParallaxDistanceOverride(object: "NGC 7000", distanceParsecs: 600)])
        XCTAssertTrue(session.addDistanceOverride(object: "ngc7000", parsecs: 700))
        XCTAssertEqual(session.composition.scene.distanceOverrides.count, 1)
        XCTAssertEqual(session.composition.scene.givenDistance(for: "NGC 7000"), 700)
        for value in [0, -1, Double.infinity, Double.nan] {
            XCTAssertFalse(session.addDistanceOverride(object: "IC 1396", parsecs: value))
        }
        XCTAssertFalse(session.addDistanceOverride(object: " \n", parsecs: 500))
        XCTAssertEqual(session.composition.scene.distanceOverrides.count, 1)
        session.undo()
        XCTAssertEqual(session.composition.scene.givenDistance(for: "ngc7000"), 600)
        session.clearDistance(for: "ngc7000")
        XCTAssertTrue(session.composition.scene.distanceOverrides.isEmpty)
        session.undo()
        XCTAssertEqual(session.composition.scene.givenDistance(for: "NGC 7000"), 600)
    }

    func testDustMapPathIsOmittedUntilChosen() throws {
        let none = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ParallaxInputs(image: "/source.png"))) as? [String: Any])
        XCTAssertNil(none["dustMap"])
        let chosen = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            ParallaxInputs(image: "/source.png", dustMap: "/dust.xisf"))) as? [String: Any])
        XCTAssertEqual(chosen["dustMap"] as? String, "/dust.xisf")
        XCTAssertEqual(try ParallaxCore.json(ParallaxDustMapPath(path: nil)), "{}")
    }

    func testReconfigurationSharesSceneWithoutFilesAndPreservesOldFrames() async throws {
        let (files, request) = try fixture()
        var first: ParallaxVideo? = try ParallaxCore.prepare(request, cancellation: ParallaxCancellation(), events: { _ in })
        let before = try first!.frame(2).dataProvider!.data! as Data
        // Removing our disposable fixture rasters proves refitting does not reload them.
        try FileManager.default.removeItem(atPath: request.inputs.starless!)
        try FileManager.default.removeItem(atPath: request.inputs.stars!)
        var settings = request.video
        settings.focus = [20, 30]; settings.tour = []; settings.seconds = 0.5
        settings.size = "80x60"; settings.fps = 60; settings.quality = "high"
        settings.rotateDegrees = [15, -345]; settings.truck = 0.1; settings.truckAngleDegrees = 30
        settings.zoom = 1.1; settings.zoomEnd = 1.3; settings.pan = 0.2
        settings.easing = "linear"; settings.growthLimit = 3; settings.fadeFrom = 5
        settings.watermark = .text("Test"); settings.labels = [ParallaxLabel(x: 20, y: 30, text: "Here")]
        settings.labelColor = "#FFCC00"
        let second = try ParallaxCore.reconfigure(first!, settings: settings, cancellation: ParallaxCancellation(), events: { _ in })
        XCTAssertEqual(second.summary.width, 80); XCTAssertEqual(second.summary.frames, 30)
        XCTAssertEqual(second.summary.backgroundFocus, first!.summary.backgroundFocus)
        XCTAssertEqual(second.summary.backgroundDistanceParsecs, first!.summary.backgroundDistanceParsecs)
        XCTAssertEqual(second.summary.detectedStars, first!.summary.detectedStars)
        XCTAssertEqual(second.summary.fit.zoom.asked, 1.1)
        let oldRender = Task.detached { [video = first!] in try video.frame(2).dataProvider!.data! as Data }
        async let oldFrame = oldRender.value
        async let newFrame = Task.detached { try second.frame(10) }.value
        let results = try await (oldFrame, newFrame)
        XCTAssertEqual(results.0, before); XCTAssertEqual(results.1.width, 80)
        first = nil
        XCTAssertEqual(try second.frame(29).height, 60)
        let cancelled = ParallaxCancellation(); cancelled.cancel()
        XCTAssertThrowsError(try ParallaxCore.reconfigure(second, settings: settings, cancellation: cancelled, events: { _ in })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(try second.frame(0).width, 80)
        withExtendedLifetime(files) {}
    }

    func testNativeHEVCPreservesFramesTimingOrientationAndColor() async throws {
        try await verifyMovie(codec: .hevc)
    }

    @MainActor
    func testSessionRefitsLatestCameraAndInvalidatesOnlySceneChanges() async throws {
        let (files, request) = try fixture()
        defer { withExtendedLifetime(files) {} }
        let session = ParallaxSession(sourceURL: URL(fileURLWithPath: request.inputs.image),
            processing: .default, wcs: request.inputs.wcs)
        defer { session.close() }
        try await waitUntil { !session.isBusy }
        XCTAssertTrue(session.sourceReady, session.error ?? "Source snapshot failed")
        session.importLayer(URL(fileURLWithPath: request.inputs.starless!), starless: true)
        try await waitUntil { !session.isBusy }
        session.importLayer(URL(fileURLWithPath: request.inputs.stars!), starless: false)
        try await waitUntil { !session.isBusy }
        session.layersAligned = true
        session.edit { $0.width = 80; $0.height = 60; $0.seconds = 0.5; $0.scene.distanceParsecs = 400 }
        session.preparePreview()
        try await waitUntil { !session.isBusy }
        XCTAssertTrue(session.hasScene, session.error ?? "Preparation failed")
        let reference = try XCTUnwrap(session.summary).backgroundFocus

        session.edit { $0.zoom = 1.1; $0.focus = [20, 30] }
        session.edit { $0.zoom = 1.3; $0.focus = [30, 20] }
        XCTAssertTrue(session.hasScene)
        XCTAssertFalse(session.hasPreview)
        try await waitUntil { !session.isReconfiguring }
        XCTAssertTrue(session.hasPreview, session.error ?? "Refit failed")
        XCTAssertEqual(session.summary?.fit.zoom.asked, 1.3)
        XCTAssertEqual(session.summary?.backgroundFocus, reference)

        session.edit { $0.motion = .tour; $0.stops[1].focus = [35, 27]; $0.stops[1].depthParsecs = 150 }
        XCTAssertTrue(session.hasScene, "Stop depth changes the camera, not the prepared scene")
        try await waitUntil { !session.isReconfiguring }
        XCTAssertTrue(session.hasPreview, session.error ?? "Depth refit failed")
        XCTAssertEqual(session.summary?.backgroundFocus, reference)
        session.undo()
        XCTAssertNil(session.composition.stops[1].depthParsecs)
        XCTAssertTrue(session.hasScene)
        try await waitUntil { !session.isReconfiguring }

        session.automaticPreview = false
        session.edit { $0.zoom = 1.5 }
        XCTAssertTrue(session.hasScene); XCTAssertFalse(session.hasPreview)
        XCTAssertFalse(session.isReconfiguring)
        session.preparePreview()
        try await waitUntil { !session.isReconfiguring }
        XCTAssertEqual(session.summary?.fit.zoom.asked, 1.5)
        session.edit { $0.scene.dust = false }
        XCTAssertFalse(session.hasScene); XCTAssertFalse(session.hasPreview)
        session.undo()
        XCTAssertTrue(session.composition.scene.dust)
        XCTAssertFalse(session.hasScene, "Undo must not restore a freed native scene")

        session.preparePreview()
        try await waitUntil { !session.isBusy }
        XCTAssertTrue(session.hasScene)
        let draft = session.composition
        session.catalogsDidChange()
        XCTAssertFalse(session.hasScene); XCTAssertFalse(session.hasPreview)
        XCTAssertEqual(session.composition, draft, "Installing catalogues keeps the edited camera and tour")
        XCTAssertTrue(session.canPrepare, "Imported layers remain ready after installing catalogues")
        session.preparePreview()
        try await waitUntil { !session.isBusy }
        XCTAssertTrue(session.hasScene)
        session.automaticPreview = true
        session.edit { $0.zoom = 1.7 }
        session.close()
        try await waitUntil { !session.isReconfiguring }
        XCTAssertFalse(session.hasScene); XCTAssertFalse(session.hasPreview)
        XCTAssertNil(session.error)
    }

    @MainActor
    func testSessionDustMapKeepsPendingCameraAndSurvivesRefits() async throws {
        let (files, request) = try fixture()
        defer { withExtendedLifetime(files) {} }
        let session = ParallaxSession(sourceURL: URL(fileURLWithPath: request.inputs.image),
            processing: .default, wcs: request.inputs.wcs)
        defer { session.close() }
        try await waitUntil { !session.isBusy }
        session.importLayer(URL(fileURLWithPath: request.inputs.starless!), starless: true)
        try await waitUntil { !session.isBusy }
        session.importLayer(URL(fileURLWithPath: request.inputs.stars!), starless: false)
        try await waitUntil { !session.isBusy }
        session.layersAligned = true
        session.edit { $0.width = 80; $0.height = 60; $0.seconds = 0.5; $0.scene.distanceParsecs = 400 }
        session.preparePreview()
        try await waitUntil { !session.isBusy }
        XCTAssertTrue(session.hasScene, session.error ?? "Preparation failed")

        let painted = files.directory.appendingPathComponent("painted.png")
        let white = Data(repeating: 255, count: 48 * 32 * 4)
        try ImageFileWriter.write(XCTUnwrap(SeizaCore.makeRGBA8Image(data: white, width: 48, height: 32)), to: painted, format: .png)

        // Applying a map while a camera edit has no preview must not restore
        // the camera from the older scene handle.
        session.automaticPreview = false
        session.edit { $0.zoom = 1.5 }
        session.chooseDustMap(ParallaxScopedURL(painted))
        try await waitUntil { !session.isBusy && !session.isReconfiguring }
        XCTAssertNil(session.error)
        XCTAssertEqual(session.summary?.dustGiven, true)
        XCTAssertEqual(session.summary?.fit.zoom.asked, 1.5)
        XCTAssertEqual(session.inputNames[.dustMap], "painted.png")

        session.automaticPreview = true
        session.edit { $0.zoom = 1.7 }
        var clear = Data(repeating: 0, count: 48 * 32 * 4)
        for index in stride(from: 3, to: clear.count, by: 4) { clear[index] = 255 }
        try ImageFileWriter.write(XCTUnwrap(SeizaCore.makeRGBA8Image(data: clear, width: 48, height: 32)), to: painted, format: .png)
        session.reloadDustMap()
        try await waitUntil { !session.isBusy && !session.isReconfiguring }
        XCTAssertEqual(session.summary?.fit.zoom.asked, 1.7)
        XCTAssertEqual(session.summary?.dustGiven, true)

        let exported = files.directory.appendingPathComponent("session-dust.tiff")
        session.edit { $0.zoom = 1.8 }
        session.exportDustMap(to: exported)
        XCTAssertTrue(session.isBusy, "Export must prevent overlapping writes and retain its destination access")
        try await waitUntil { !session.isBusy && !session.isReconfiguring }
        XCTAssertNil(session.error)
        XCTAssertEqual(session.summary?.fit.zoom.asked, 1.8, "Export must resume a pending preview refit")
        let original = try ParallaxCore.prepare(request, cancellation: ParallaxCancellation(), events: { _ in })
        let readback = try ParallaxCore.withDustMap(original, path: exported.path, cancellation: ParallaxCancellation(), events: { _ in })
        for value in try XCTUnwrap(readback.dustMap(width: 8, height: 6)) { XCTAssertEqual(value, 0, accuracy: 1e-4) }

        session.chooseDustMap(ParallaxScopedURL(files.directory.appendingPathComponent("missing.png")))
        try await waitUntil { !session.isBusy }
        XCTAssertNotNil(session.error)
        XCTAssertEqual(session.inputNames[.dustMap], "painted.png", "A failed map swap leaves the current selection intact")
        XCTAssertEqual(session.summary?.dustGiven, true)

        session.edit { $0.zoom = 1.9 }
        try await waitUntil { !session.isReconfiguring }
        XCTAssertEqual(session.summary?.fit.zoom.asked, 1.9)
        XCTAssertEqual(session.summary?.dustGiven, true, "Camera refits retain the map")
        session.clearInput(.dustMap)
        try await waitUntil { !session.isBusy }
        XCTAssertEqual(session.summary?.fit.zoom.asked, 1.9)
        XCTAssertNotEqual(session.summary?.dustGiven, true)
        XCTAssertNil(session.inputNames[.dustMap])
        XCTAssertNil(session.error)
    }

    @MainActor
    func testSessionDepthPlaneSettingsNeedANewScene() async throws {
        let (files, request) = try fixture()
        defer { withExtendedLifetime(files) {} }
        let session = ParallaxSession(sourceURL: URL(fileURLWithPath: request.inputs.image),
            processing: .default, wcs: request.inputs.wcs)
        defer { session.close() }
        try await waitUntil { !session.isBusy }
        session.importLayer(URL(fileURLWithPath: request.inputs.starless!), starless: true)
        try await waitUntil { !session.isBusy }
        session.importLayer(URL(fileURLWithPath: request.inputs.stars!), starless: false)
        try await waitUntil { !session.isBusy }
        session.layersAligned = true
        session.edit { $0.width = 80; $0.height = 60; $0.seconds = 0.5; $0.scene.distanceParsecs = 400 }
        session.preparePreview()
        try await waitUntil { !session.isBusy }
        XCTAssertTrue(session.hasScene, session.error ?? "Preparation failed")
        XCTAssertEqual(session.planes, [])
        XCTAssertNil(session.planesDescription, "Nothing to say while automatic planes are off")

        session.edit { $0.scene.autoPlanes = true }
        XCTAssertFalse(session.hasScene); XCTAssertFalse(session.hasPreview)
        XCTAssertEqual(session.planesDescription, "Depth planes are found when the scene is prepared.")
        session.undo()
        XCTAssertFalse(session.composition.scene.autoPlanes)
        XCTAssertFalse(session.hasScene, "Undo must not restore a freed native scene")

        session.preparePreview()
        try await waitUntil { !session.isBusy }
        XCTAssertTrue(session.hasScene)
        session.setDistance(150, for: "NGC 7023")
        XCTAssertFalse(session.hasScene); XCTAssertFalse(session.hasPreview)
        // Its object places no listed plane, so it is listed to be removed.
        XCTAssertEqual(session.unlistedDistances.map(\.object), ["NGC 7023"])
        session.setDistance(160, for: "NGC 7023")
        XCTAssertEqual(session.composition.scene.distanceOverrides, [ParallaxDistanceOverride(object: "NGC 7023", distanceParsecs: 160)])
        session.clearDistance(for: "NGC 7023")
        XCTAssertTrue(session.composition.scene.distanceOverrides.isEmpty)
        session.undo()
        XCTAssertEqual(session.composition.scene.givenDistance(for: "NGC 7023"), 160)
        XCTAssertNil(session.error)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Timed out waiting for the parallax session")
    }

    @MainActor
    func testCustomPlaneSelectionEditsReplacementAndUndoRebuildTheScene() async throws {
        let (files, request) = try planeFixture()
        let mask = try planeMask(in: files)
        let replacement = try planeMask(in: files, name: "replacement")
        let session = ParallaxSession(sourceURL: URL(fileURLWithPath: request.inputs.image), processing: .default, wcs: request.inputs.wcs)
        defer { session.close(); withExtendedLifetime(files) {} }
        try await waitUntil { !session.isBusy }
        session.importLayer(URL(fileURLWithPath: request.inputs.starless!), starless: true)
        try await waitUntil { !session.isBusy }
        session.importLayer(URL(fileURLWithPath: request.inputs.stars!), starless: false)
        try await waitUntil { !session.isBusy }
        session.layersAligned = true
        session.edit { $0.width = 80; $0.height = 60; $0.seconds = 0.5; $0.scene.distanceParsecs = 400 }
        session.preparePreview()
        try await waitUntil { !session.isBusy }
        XCTAssertTrue(session.hasScene, session.error ?? "Preparation failed")
        session.selectPlaneMask(ParallaxScopedURL(mask))
        XCTAssertFalse(session.hasScene)
        let id = try XCTUnwrap(session.composition.scene.planes.first?.id)
        session.editPlane(id) { $0.distanceParsecs = 150; $0.name = "Foreground" }
        session.preparePreview()
        try await waitUntil { !session.isBusy }
        XCTAssertTrue(session.hasPreview, session.error ?? "Mask preparation failed")
        XCTAssertEqual(session.summary?.planes?.first?.name, "Foreground")
        XCTAssertEqual(session.summary?.planes?.first?.distanceParsecs, 150)
        session.reloadPlane(id)
        XCTAssertFalse(session.hasScene, "Reload must reread masks edited outside the app")
        session.selectPlaneMask(ParallaxScopedURL(replacement), replacing: id)
        XCTAssertEqual(session.composition.scene.planes.first?.id, id)
        XCTAssertEqual(session.composition.scene.planes.first?.name, "Foreground")
        session.undo()
        XCTAssertEqual(session.composition.scene.planes.first?.mask, mask.path)
        session.removePlane(id)
        XCTAssertTrue(session.composition.scene.planes.isEmpty)
        session.undo()
        XCTAssertEqual(session.composition.scene.planes.first?.mask, mask.path)
        session.preparePreview()
        try await waitUntil { !session.isBusy }
        XCTAssertTrue(session.hasPreview, session.error ?? "Undo lost access to the mask")
        session.edit { $0.zoom = 1.2 }
        try await waitUntil { !session.isReconfiguring }
        XCTAssertTrue(session.hasScene)
        XCTAssertEqual(session.summary?.planes?.first?.distanceParsecs, 150)
    }

    private func verifyMovie(codec: NativeVideoExporter.Codec) async throws {
        let files = try ParallaxFiles()
        let url = files.directory.appendingPathComponent("native.mp4")
        try Data("previous destination".utf8).write(to: url)
        try await NativeVideoExporter.write(to: url, width: 64, height: 48, fps: 24, frames: 8,
            codec: codec, cancellation: ParallaxCancellation(), render: { index, buffer in
                CVPixelBufferLockBaseAddress(buffer, [])
                defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                for y in 0..<48 {
                    for x in 0..<64 {
                        let i = y * stride + x * 4
                        // Top left red, top right green, bottom blue. Small ramp verifies frame order.
                        base[i] = y >= 24 ? 200 : 20
                        base[i + 1] = y < 24 && x >= 32 ? 200 : 20
                        base[i + 2] = y < 24 && x < 32 ? UInt8(180 + index * 5) : 20
                        base[i + 3] = 255
                    }
                }
            }, progress: { _, _ in })
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 64, height: 48))
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 8.0 / 24, accuracy: 0.001)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample).seconds, Double(count) / 24, accuracy: 0.001)
            let pixel = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            let base = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixel)
            XCTAssertEqual(Double(base[8 * stride + 8 * 4 + 2]), Double(180 + count * 5), accuracy: 16)
            XCTAssertGreaterThan(base[8 * stride + 48 * 4 + 1], 175)
            XCTAssertGreaterThan(base[36 * stride + 8 * 4], 175)
            XCTAssertLessThan(base[8 * stride + 8 * 4], 40)
            CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
            count += 1
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(count, 8)
    }

    func testEncoderCancellationAndRenderFailurePreserveDestination() async throws {
        let files = try ParallaxFiles()
        let url = files.directory.appendingPathComponent("existing.mp4")
        let original = Data("existing movie".utf8)
        try original.write(to: url)
        let signal = ParallaxCancellation()
        do {
            try await NativeVideoExporter.write(to: url, width: 64, height: 48, fps: 24, frames: 8,
                codec: .h264, cancellation: signal, render: { _, _ in signal.cancel() }, progress: { _, _ in })
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: url), original)
        do {
            try await NativeVideoExporter.write(to: url, width: 64, height: 48, fps: 24, frames: 8,
                codec: .h264, cancellation: ParallaxCancellation(),
                render: { _, _ in throw SeizaCoreError.message("Synthetic render failure") }, progress: { _, _ in })
            XCTFail("Expected render error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Synthetic render failure")) }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}
