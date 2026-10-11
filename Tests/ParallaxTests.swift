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
        let json = #"{"schemaVersion":1,"focus":[100,80],"focusName":"Target","seconds":7,"tour":[{"name":"Whole Image","dolly":0,"zoom":1,"rotateDegrees":20,"pan":0,"travel":99,"hold":1},{"name":"Target","focus":[100,80],"dolly":0.4,"zoom":1.2,"rotateDegrees":380,"pan":0.6,"travel":4,"hold":2}]}"#
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
                    "overlay", "overlayDensity", "labels", "labelColor", "watermark"] {
            XCTAssertNotNil(object[key], key)
        }
        for key in ["image", "wcs", "distanceFocus", "distanceParsecs", "smallStars", "online", "catalogDirectory", "autoTour"] {
            XCTAssertNil(object[key], key)
        }
        XCTAssertEqual(object["watermark"] as? Bool, false)
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
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Timed out waiting for the parallax session")
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
