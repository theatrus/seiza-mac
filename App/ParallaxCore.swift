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
    /// An image with transparency shown during the stop in place of its
    /// title, with or without stop titles.
    var card: String?
    /// Nil follows the scene under the focus. Preserve an explicit depth
    /// from a generated or imported tour until the user chooses Follow scene.
    var depthParsecs: Double?

    enum CodingKeys: String, CodingKey {
        case name, focus, depthParsecs, dolly, zoom, rotateDegrees, pan, travel, hold, spinDegrees, push, title, card
    }
    init(name: String? = "Whole Image", focus: [Double]? = nil, dolly: Double = 0,
         zoom: Double = 1, rotateDegrees: Double = 0, pan: Double = 0,
         travel: Double = 4, hold: Double = 1, spinDegrees: Double = 0, push: Double = 0, title: String? = nil,
         card: String? = nil, depthParsecs: Double? = nil) {
        self.name = name; self.focus = focus; self.dolly = dolly; self.zoom = zoom
        self.depthParsecs = depthParsecs
        self.rotateDegrees = rotateDegrees; self.pan = pan; self.travel = travel; self.hold = hold
        self.spinDegrees = spinDegrees; self.push = push
        self.title = title; self.card = card
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        focus = try c.decodeIfPresent([Double].self, forKey: .focus)
        depthParsecs = try c.decodeIfPresent(Double.self, forKey: .depthParsecs)
        dolly = try c.decodeIfPresent(Double.self, forKey: .dolly) ?? 0
        zoom = try c.decodeIfPresent(Double.self, forKey: .zoom) ?? 1
        rotateDegrees = try c.decodeIfPresent(Double.self, forKey: .rotateDegrees) ?? 0
        pan = try c.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        travel = try c.decodeIfPresent(Double.self, forKey: .travel) ?? 4
        hold = try c.decodeIfPresent(Double.self, forKey: .hold) ?? 1
        spinDegrees = try c.decodeIfPresent(Double.self, forKey: .spinDegrees) ?? 0
        push = try c.decodeIfPresent(Double.self, forKey: .push) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title)
        card = try c.decodeIfPresent(String.self, forKey: .card)
    }
    var displayName: String { name ?? (focus == nil ? "Whole Image" : "Custom Point") }
}

struct ParallaxTourOptions: Codable {
    var targets: Int? = 5
    var hold = 1.5
    var motion = 1.0
}

/// How to plan a tour on a prepared scene: the frame it is for, and how many
/// targets, how long at each and how much motion.
struct ParallaxScenePlanSettings: Encodable {
    var size: String
    var framing = "fill"
    var autoTour: ParallaxTourOptions
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
    var crop: ParallaxCrop?
}

struct ParallaxCrop: Codable, Equatable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    static func selecting(from start: CGPoint, to end: CGPoint, width: Int, height: Int, aspect: Double?) -> Self? {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        var rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(bounds)
        guard !rect.isNull else { return nil }
        if let aspect, aspect.isFinite, aspect > 0 {
            if rect.width / max(1, rect.height) > aspect { rect.size.width = rect.height * aspect }
            else { rect.size.height = rect.width / aspect }
        }
        let crop = Self(x: Int(rect.minX.rounded()), y: Int(rect.minY.rounded()),
                        width: Int(rect.width.rounded(.down)), height: Int(rect.height.rounded(.down)))
        return crop.width >= 16 && crop.height >= 16 ? crop : nil
    }

    init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Int.self); y = try c.decode(Int.self)
        width = try c.decode(Int.self); height = try c.decode(Int.self)
        guard c.isAtEnd else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "A crop needs x, y, width and height.")
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x); try c.encode(y); try c.encode(width); try c.encode(height)
    }
}

struct ParallaxSceneSettings: Codable, Equatable {
    var crop: ParallaxCrop?
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
    /// Lift catalogued nebulae at distances of their own, and dust clouds in
    /// front of the nebula, onto depth planes.
    var autoPlanes = false
    var planes: [ParallaxMaskPlane] = []
    var distanceOverrides: [ParallaxDistanceOverride] = []
    var minimumScaleArcsecPerPixel = 0.1
    var maximumScaleArcsecPerPixel = 20.0

    func givenDistance(for object: String) -> Double? {
        distanceOverrides.first { Self.objectKey($0.object) == Self.objectKey(object) }?.distanceParsecs
    }
    /// Give `object` its own distance, replacing one given before.
    mutating func setDistance(_ parsecs: Double, for object: String) {
        if let index = distanceOverrides.firstIndex(where: { Self.objectKey($0.object) == Self.objectKey(object) }) {
            distanceOverrides[index].distanceParsecs = parsecs
        } else { distanceOverrides.append(ParallaxDistanceOverride(object: object.trimmingCharacters(in: .whitespacesAndNewlines), distanceParsecs: parsecs)) }
    }
    /// Return `object` to the catalogue's distance.
    mutating func clearDistance(for object: String) { distanceOverrides.removeAll { Self.objectKey($0.object) == Self.objectKey(object) } }
    private static func objectKey(_ name: String) -> String { name.filter { !$0.isWhitespace }.lowercased() }
}

/// A user-selected mask. The UUID identifies its editor row, not a native field.
struct ParallaxMaskPlane: Codable, Equatable, Identifiable {
    var id = UUID()
    var mask: String
    var distanceParsecs: Double
    var name: String
    enum CodingKeys: String, CodingKey { case mask, distanceParsecs, name }
}

/// A distance for a catalogued object, by name, in place of the catalogue's.
/// It moves the depth plane that object places.
struct ParallaxDistanceOverride: Codable, Equatable {
    var object: String
    var distanceParsecs: Double
}

struct ParallaxLabel: Codable, Equatable, Identifiable {
    var id = UUID()
    var x: Double
    var y: Double
    var radius = 0.0
    var text = "Label"
    enum CodingKeys: String, CodingKey { case x, y, radius, text }
}

/// A watermark of text, an image such as a logo, or both, in a corner of
/// every frame. Absent text or image draws none.
struct ParallaxWatermarkStyle: Encodable, Equatable {
    var text: String?
    var image: String?
    var corner = "bottomRight"
    var size = 0.06
    var opacity = 0.8
}

enum ParallaxWatermark: Encodable, Equatable {
    case disabled, text(String), styled(ParallaxWatermarkStyle)
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .disabled: try c.encode(false)
        case .text(let text): try c.encode(text)
        case .styled(let style): try c.encode(style)
        }
    }
}

// Reconfigure takes a COMPLETE camera/output object. Never send scene fields,
// and never rely on an omitted field inheriting the previous handle's value.
struct ParallaxVideoSettings: Encodable, Equatable {
    var focus: [Double]?
    var framing = "fill"
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
    /// Title cards over the start and end, shown for `cardSeconds` each.
    var introCard: String?
    var outroCard: String?
    var cardSeconds = 3.0
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
    var sourceWidth = 0
    var sourceHeight = 0
    var matchImageShape = false
    var framing = "fill"
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
    /// A logo drawn with the credit, its corner, its height as a share of the
    /// frame's shorter side, and the opacity of both.
    var logoPath: String?
    var watermarkCorner = "bottomRight"
    var watermarkSize = 0.06
    var watermarkOpacity = 0.8
    /// Title cards over the start and end of the video.
    var introCard: String?
    var outroCard: String?
    var cardSeconds = 3.0

    var filmedBounds: CGRect {
        scene.crop?.rect ?? CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
    }
    var imageCenter: [Double] {
        let bounds = filmedBounds
        return [bounds.minX + max(0, bounds.width - 1) / 2,
                bounds.minY + max(0, bounds.height - 1) / 2]
    }
    var outputSize: (width: Int, height: Int) {
        let bounds = filmedBounds
        guard matchImageShape, bounds.width > 0, bounds.height > 0 else { return (width, height) }
        let long = max(16, min(3840, max(width, height)))
        let short = max(16, min(long, Int((Double(long) * min(bounds.width, bounds.height) / max(bounds.width, bounds.height) / 2).rounded()) * 2))
        return bounds.width >= bounds.height ? (long, short) : (short, long)
    }
    var frameKey: String { "\(outputSize.width)x\(outputSize.height)|\(framing)" }
    func sourcePoint(_ point: [Double]) -> [Double] {
        guard point.count == 2 else { return point }
        return [point[0] + filmedBounds.minX, point[1] + filmedBounds.minY]
    }
    func videoPoint(_ point: [Double]) -> [Double] {
        guard point.count == 2 else { return point }
        return [point[0] - filmedBounds.minX, point[1] - filmedBounds.minY]
    }
    func sceneSettings() -> ParallaxSceneSettings {
        var result = scene
        result.distanceFocus = scene.distanceFocus.map(videoPoint)
        return result
    }
    /// The editor keeps source coordinates, so changing a crop never applies
    /// its origin twice. Only requests and saved tours use crop coordinates.
    mutating func setCrop(_ crop: ParallaxCrop?) {
        scene.crop = crop
        if distanceName == "Image center" { scene.distanceFocus = imageCenter }
        let bounds = filmedBounds
        guard bounds.width >= 16, bounds.height >= 16 else { return }
        func clamp(_ point: [Double]) -> [Double] {
            guard point.count == 2 else { return point }
            return [min(max(point[0], bounds.minX), bounds.maxX - 1),
                    min(max(point[1], bounds.minY), bounds.maxY - 1)]
        }
        focus = focus.map(clamp)
        scene.distanceFocus = scene.distanceFocus.map(clamp)
        for index in stops.indices { stops[index].focus = stops[index].focus.map(clamp) }
        for index in labels.indices {
            let point = clamp([labels[index].x, labels[index].y])
            labels[index].x = point[0]; labels[index].y = point[1]
        }
    }

    /// The credit and logo as the native core takes them: the plain text
    /// while that is all there is, else text, logo, corner, size and opacity.
    var watermark: ParallaxWatermark {
        let text = creditEnabled ? credit : nil
        let style = ParallaxWatermarkStyle(text: text, image: logoPath, corner: watermarkCorner,
                                           size: watermarkSize, opacity: watermarkOpacity)
        if style == ParallaxWatermarkStyle(text: text) { return text.map(ParallaxWatermark.text) ?? .disabled }
        return .styled(style)
    }

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
    /// Take `plan`'s tour. A plan made on the prepared scene keeps the scene's
    /// distance reference. Imported and catalogue plans supply a new reference.
    /// Every path preserves explicit stop depths, including externally authored ones.
    mutating func applyTour(_ plan: ParallaxTourPlan, onScene: Bool) {
        if !onScene { setCrop(plan.crop) }
        motion = .tour
        stops = plan.tour
        for index in stops.indices { stops[index].focus = stops[index].focus.map(sourcePoint) }
        if !onScene { scene.distanceFocus = sourcePoint(plan.focus); distanceName = plan.focusName }
        if let glide = plan.tourGlide { tourGlide = glide }
        if let titles = plan.tourTitles { tourTitles = titles }
        if let loop = plan.tourLoop { tourLoop = loop }
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
        if let crop = scene.crop,
           crop.x < 0 || crop.y < 0 || crop.width < 16 || crop.height < 16 ||
           crop.x > sourceWidth - crop.width || crop.y > sourceHeight - crop.height {
            return "Choose a crop at least 16 × 16 pixels inside the source image."
        }
        guard ["fill", "fit"].contains(framing) else { return "Choose Fill Frame or Show Whole Image." }
        guard width >= 16, height >= 16, width <= 3840, height <= 3840,
            width.isMultiple(of: 2), height.isMultiple(of: 2), [24, 30, 60].contains(fps)
        else { return "Choose even dimensions between 16 and 3840 pixels and 24, 30 or 60 fps." }
        guard duration.isFinite, duration > 0, duration <= 600 else { return "The video must be longer than zero and at most 10 minutes." }
        let point: ([Double]?) -> Bool = { $0.map { $0.count == 2 && $0.allSatisfy(\.isFinite) } ?? true }
        for distance in [scene.distanceParsecs, scene.unmatchedDistanceParsecs].compactMap({ $0 }) + scene.distanceOverrides.map(\.distanceParsecs) + scene.planes.map(\.distanceParsecs) {
            if !distance.isFinite || distance <= 0 { return "Distances must be positive, finite parsec values." }
        }
        if scene.distanceOverrides.contains(where: { $0.object.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "Give each object distance a catalogue object name."
        }
        if scene.planes.contains(where: { $0.mask.isEmpty || $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "Choose a mask and a name for each custom depth plane."
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
        guard watermarkSize.isFinite, watermarkSize > 0, watermarkSize <= 1,
            watermarkOpacity.isFinite, (0...1).contains(watermarkOpacity), cardSeconds.isFinite, cardSeconds > 0
        else { return "The logo needs a height above 0 and at most 1, an opacity from 0 to 1, and cards a duration above 0." }
        if motion == .tour {
            guard stops.count >= 2 else { return "A tour needs at least two stops." }
            for stop in stops {
                if let depth = stop.depthParsecs, !depth.isFinite || depth <= 0 {
                    return "Stop depths must be positive, finite parsec values."
                }
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
        let output = outputSize
        let scale = preview ? min(1, 960.0 / Double(max(output.width, output.height))) : 1
        let w = max(16, Int((Double(output.width) * scale / 2).rounded()) * 2)
        let h = max(16, Int((Double(output.height) * scale / 2).rounded()) * 2)
        var videoStops = stops
        for index in videoStops.indices { videoStops[index].focus = videoStops[index].focus.map(videoPoint) }
        var videoLabels = labels
        for index in videoLabels.indices {
            let point = videoPoint([videoLabels[index].x, videoLabels[index].y])
            videoLabels[index].x = point[0]; videoLabels[index].y = point[1]
        }
        return ParallaxVideoSettings(focus: focus.map(videoPoint), framing: framing, start: start, dolly: dolly,
            truck: truck, truckAngleDegrees: truckAngleDegrees, pan: pan, zoom: zoom, zoomEnd: zoomEnd,
            rotateDegrees: [rotationStart, rotation], easing: easing, quality: preview ? "standard" : quality,
            growthLimit: growthLimit, fadeFrom: fadeFrom, tour: motion == .tour ? videoStops : [], tourGlide: tourGlide,
            tourTitles: motion == .tour && tourTitles, tourLoop: motion == .tour && tourLoop,
            seconds: duration, fps: fps, size: "\(w)x\(h)", overlay: overlay, overlayDensity: overlayDensity,
            labels: videoLabels, labelColor: labelColor, watermark: watermark,
            introCard: introCard, outroCard: outroCard, cardSeconds: cardSeconds)
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
    /// A dust map, white where opaque, in place of the dust counted from the
    /// stars. A scene field: reconfiguration refuses it.
    var dustMap: String?
}

/// `{"path": ...}` for a dust map file, or `{}` for the counted dust.
struct ParallaxDustMapPath: Encodable { var path: String? }
struct ParallaxDustMapWrite: Encodable { var path: String; var counted: Bool }

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
struct ParallaxStopFit: Decodable {
    let zoom: ParallaxFitValue
    let pan: ParallaxFitValue
    /// How far the stop flies in: the fit flies it less far where it would
    /// show much of the smooth fill behind a depth plane.
    let dolly: ParallaxFitValue?
}
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
            if let dolly = stop.dolly, dolly.changed {
                notes.append(String(format: "Stop %d dolly: %.2f → %.2f", index + 1, dolly.asked, dolly.used))
            }
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
    let crop: ParallaxCrop?
    /// Whether a given map, rather than the star counts, made the dust, and
    /// how many stars its opaque places brought in front of the nebula.
    let dustGiven: Bool?
    let starsInFrontOfDust: Int?
    let planes: [ParallaxPlane]?
}

/// A depth plane the scene lifted: its distance, how that was found, the
/// share of the image it covers, and whether it blocks light behind it.
struct ParallaxPlane: Decodable, Equatable {
    let name: String
    let distanceParsecs: Double
    let basis: String
    let coverage: Double
    let absorbs: Bool
    /// The catalogued object whose distance places the plane, which a
    /// distance override moves it by; nil for a given mask or a cloud of dust
    /// the star counts place.
    let object: String?
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
    private struct DustMapTransform: Encodable {
        var path: String
        var output: String
        var sourceWidth: Int
        var sourceHeight: Int
        var crop: ParallaxCrop
        var expand: Bool
        var base: String?
    }

    static func transformDustMap(path: String, to output: URL, sourceWidth: Int, sourceHeight: Int,
                                 crop: ParallaxCrop, expand: Bool, base: String? = nil) throws {
        let request = DustMapTransform(path: path, output: output.path, sourceWidth: sourceWidth,
            sourceHeight: sourceHeight, crop: crop, expand: expand, base: base)
        var failure: UnsafeMutablePointer<CChar>?
        let success = try json(request).withCString { seiza_mac_dust_map_transform_json($0, &failure) }
        guard success else { throw error(failure) }
    }

    static func error(_ pointer: UnsafeMutablePointer<CChar>?) -> Error {
        guard let pointer else { return SeizaCoreError.invalidCABIResponse }
        defer { seiza_string_free(pointer) }
        return SeizaCoreError.message(String(cString: pointer))
    }

    static func json<T: Encodable>(_ request: T) throws -> String {
        String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
    }

    // Keep the original file's astrometric headers. The full-size snapshot and
    // confirmed, aligned stars layer preserve the same source geometry.
    static func resolvingWCS(_ request: ParallaxRequest, allowStarsFallback: Bool = true,
                            originalURL: URL? = nil, didSolve: ((SolveResult) -> Void)? = nil,
                            cancellation: ParallaxCancellation, events: (ParallaxEvent) -> Void,
                            solve: ((URL, URL?, Double, Double) throws -> WCSResult)? = nil) throws -> ParallaxRequest {
        try cancellation.check()
        guard request.inputs.wcs == nil else { return request }
        let catalog = request.inputs.catalogDirectory.map { URL(fileURLWithPath: $0) }
        func attempt(_ path: String) throws -> WCSResult {
            try cancellation.check()
            let wcs: WCSResult
            if let solve {
                wcs = try solve(URL(fileURLWithPath: path), catalog,
                    request.scene.minimumScaleArcsecPerPixel, request.scene.maximumScaleArcsecPerPixel)
            } else {
                let solution = try SeizaCore.solve(url: URL(fileURLWithPath: path), catalogDirectory: catalog,
                    minimumScale: request.scene.minimumScaleArcsecPerPixel,
                    maximumScale: request.scene.maximumScaleArcsecPerPixel,
                    cancellation: cancellation.pointer)
                try cancellation.check()
                didSolve?(solution)
                if let provenance = solution.provenanceDescription {
                    events(ParallaxEvent(kind: solution.solvedFrom == "header-unchecked" ? "warning" : "note",
                        message: provenance, fraction: nil))
                }
                wcs = solution.wcs
            }
            try cancellation.check()
            return wcs
        }
        var resolved = request
        if let originalURL, originalURL.path != request.inputs.image {
            events(ParallaxEvent(kind: "note", message: "Plate-solving the original file using its headers…", fraction: nil))
            do {
                resolved.inputs.wcs = try attempt(originalURL.path)
                return resolved
            } catch {
                try cancellation.check()
                if error is CancellationError { throw error }
                events(ParallaxEvent(kind: "warning", message: "Original file solve failed: \(error.localizedDescription). Retrying the source snapshot…", fraction: nil))
            }
        }
        events(ParallaxEvent(kind: "note", message: "Plate-solving the source image…", fraction: nil))
        do {
            resolved.inputs.wcs = try attempt(request.inputs.image)
        } catch {
            try cancellation.check()
            if error is CancellationError { throw error }
            guard allowStarsFallback, let stars = request.inputs.stars, stars != request.inputs.image else { throw error }
            let sourceError = error.localizedDescription
            events(ParallaxEvent(kind: "warning",
                message: "Source image solve failed: \(sourceError). Retrying with the aligned stars layer…", fraction: nil))
            do {
                resolved.inputs.wcs = try attempt(stars)
            } catch {
                try cancellation.check()
                if error is CancellationError { throw error }
                throw SeizaCoreError.message("Could not solve either image. Source: \(sourceError). Stars: \(error.localizedDescription)")
            }
            events(ParallaxEvent(kind: "note", message: "Sky coordinates recovered from the stars layer.", fraction: nil))
        }
        return resolved
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
        return try validatedPlan(String(cString: pointer))
    }

    /// A tour planned on `video`'s prepared scene, as an automatic tour of
    /// that scene would be: each stop frames its target at the depth of the
    /// plane the scene shows it on. The scene keeps its distance, so the
    /// plan's focus matters only to a new preparation.
    static func planOnScene(_ video: ParallaxVideo, settings: ParallaxScenePlanSettings,
                            cancellation: ParallaxCancellation) throws -> ParallaxTourPlan {
        try cancellation.check()
        var failure: UnsafeMutablePointer<CChar>?
        let pointer = try withExtendedLifetime(video) {
            try json(settings).withCString { seiza_parallax_plan_scene_tour_json(video.pointer, $0, &failure) }
        }
        guard let pointer else { throw error(failure) }
        defer { seiza_string_free(pointer) }
        try cancellation.check()
        return try validatedPlan(String(cString: pointer))
    }

    private static func validatedPlan(_ json: String) throws -> ParallaxTourPlan {
        let result = try JSONDecoder().decode(ParallaxTourPlan.self, from: Data(json.utf8))
        guard result.schemaVersion == 1, result.tour.count >= 2 else { throw SeizaCoreError.invalidCABIResponse }
        var composition = ParallaxComposition()
        composition.motion = .tour; composition.stops = result.tour; composition.scene.distanceFocus = result.focus
        if let message = composition.validationMessage { throw SeizaCoreError.message("Invalid generated tour: \(message)") }
        return result
    }

    static func prepare(_ request: ParallaxRequest, originalURL: URL? = nil,
                        didSolve: ((SolveResult) -> Void)? = nil, cancellation: ParallaxCancellation,
                        events: @escaping (ParallaxEvent) -> Void) throws -> ParallaxVideo {
        try cancellation.check()
        // Imported pairs have already been confirmed aligned by the workspace.
        // Automatic separation keeps the upstream solve/separation path.
        var resolved = request
        if originalURL != nil || request.inputs.stars != nil {
            do {
                resolved = try resolvingWCS(request, originalURL: originalURL, didSolve: didSolve,
                    cancellation: cancellation, events: events)
            } catch {
                try cancellation.check()
                guard !(error is CancellationError), request.inputs.stars == nil,
                      request.inputs.rcAstroExecutable != nil else { throw error }
                events(ParallaxEvent(kind: "warning", message: "Source solve failed; trying the automatically separated stars layer.", fraction: nil))
            }
        }
        let context = ParallaxEventContext(events)
        var failure: UnsafeMutablePointer<CChar>?
        let pointer = try withExtendedLifetime(context) {
            try json(resolved).withCString {
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

    /// The same scene and camera with the dust map at `path` (white opaque;
    /// PNG, JPEG, TIFF, FITS or XISF), or the counted dust again when `path`
    /// is nil. Only the dust changes; the scene is not prepared again.
    static func withDustMap(_ video: ParallaxVideo, path: String?, cancellation: ParallaxCancellation,
                            events: @escaping (ParallaxEvent) -> Void) throws -> ParallaxVideo {
        try cancellation.check()
        let context = ParallaxEventContext(events)
        var failure: UnsafeMutablePointer<CChar>?
        let pointer = try withExtendedLifetime((video, context)) {
            try json(ParallaxDustMapPath(path: path)).withCString {
                seiza_parallax_with_dust_map_json(video.pointer, $0, cancellation.pointer,
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

    /// The dust as a `width` × `height` map over the whole image, row by row,
    /// 0 clear to 1 opaque: the dust in use, or the dust counted from the
    /// stars even while a given map takes its place. Nil when there is none.
    func dustMap(width: Int, height: Int, counted: Bool = false) throws -> [Float]? {
        guard width > 0, height > 0 else { throw SeizaCoreError.message("The dust map needs a width and height.") }
        var opacity = [Float](repeating: 0, count: width * height)
        var failure: UnsafeMutablePointer<CChar>?
        let which = UInt32(counted ? SEIZA_DUST_MAP_COUNTED : SEIZA_DUST_MAP_IN_USE)
        let result = opacity.withUnsafeMutableBufferPointer { buffer in
            seiza_parallax_dust_map(pointer, which, UInt32(width), UInt32(height), buffer.baseAddress, buffer.count, &failure)
        }
        if result < 0 { throw ParallaxCore.error(failure) }
        if let failure { seiza_string_free(failure) }
        return result == 1 ? opacity : nil
    }

    /// Write the dust to `url`, white opaque, in the format its extension
    /// names: 16-bit PNG or TIFF, or 32-bit float FITS or XISF, the size of
    /// the image. False when there is no such dust to write.
    func writeDustMap(to url: URL, counted: Bool = false) throws -> Bool {
        var failure: UnsafeMutablePointer<CChar>?
        let request = try ParallaxCore.json(ParallaxDustMapWrite(path: url.path, counted: counted))
        let result = request.withCString { seiza_parallax_write_dust_map_json(pointer, $0, &failure) }
        if result < 0 { throw ParallaxCore.error(failure) }
        if let failure { seiza_string_free(failure) }
        return result == 1
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
