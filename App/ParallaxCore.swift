import CoreGraphics
import CoreVideo
import Foundation

struct ParallaxStop: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String? = "Whole Image"
    var focus: [Double]?
    var dolly = 0.0
    var zoom = 1.0
    var rotateDegrees = 0.0
    var pan = 0.0
    var travel = 4.0
    var hold = 1.0
    var spinDegrees = 0.0
    var push = 0.0
    var title: String?

    enum CodingKeys: String, CodingKey {
        case name, focus, dolly, zoom, rotateDegrees, pan, travel, hold, spinDegrees, push, title
    }
    init(name: String? = "Whole Image", focus: [Double]? = nil, dolly: Double = 0,
         zoom: Double = 1, rotateDegrees: Double = 0, pan: Double = 0,
         travel: Double = 4, hold: Double = 1, spinDegrees: Double = 0, push: Double = 0, title: String? = nil) {
        self.name = name; self.focus = focus; self.dolly = dolly; self.zoom = zoom
        self.rotateDegrees = rotateDegrees; self.pan = pan; self.travel = travel; self.hold = hold
        self.spinDegrees = spinDegrees; self.push = push
        self.title = title
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        focus = try c.decodeIfPresent([Double].self, forKey: .focus)
        dolly = try c.decodeIfPresent(Double.self, forKey: .dolly) ?? 0
        zoom = try c.decodeIfPresent(Double.self, forKey: .zoom) ?? 1
        rotateDegrees = try c.decodeIfPresent(Double.self, forKey: .rotateDegrees) ?? 0
        pan = try c.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        travel = try c.decodeIfPresent(Double.self, forKey: .travel) ?? 4
        hold = try c.decodeIfPresent(Double.self, forKey: .hold) ?? 1
        spinDegrees = try c.decodeIfPresent(Double.self, forKey: .spinDegrees) ?? 0
        push = try c.decodeIfPresent(Double.self, forKey: .push) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title)
    }
    var displayName: String { name ?? (focus == nil ? "Whole Image" : "Custom Point") }
}

struct ParallaxTourOptions: Codable {
    var targets: Int? = 5
    var hold = 1.5
    var motion = 1.0
}

struct ParallaxTourPlan: Codable {
    var schemaVersion = 1
    var focus: [Double]
    var focusName: String
    var seconds: Double
    var tour: [ParallaxStop]
    // Optional when reading the upstream planner or older saved tours.
    var tourGlide: Double?
    var tourTitles: Bool?
    var tourLoop: Bool?
}

struct ParallaxSceneSettings: Codable, Equatable {
    var distanceFocus: [Double]?
    var distanceParsecs: Double?
    var unmatchedDistanceParsecs: Double?
    var online = false
    var gaiaMaxMagnitude = 16.0
    var maxStars: Int?
    var smallStars = "field"
    var keepGalaxies = false
    var dust = true
    var dustOpacity = 3.0
    var minimumScaleArcsecPerPixel = 0.1
    var maximumScaleArcsecPerPixel = 20.0
}

struct ParallaxLabel: Codable, Equatable, Identifiable {
    var id = UUID()
    var x: Double
    var y: Double
    var radius = 0.0
    var text = "Label"
    enum CodingKeys: String, CodingKey { case x, y, radius, text }
}

enum ParallaxWatermark: Encodable, Equatable {
    case disabled, text(String)
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .disabled: try c.encode(false); case .text(let text): try c.encode(text) }
    }
}

// Reconfigure takes a COMPLETE camera/output object. Never send scene fields,
// and never rely on an omitted field inheriting the previous handle's value.
struct ParallaxVideoSettings: Encodable, Equatable {
    var focus: [Double]?
    var start = "whole"
    var dolly = 0.4
    var truck = 0.0
    var truckAngleDegrees = 0.0
    var pan = 0.0
    var zoom = 1.0
    var zoomEnd = 1.0
    var rotateDegrees = [0.0, 0.0]
    var easing = "inOut"
    var quality = "standard"
    var growthLimit = 4.0
    var fadeFrom = 6.0
    var tour: [ParallaxStop] = []
    var tourGlide = 0.2
    var tourTitles = false
    var tourLoop = false
    var seconds = 8.0
    var fps = 30
    var size = "1920x1080"
    var overlay = false
    var overlayDensity = 0.6
    var labels: [ParallaxLabel] = []
    var labelColor = "#F0F4F8"
    var watermark = ParallaxWatermark.disabled
}

struct ParallaxComposition: Equatable {
    enum Motion: String, CaseIterable { case flyIn = "Fly In", tour = "Tour" }
    var motion = Motion.flyIn
    var stops = [ParallaxStop(travel: 0), ParallaxStop(name: "Destination", dolly: 0.4, hold: 2)]
    var scene = ParallaxSceneSettings()
    var distanceName = "Image center"
    var focus: [Double]?
    var focusName = "Image center"
    var seconds = 8.0
    var dolly = 0.4
    var pan = 0.0
    var rotation = 0.0
    var rotationStart = 0.0
    var start = "whole"
    var truck = 0.0
    var truckAngleDegrees = 0.0
    var zoom = 1.0
    var zoomEnd = 1.0
    var easing = "inOut"
    var tourGlide = 0.2
    var tourTitles = false
    var tourLoop = false
    var width = 1920
    var height = 1080
    var fps = 30
    var quality = "standard"
    var growthLimit = 4.0
    var fadeFrom = 6.0
    var overlay = false
    var overlayDensity = 0.6
    var labels: [ParallaxLabel] = []
    var labelColor = "#F0F4F8"
    var creditEnabled = false
    var credit = "Rendered with seiza.fyi"

    var duration: Double {
        motion == .tour ? stops.enumerated().reduce(0) { $0 + $1.element.hold + ($1.offset == 0 ? 0 : $1.element.travel) } + loopClosingDuration : seconds
    }
    // Match upstream close_loop timing so the draft timeline includes an
    // automatically added return. Native preparation remains authoritative.
    var loopClosingDuration: Double {
        guard motion == .tour, tourLoop, stops.count >= 2,
            let first = stops.first, let last = stops.last else { return 0 }
        if last.focus == first.focus && last.dolly == first.dolly && last.zoom == first.zoom && last.pan == first.pan { return 0 }
        let travel = stops.dropFirst().reduce(0) { $0 + $1.travel } / Double(stops.count - 1)
        return travel + max(first.hold * 3, 3)
    }
    func arrival(at index: Int) -> Double {
        guard stops.indices.contains(index) else { return 0 }
        return stops.prefix(index).reduce(0) { $0 + $1.hold }
            + stops.prefix(index + 1).dropFirst().reduce(0) { $0 + $1.travel }
    }
    mutating func setSpin(at index: Int, clockwise: Bool) {
        guard stops.indices.contains(index) else { return }
        stops[index].spinDegrees = clockwise ? -360 : 360
        if stops[index].hold == 0 { stops[index].hold = 4 }
    }
    mutating func setTravelTurn(at index: Int, clockwise: Bool) {
        guard stops.indices.contains(index), index > 0 else { return }
        stops[index].rotateDegrees = stops[index - 1].rotateDegrees + (clockwise ? -360 : 360)
    }
    var validationMessage: String? {
        guard width >= 16, height >= 16, width <= 3840, height <= 3840,
            width.isMultiple(of: 2), height.isMultiple(of: 2), [24, 30, 60].contains(fps)
        else { return "Choose even dimensions between 16 and 3840 pixels and 24, 30 or 60 fps." }
        guard duration.isFinite, duration > 0, duration <= 600 else { return "The video must be longer than zero and at most 10 minutes." }
        let point: ([Double]?) -> Bool = { $0.map { $0.count == 2 && $0.allSatisfy(\.isFinite) } ?? true }
        for distance in [scene.distanceParsecs, scene.unmatchedDistanceParsecs].compactMap({ $0 }) {
            if !distance.isFinite || distance <= 0 { return "Distances must be positive, finite parsec values." }
        }
        guard point(scene.distanceFocus), scene.gaiaMaxMagnitude.isFinite,
            (1...25).contains(scene.gaiaMaxMagnitude), scene.dustOpacity.isFinite, scene.dustOpacity >= 0,
            scene.maxStars.map({ $0 >= 0 }) ?? true,
            scene.minimumScaleArcsecPerPixel.isFinite, scene.maximumScaleArcsecPerPixel.isFinite,
            scene.minimumScaleArcsecPerPixel > 0, scene.maximumScaleArcsecPerPixel >= scene.minimumScaleArcsecPerPixel
        else { return "Check the scene's distance reference, star limit, dust and solve settings." }
        guard point(focus), [dolly, pan, rotation, rotationStart, truck, truckAngleDegrees, zoom, zoomEnd, tourGlide, growthLimit, fadeFrom].allSatisfy(\.isFinite),
            (0..<1).contains(dolly), (0...1).contains(pan), zoom >= 1, zoomEnd >= 1,
            tourGlide >= 0, growthLimit >= 1, fadeFrom > 0
        else { return "Check the camera position, zoom, roll, glide and star appearance settings." }
        guard overlayDensity.isFinite, (0...1).contains(overlayDensity),
            labelColor.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil,
            labels.allSatisfy({ [$0.x, $0.y, $0.radius].allSatisfy(\.isFinite) && $0.radius >= 0 && !$0.text.isEmpty })
        else { return "Labels need valid positions, nonnegative radii and a color in #RRGGBB format." }
        if motion == .tour {
            guard stops.count >= 2 else { return "A tour needs at least two stops." }
            for stop in stops {
                guard point(stop.focus), [stop.dolly, stop.pan, stop.zoom, stop.rotateDegrees, stop.travel, stop.hold, stop.spinDegrees, stop.push].allSatisfy(\.isFinite),
                    (0..<1).contains(stop.dolly), (0...1).contains(stop.pan), stop.zoom > 0,
                    (0..<1).contains(stop.push), stop.travel >= 0, stop.hold >= 0
                else { return "Every stop needs valid framing, spin, push and nonnegative times." }
            }
        }
        return nil
    }
    func videoSettings(preview: Bool) -> ParallaxVideoSettings {
        // Preserve exact output aspect ratio for standard presets; custom even
        // dimensions are rounded to an even preview size.
        let scale = preview ? min(1, 960.0 / Double(max(width, height))) : 1
        let w = max(16, Int(Double(width) * scale) / 2 * 2)
        let h = max(16, Int(Double(height) * scale) / 2 * 2)
        return ParallaxVideoSettings(focus: focus, start: start, dolly: dolly,
            truck: truck, truckAngleDegrees: truckAngleDegrees, pan: pan, zoom: zoom, zoomEnd: zoomEnd,
            rotateDegrees: [rotationStart, rotation], easing: easing, quality: preview ? "standard" : quality,
            growthLimit: growthLimit, fadeFrom: fadeFrom, tour: motion == .tour ? stops : [], tourGlide: tourGlide,
            tourTitles: motion == .tour && tourTitles, tourLoop: motion == .tour && tourLoop,
            seconds: duration, fps: fps, size: "\(w)x\(h)", overlay: overlay, overlayDensity: overlayDensity,
            labels: labels, labelColor: labelColor, watermark: creditEnabled ? .text(credit) : .disabled)
    }
}

struct ParallaxInputs: Encodable {
    var image: String
    var starless: String?
    var stars: String?
    var wcs: WCSResult?
    var catalogDirectory: String?
    var gaiaCache: String?
    var objects: String?
    var objectDistances: String?
    var starDistances: String?
    var rcAstroExecutable: String?
    var rcAstroHost: String?
}

struct ParallaxRequest: Encodable {
    var inputs: ParallaxInputs
    var scene = ParallaxSceneSettings()
    var video = ParallaxVideoSettings()
    var autoTour: ParallaxTourOptions?
    enum CodingKeys: String, CodingKey { case autoTour }
    func encode(to encoder: Encoder) throws {
        try inputs.encode(to: encoder)
        try scene.encode(to: encoder)
        try video.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(autoTour, forKey: .autoTour)
    }
}

struct ParallaxFitValue: Decodable {
    let asked: Double
    let used: Double
    var changed: Bool { abs(asked - used) > 0.0001 }
}
struct ParallaxStopFit: Decodable { let zoom: ParallaxFitValue; let pan: ParallaxFitValue }
struct ParallaxFit: Decodable {
    let zoom: ParallaxFitValue
    let pan: ParallaxFitValue
    let lead: ParallaxFitValue
    let truck: ParallaxFitValue
    let stops: [ParallaxStopFit]
    let inside: Bool
    var edgeWarning: String? {
        inside ? nil : "Some frames extend beyond the image. Move the focus or tour stops inward, or reduce roll and pan."
    }
    var adjustments: [String] {
        var notes = [("Zoom", zoom), ("Pan", pan), ("Sideways lead", lead), ("Sideways motion", truck)]
            .filter { $0.1.changed }.map { String(format: "%@: %.2f → %.2f", $0.0, $0.1.asked, $0.1.used) }
        for (index, stop) in stops.enumerated() {
            if stop.zoom.changed { notes.append(String(format: "Stop %d zoom: %.2f → %.2f", index + 1, stop.zoom.asked, stop.zoom.used)) }
            if stop.pan.changed { notes.append(String(format: "Stop %d pan: %.2f → %.2f", index + 1, stop.pan.asked, stop.pan.used)) }
        }
        return notes
    }
}
struct ParallaxSummary: Decodable {
    let schemaVersion: Int
    let frames: Int
    let fps: Int
    let width: Int
    let height: Int
    let detectedStars: Int
    let withDistance: Int
    let backgroundDistanceParsecs: Double
    let backgroundBasis: String
    let backgroundFocus: [Double]
    let fit: ParallaxFit
    let wcs: WCSResult
}

struct ParallaxEvent: Decodable {
    let kind: String
    let message: String?
    let fraction: Double?
}

/// The ABI currently reports catalogue progress as notes. Recognize only
/// known messages and keep the original notes. Region counts are not an
/// overall completion percentage: some regions may already be cached.
struct ParallaxActivity {
    struct Entry: Identifiable {
        let id = UUID()
        let elapsed: TimeInterval
        let message: String
        let warning: Bool
    }
    let startedAt: Date
    var lastEventAt: Date
    var finishedAt: Date?
    var networkPhase: String?
    var regions: Int?
    var downloaded = 0
    var cancellationRequested = false
    var entries: [Entry] = []

    init(message: String, now: Date = .now) {
        startedAt = now; lastEventAt = now
        entries = [Entry(elapsed: 0, message: message, warning: false)]
    }

    mutating func receive(_ event: ParallaxEvent, now: Date = .now) {
        lastEventAt = now
        guard let raw = event.message else { return }
        let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        entries.append(Entry(elapsed: now.timeIntervalSince(startedAt), message: message, warning: event.kind == "warning"))
        if entries.count > 100 { entries.removeFirst() }
        if message.hasPrefix("fetching Gaia DR3 distances") {
            networkPhase = "Looking up Gaia star distances…"
            downloaded = 0
            regions = message.range(of: #"\d+(?= cone\(s\)$)"#, options: .regularExpression).flatMap { Int(message[$0]) }
        } else if message.hasSuffix("cone(s) fetched"), networkPhase != nil {
            downloaded = message.split(separator: " ").first.flatMap { Int($0) } ?? downloaded
        } else if message.range(of: #"^\d+ Gaia stars(?: from .*)?$"#, options: .regularExpression) != nil {
            networkPhase = "Checking bright-star distances (Hipparcos)…"
        } else if message.contains("matched to Gaia") || message.contains("no Hipparcos distances") {
            networkPhase = nil
        } else if event.kind != "warning" {
            networkPhase = nil
        }
    }

    func detail(at now: Date) -> String {
        let elapsed = Self.time((finishedAt ?? now).timeIntervalSince(startedAt))
        if cancellationRequested {
            return "\(elapsed) elapsed · Cancel requested. Waiting for the current operation to return."
        }
        if let regions, networkPhase?.hasPrefix("Looking up Gaia") == true {
            return "\(elapsed) elapsed · \(downloaded) new sky regions downloaded · \(regions) regions cover this image"
        }
        return "\(elapsed) elapsed"
    }

    func waitingMessage(at now: Date) -> String? {
        guard finishedAt == nil, !cancellationRequested, networkPhase != nil,
            now.timeIntervalSince(lastEventAt) >= 15 else { return nil }
        return "Waiting for the catalogue service: \(Self.time(now.timeIntervalSince(lastEventAt))) since its last update. Queries can take several minutes; completed Gaia regions are cached."
    }

    static func time(_ seconds: TimeInterval) -> String {
        let seconds = max(0, Int(seconds))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// Immutable pointer; native cancellation is atomic. The Swift flag can be read
// from render/writer queues. Every operation retains this owner until it returns.
final class ParallaxCancellation: @unchecked Sendable {
    let pointer = seiza_cancel_signal_create()!
    private let lock = NSLock()
    private var stopped = false
    var isCancelled: Bool { lock.withLock { stopped } }
    func cancel() {
        lock.withLock { stopped = true }
        seiza_cancel_signal_cancel(pointer)
    }
    func check() throws { if isCancelled { throw CancellationError() } }
    deinit { seiza_cancel_signal_free(pointer) }
}

private final class ParallaxEventContext {
    let receive: (ParallaxEvent) -> Void
    init(_ receive: @escaping (ParallaxEvent) -> Void) { self.receive = receive }
}

private let parallaxEventCallback: SeizaParallaxEventCallback = { json, context in
    guard let json, let context,
        let event = try? JSONDecoder().decode(ParallaxEvent.self, from: Data(String(cString: json).utf8))
    else { return }
    Unmanaged<ParallaxEventContext>.fromOpaque(context).takeUnretainedValue().receive(event)
}

enum ParallaxCore {
    static func error(_ pointer: UnsafeMutablePointer<CChar>?) -> Error {
        guard let pointer else { return SeizaCoreError.invalidCABIResponse }
        defer { seiza_string_free(pointer) }
        return SeizaCoreError.message(String(cString: pointer))
    }

    static func json<T: Encodable>(_ request: T) throws -> String {
        String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
    }

    static func plan(_ request: ParallaxRequest, cancellation: ParallaxCancellation,
                     events: @escaping (ParallaxEvent) -> Void) throws -> ParallaxTourPlan {
        try cancellation.check()
        let context = ParallaxEventContext(events)
        var failure: UnsafeMutablePointer<CChar>?
        let pointer = try withExtendedLifetime(context) {
            try json(request).withCString {
                seiza_parallax_plan_tour_json($0, parallaxEventCallback,
                    Unmanaged.passUnretained(context).toOpaque(), &failure)
            }
        }
        guard let pointer else { throw error(failure) }
        defer { seiza_string_free(pointer) }
        try cancellation.check()
        let result = try JSONDecoder().decode(ParallaxTourPlan.self, from: Data(String(cString: pointer).utf8))
        guard result.schemaVersion == 1, result.tour.count >= 2 else { throw SeizaCoreError.invalidCABIResponse }
        var composition = ParallaxComposition()
        composition.motion = .tour; composition.stops = result.tour; composition.scene.distanceFocus = result.focus
        if let message = composition.validationMessage { throw SeizaCoreError.message("Invalid generated tour: \(message)") }
        return result
    }

    static func prepare(_ request: ParallaxRequest, cancellation: ParallaxCancellation,
                        events: @escaping (ParallaxEvent) -> Void) throws -> ParallaxVideo {
        try cancellation.check()
        let context = ParallaxEventContext(events)
        var failure: UnsafeMutablePointer<CChar>?
        let pointer = try withExtendedLifetime(context) {
            try json(request).withCString {
                seiza_parallax_prepare_json($0, cancellation.pointer, parallaxEventCallback,
                    Unmanaged.passUnretained(context).toOpaque(), &failure)
            }
        }
        guard let pointer else { let failure = error(failure); try cancellation.check(); throw failure }
        let video = try ParallaxVideo(pointer: pointer)
        try cancellation.check()
        return video
    }

    static func reconfigure(_ video: ParallaxVideo, settings: ParallaxVideoSettings,
                            cancellation: ParallaxCancellation,
                            events: @escaping (ParallaxEvent) -> Void) throws -> ParallaxVideo {
        try cancellation.check()
        let context = ParallaxEventContext(events)
        var failure: UnsafeMutablePointer<CChar>?
        let pointer = try withExtendedLifetime((video, context)) {
            try json(settings).withCString {
                seiza_parallax_reconfigure_json(video.pointer, $0, cancellation.pointer,
                    parallaxEventCallback, Unmanaged.passUnretained(context).toOpaque(), &failure)
            }
        }
        guard let pointer else { let failure = error(failure); try cancellation.check(); throw failure }
        let result = try ParallaxVideo(pointer: pointer)
        try cancellation.check()
        return result
    }
}

// Upstream explicitly permits concurrent random-access renders. No mutation or
// free occurs while a frame/export retains this immutable owner.
final class ParallaxVideo: @unchecked Sendable {
    fileprivate let pointer: OpaquePointer
    let summary: ParallaxSummary

    fileprivate init(pointer: OpaquePointer) throws {
        var failure: UnsafeMutablePointer<CChar>?
        guard let json = seiza_parallax_summary_json(pointer, &failure) else {
            seiza_parallax_free(pointer)
            throw ParallaxCore.error(failure)
        }
        defer { seiza_string_free(json) }
        do {
            summary = try JSONDecoder().decode(ParallaxSummary.self, from: Data(String(cString: json).utf8))
            guard summary.schemaVersion == 1, summary.frames >= 2, summary.frames <= 36_000,
                summary.fps > 0, summary.width >= 16, summary.height >= 16,
                summary.width <= 3840, summary.height <= 3840
            else { throw SeizaCoreError.invalidCABIResponse }
        } catch {
            seiza_parallax_free(pointer)
            throw error
        }
        self.pointer = pointer
    }

    deinit { seiza_parallax_free(pointer) }

    func frame(_ index: Int) throws -> CGImage {
        var data = Data(count: summary.width * summary.height * 4)
        try data.withUnsafeMutableBytes { bytes in
            try render(index, format: UInt32(SEIZA_PIXEL_FORMAT_RGBA8), base: bytes.baseAddress!,
                       length: bytes.count, stride: summary.width * 4)
        }
        guard let image = SeizaCore.makeRGBA8Image(data: data, width: summary.width, height: summary.height)
        else { throw SeizaCoreError.invalidCABIResponse }
        return image
    }

    func render(_ index: Int, into buffer: CVPixelBuffer) throws {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
            CVPixelBufferGetWidth(buffer) == summary.width,
            CVPixelBufferGetHeight(buffer) == summary.height,
            CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess
        else { throw SeizaCoreError.message("The video pixel buffer is incompatible.") }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw SeizaCoreError.invalidCABIResponse }
        try render(index, format: UInt32(SEIZA_PIXEL_FORMAT_BGRA8), base: base,
                   length: CVPixelBufferGetDataSize(buffer), stride: CVPixelBufferGetBytesPerRow(buffer))
    }

    private func render(_ index: Int, format: UInt32, base: UnsafeMutableRawPointer,
                        length: Int, stride: Int) throws {
        guard (0..<summary.frames).contains(index) else { throw SeizaCoreError.message("Frame is outside the video.") }
        var failure: UnsafeMutablePointer<CChar>?
        guard seiza_parallax_render_frame(pointer, UInt32(index), format,
            base.assumingMemoryBound(to: UInt8.self), length, stride, &failure)
        else { throw ParallaxCore.error(failure) }
    }
}
