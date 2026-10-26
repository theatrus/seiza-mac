import AppKit
import Foundation

// All mathematical operations and fit validation live in the published Seiza crates.
enum ColorTool: String, CaseIterable, Identifiable, Sendable {
    case narrowband, continuum, stretchStars, restoreStars, restorePreparedStars
    var id: String { rawValue }
    var title: String {
        switch self {
        case .narrowband: "Narrowband palette"
        case .continuum: "Continuum subtraction"
        case .stretchStars: "Extract and stretch RGB stars"
        case .restoreStars: "Restore RGB stars"
        case .restorePreparedStars: "Restore prepared display stars"
        }
    }
    var operation: String {
        switch self {
        case .narrowband: "narrowband"
        case .continuum: "subtract-continuum"
        case .stretchStars: "stretch-stars"
        case .restoreStars: "restore-stars"
        case .restorePreparedStars: "restore-prepared-stars"
        }
    }
}

struct ColorToolsRecipe: Equatable, Sendable {
    var tool: ColorTool = .narrowband
    var paths = Array(repeating: "", count: 4)
    var palette = "hoo"
    var referenceCount = 1
    var aligned = false
    var linearConfirmed = false
    var inputDisplay = false
    var nebulaDisplay = true
    var targetMedian = 0.2
    var balance = true
    var shadowProtection = 1.0
    var oiiiBoost = 1.0
    var siiBoost = 1.0
    var excludeStars = false
    var greenReduction = 0.0
    var structure = ""
    var structureAmount = 0.0
    var saturations = Array(repeating: 0.0, count: 4)
    var masks = Array(repeating: "", count: 4)
    var psfMatching = false
    var manual = false
    var coefficients = Array(repeating: 1.0, count: 3)
    var starAmount = 5.0
    var starReduction = 0.0

    var inputLabels: [String] {
        switch tool {
        case .narrowband: palette == "hoo" ? ["Hα", "O III"] : ["Hα", "O III", "S II"]
        case .continuum: ["Narrowband line"] + (1...referenceCount).map { "Continuum reference \($0)" }
        case .stretchStars: ["Original linear RGB", "Starless linear RGB"]
        case .restoreStars: ["Original linear RGB", "Starless linear RGB", "Nebula RGB"]
        case .restorePreparedStars: ["Prepared display RGB stars", "Nebula RGB"]
        }
    }
    var inputs: [String] { Array(paths.prefix(inputLabels.count)) }
    var requiresLinearConfirmation: Bool {
        tool == .continuum || tool == .stretchStars || tool == .restoreStars
            || (tool == .narrowband && !inputDisplay) || (tool == .restorePreparedStars && !nebulaDisplay)
    }
    var protectedURLs: [URL] {
        (inputs + (tool == .continuum ? Array(masks.prefix(inputs.count)) : [])
            + (tool == .narrowband ? [structure] : []))
            .filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0) }
    }
    func validate(analyze: Bool, plan: Data?) throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw ImageStackError.invalidRequest(message) }
        }
        try require(aligned, "Confirm that the images share an aligned pixel grid. Equal dimensions alone do not establish alignment.")
        try require(!requiresLinearConfirmation || linearConfirmed, "Confirm that linear inputs retain their original common photometric scale.")
        try require(inputs.allSatisfy { !$0.isEmpty }, "Choose every required input image.")
        for url in protectedURLs {
            try require(FileManager.default.fileExists(atPath: url.path), "A selected image or clipping mask is missing: \(url.lastPathComponent)")
        }
        func range(_ v: Double, _ a: Double, _ b: Double) -> Bool { v.isFinite && (a...b).contains(v) }
        if tool == .continuum {
            try require(saturations.prefix(inputs.count).allSatisfy { $0.isFinite && $0 >= 0 }, "Use a positive producer saturation ceiling, or 0 for unknown. Never use the observed maximum.")
            if !analyze {
                try require(manual || plan != nil, "Analyze and review a fit or load an exact-source plan before subtracting.")
                if manual { try require(coefficients.prefix(referenceCount).allSatisfy { $0.isFinite && $0 >= 0 }, "Manual coefficients must be finite and nonnegative.") }
            }
        }
        if (tool == .narrowband && !inputDisplay) || ([.restoreStars, .restorePreparedStars].contains(tool) && !nebulaDisplay) {
            try require(targetMedian.isFinite && targetMedian > 0 && targetMedian < 1, "Target median must be between zero and one.")
        }
        try require(range(greenReduction, 0, 1) && range(starReduction, 0, 1) && range(starAmount, 0, 8), "Green/star reduction must be 0–1 and star stretch 0–8.")
        if tool == .narrowband {
            try require(range(structureAmount, 0, 1), "Structure mix must be 0–1.")
            if balance { try require(range(shadowProtection, 0, 1) && oiiiBoost.isFinite && oiiiBoost > 0 && siiBoost.isFinite && siiBoost > 0, "Shadow protection must be 0–1 and channel boosts must be positive.") }
        }
    }
    func json(output: URL?, analyze: Bool, plan: Data?) throws -> Data {
        try validate(analyze: analyze, plan: plan)
        var v: [String: Any] = ["operation": analyze ? "analyze-continuum" : tool.operation, "inputs": inputs]
        if let output { v["output"] = output.path }
        if tool == .narrowband {
            v["palette"] = palette; v["inputDisplay"] = inputDisplay; v["balance"] = balance
            if balance {
                var options: [String: Any] = ["shadow_protection": shadowProtection, "oiii_boost": oiiiBoost, "sii_boost": siiBoost]
                if excludeStars { options["star_mask_radius"] = 5.0 }
                v["balanceOptions"] = options
            }
            if !structure.isEmpty { v["structure"] = structure; v["structureAmount"] = structureAmount }
        }
        if tool == .continuum {
            v["saturations"] = saturations.prefix(inputs.count).map { $0 == 0 ? NSNull() : $0 as Any }
            v["clippingMasks"] = masks.prefix(inputs.count).map { $0.isEmpty ? NSNull() : $0 as Any }
            v["psfMatching"] = psfMatching
            if manual && !analyze { v["manualCoefficients"] = Array(coefficients.prefix(referenceCount)) }
            else if let plan, !analyze { v["plan"] = try JSONSerialization.jsonObject(with: plan) }
        }
        v["targetMedian"] = targetMedian; v["greenReduction"] = greenReduction
        v["starAmount"] = starAmount; v["starReduction"] = starReduction; v["nebulaDisplay"] = nebulaDisplay
        return try JSONSerialization.data(withJSONObject: v, options: [.sortedKeys])
    }
}

struct ColorToolsResult: Sendable {
    let report: Data
    let imageURL: URL?
    var object: [String: Any] { (try? JSONSerialization.jsonObject(with: report)) as? [String: Any] ?? [:] }
    var status: String { object["status"] as? String ?? "invalid" }
    var plan: Data? { (object["plan"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) } }
    var summary: String {
        if status == "skipped" { return "Fit skipped: \(object["detail"] as? String ?? "insufficient validated stars"). No subtraction was built." }
        if status == "fitted", let plan = object["plan"] as? [String: Any] {
            let weights = (plan["coefficients"] as? [Double] ?? []).map { String(format: "%.6g", $0) }.joined(separator: ", ")
            let d = plan["diagnostics"] as? [String: Any] ?? [:]
            return "Review coefficients: \(weights). Validation stars: \(d["validationStars"] ?? "—"); fractional RMS: \(d["validationFractionalRms"] ?? "—"). Build the subtraction preview when satisfied."
        }
        return object["transfer"] as? String == "linear"
            ? "Signed linear residual preview. Negative samples and missing coverage are preserved."
            : "Display preview. Reopening starts with No Stretch. Save preserves the built float samples."
    }
}

/// Serial native calls run off the main actor. Cancellation discards uncommitted results.
actor ColorToolsService {
    static let shared = ColorToolsService()

    static func process(_ data: Data) throws -> Data {
        var error: UnsafeMutablePointer<CChar>?
        let result = String(decoding: data, as: UTF8.self).withCString { seiza_mac_color_tools_json($0, &error) }
        defer { if let result { seiza_string_free(result) }; if let error { seiza_string_free(error) } }
        guard let result else { throw ImageStackError.core(error.map { String(cString: $0) } ?? "Color processing failed.") }
        return Data(String(cString: result).utf8)
    }

    func run(recipe: ColorToolsRecipe, analyze: Bool, plan: Data?, directory: URL) throws -> ColorToolsResult {
        try Task.checkCancellation()
        let output = analyze ? nil : directory.appendingPathComponent("preview.fits")
        let json = try recipe.json(output: output, analyze: analyze, plan: plan)
        let report = try Self.process(json)
        try Task.checkCancellation()
        return ColorToolsResult(report: report, imageURL: output)
    }

    static func protect(_ output: URL, sources: [URL]) throws {
        if sources.contains(where: { StackInputProtection.sameFile(output, $0) }) {
            throw ImageStackError.invalidRequest("Choose a separate destination. An input, clipping mask, plan or preview cannot be replaced.")
        }
    }

    /// Publish only completed data via same-volume staging. Never truncate a destination on failure.
    static func publish(to output: URL, sources: [URL], writer: (URL) throws -> Void) throws {
        try protect(output, sources: sources)
        let directory = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: output, create: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = directory.appendingPathComponent("result").appendingPathExtension(output.pathExtension)
        try writer(staged)
        try Task.checkCancellation()
        try protect(output, sources: sources)
        if FileManager.default.fileExists(atPath: output.path) {
            _ = try FileManager.default.replaceItemAt(output, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: output)
        }
    }

    func save(preview: ColorToolsResult, to output: URL, sources: [URL]) throws {
        guard let image = preview.imageURL, ["fits", "fit", "fts", "xisf"].contains(output.pathExtension.lowercased()) else {
            throw ImageStackError.invalidRequest("Build a preview and choose a FITS or XISF destination.")
        }
        try Self.publish(to: output, sources: sources + [image]) { staged in
            try Task.checkCancellation()
            let json = try JSONSerialization.data(withJSONObject: ["operation": "copy-result", "inputs": [image.path], "output": staged.path])
            _ = try Self.process(json)
        }
    }

    func saveReport(_ report: Data, to output: URL, sources: [URL]) throws {
        try Self.publish(to: output, sources: sources) { try report.write(to: $0) }
    }
}
