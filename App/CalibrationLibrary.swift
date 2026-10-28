import Foundation
import SwiftUI

/// Lossless policy records. Dictionary keys (including native setting names)
/// are preserved; the app does not translate or duplicate the shared rules.
enum LibraryJSON: Codable, Hashable, Sendable {
    case object([String: LibraryJSON]), array([LibraryJSON]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([LibraryJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: LibraryJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    // Preferences written before the C ABI migration retain native snake_case
    // records. Read either spelling; send current C fields only at the boundary.
    static func camel(_ key: String) -> String {
        let parts = key.split(separator: "_")
        return (parts.first.map(String.init) ?? "") + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }
    subscript(_ key: String) -> LibraryJSON {
        if case .object(let values) = self { return values[key] ?? values[Self.camel(key)] ?? .null }
        return .null
    }
    var cabiFields: LibraryJSON {
        switch self {
        case .array(let values): return .array(values.map(\.cabiFields))
        case .object(let values):
            var result: [String: LibraryJSON] = [:]
            for (key, value) in values {
                let name = Self.camel(key)
                if key == name || values[name] == nil { result[name] = key == "value" ? value : value.cabiFields }
            }
            return .object(result)
        default: return self
        }
    }
    var array: [LibraryJSON] { if case .array(let v) = self { return v }; return [] }
    var text: String { if case .string(let v) = self { return v }; return "" }
    var number: Double? { if case .number(let v) = self { return v }; return nil }
    var boolean: Bool { if case .bool(let v) = self { return v }; return false }
    var json: String { get throws { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) } }
}
struct LibrarySource: Codable, Sendable { let path: String; let fingerprint: String }
struct LibraryChoice: Codable, Equatable, Sendable { let path: String; let fingerprint: String; let choice: String }
struct LibraryLightChoice: Codable, Equatable, Sendable {
    let path: String
    let fingerprint: String
    let row: LibraryJSON
}
struct LibrarySetting: Codable, Sendable { let key: String; let value: LibraryJSON }
struct LibraryRigSettings: Encodable, Sendable {
    let rig_uuid: String
    let settings: [LibrarySetting]
    enum CodingKeys: String, CodingKey { case rig_uuid = "rigUuid", settings }
}
enum LibraryAssociation: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, oneSet = "one_set"
    var id: Self { self }
    var title: String { self == .automatic ? "Group and match automatically" : "Use all as one set" }
}
struct LibraryPreferences: Codable, Equatable, Sendable {
    var settings: [String: LibraryJSON] = [:]
    var rigs: [String: [String: LibraryJSON]] = [:]
    var choices: [LibraryChoice] = []
    var groupOverrides: [LibraryJSON] = []
    var lightChoices: [LibraryLightChoice] = []
    var incomplete = "stop"
    var flatAssociation = LibraryAssociation.automatic
    var darkAssociation = LibraryAssociation.automatic
    var flatStarMasking = false
    var flatStability: LibraryJSON = .object([
        "enabled": .bool(true), "trim_unstable": .bool(true),
        "try_next_session": .bool(true), "retain_unstable": .bool(true)])
    enum CodingKeys: String, CodingKey {
        case settings, rigs, choices, groupOverrides, lightChoices, incomplete, flatStarMasking, flatStability, flatAssociation, darkAssociation
    }
    init() {}
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        settings = try c.decodeIfPresent([String: LibraryJSON].self, forKey: .settings) ?? settings
        rigs = try c.decodeIfPresent([String: [String: LibraryJSON]].self, forKey: .rigs) ?? rigs
        choices = try c.decodeIfPresent([LibraryChoice].self, forKey: .choices) ?? choices
        groupOverrides = try c.decodeIfPresent([LibraryJSON].self, forKey: .groupOverrides) ?? groupOverrides
        lightChoices = try c.decodeIfPresent([LibraryLightChoice].self, forKey: .lightChoices) ?? lightChoices
        incomplete = try c.decodeIfPresent(String.self, forKey: .incomplete) ?? incomplete
        flatStarMasking = try c.decodeIfPresent(Bool.self, forKey: .flatStarMasking) ?? flatStarMasking
        flatStability = try c.decodeIfPresent(LibraryJSON.self, forKey: .flatStability) ?? flatStability
        flatAssociation = try c.decodeIfPresent(LibraryAssociation.self, forKey: .flatAssociation) ?? flatAssociation
        darkAssociation = try c.decodeIfPresent(LibraryAssociation.self, forKey: .darkAssociation) ?? darkAssociation
    }
    /// This execution policy does not change Seiza's reviewed matches or key.
    var reviewInputs: Self {
        var inputs = self
        inputs.incomplete = "stop"
        return inputs
    }
    static func load(_ defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "gradedCalibrationPreferences.v1"),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
}
struct LibraryFrame: Decodable, Identifiable, Sendable {
    let path: String; let fingerprint: String; let id: String; let kind: String
    let isMaster: Bool; let grade: String?; let reason: String?; let measurementState: String; let error: String?
}
struct LibraryRig: Decodable, Identifiable, Sendable { let id: String; let name: String }
struct LibraryField: Decodable, Identifiable, Sendable {
    let key: String; let group: String; let label: String; let help: String
    let kind: LibraryJSON; let `default`: LibraryJSON
    var id: String { key }
}
struct LibraryFileSession: Codable, Sendable {
    let bias: String?; let dark: String?; let flat: String?
    let darkExposureSeconds: Double?; let pedestal: Double?; let normalizedFullScale: Double?
    let tolerances: LibraryJSON
    enum CodingKeys: String, CodingKey {
        case bias, dark, flat, pedestal, tolerances
        case darkExposureSeconds, normalizedFullScale
    }
    var calibration: ImageStackCalibration {
        ImageStackCalibration(bias: bias.map { URL(fileURLWithPath: $0) },
            dark: dark.map { URL(fileURLWithPath: $0) }, flat: flat.map { URL(fileURLWithPath: $0) },
            overridesDarkExposure: dark != nil && darkExposureSeconds != nil,
            darkExposureSeconds: darkExposureSeconds ?? 0)
    }
    func apply(to handle: OpaquePointer) throws {
        guard pedestal == nil, normalizedFullScale == nil else {
            throw ImageStackError.core("This file session requires the session-aware opener.")
        }
        var gate = SeizaMatchTolerances()
        seiza_match_tolerances_default(&gate)
        gate.known = UInt32(SEIZA_TOLERANCE_HAS_EXPOSURE | SEIZA_TOLERANCE_HAS_EXPOSURE_FRACTION
            | SEIZA_TOLERANCE_HAS_DARK_TEMPERATURE | SEIZA_TOLERANCE_HAS_MASTER_TEMPERATURE
            | SEIZA_TOLERANCE_HAS_ROTATION | SEIZA_TOLERANCE_HAS_FOCAL_LENGTH | SEIZA_TOLERANCE_HAS_FLAT_SESSION)
        gate.exposure_seconds = tolerances["exposure_seconds"].number ?? gate.exposure_seconds
        gate.exposure_fraction = tolerances["exposure_fraction"].number ?? gate.exposure_fraction
        gate.dark_temperature_c = tolerances["dark_temperature_c"].number ?? gate.dark_temperature_c
        gate.master_temperature_c = tolerances["master_temperature_c"].number ?? gate.master_temperature_c
        gate.rotation_deg = tolerances["rotation_deg"].number ?? gate.rotation_deg
        gate.focal_length_mm = tolerances["focal_length_mm"].number ?? gate.focal_length_mm
        gate.flat_session_seconds = UInt64(tolerances["flat_session_seconds"].number ?? Double(gate.flat_session_seconds))
        if tolerances["allow_flat_gain_offset_mismatch"].boolean { gate.known |= UInt32(SEIZA_TOLERANCE_ALLOW_FLAT_GAIN_OFFSET_MISMATCH) }
        try call { seiza_live_stacker_set_match_tolerances(handle, &gate, &$0) }
        let rotation = tolerances["light_rotation"]
        let basis: UInt32 = rotation["basis"].text == "measured" ? UInt32(SEIZA_LIGHT_ROTATION_MEASURED)
            : rotation["basis"].text == "unknown" ? UInt32(SEIZA_LIGHT_ROTATION_UNKNOWN) : UInt32(SEIZA_LIGHT_ROTATION_RECORDED)
        try call { seiza_live_stacker_set_light_rotation(handle, basis, rotation["degrees"].number ?? 0, &$0) }
        try call { failure in
            withOptionalCString(bias) { bias in withOptionalCString(dark) { dark in withOptionalCString(flat) { flat in
                seiza_live_stacker_set_calibration_fits(handle, bias, dark, flat, darkExposureSeconds ?? 0, &failure)
            } } }
        }
    }
    private func call(_ operation: (inout UnsafeMutablePointer<CChar>?) -> Bool) throws {
        var failure: UnsafeMutablePointer<CChar>?
        let success = operation(&failure)
        defer { if let failure { seiza_string_free(failure) } }
        if !success { throw ImageStackError.core(failure.map { String(cString: $0) } ?? "Could not apply the calibration session.") }
    }
}
struct LibraryReview: Decodable, Sendable {
    let reviewKey: String; let frames: [LibraryFrame]; let rigs: [LibraryRig]; let snapshot: LibraryJSON; let grouping: LibraryJSON; let flatWork: LibraryJSON; let lightOptions: [LibraryJSON]
    let warnings: [String]; let missing: [Bool]; let paths: [String]; let lightPaths: [String]
    let fileSessions: [LibraryFileSession]; let sources: [LibrarySource]
    var assignments: [Int] { snapshot["assignments"].array.compactMap { $0.number.map(Int.init) } }
    var sessionCount: Int { snapshot["sessions"].array.count }
}
struct LibraryRequest: Encodable, Sendable {
    var operation: String
    var library: String = ""
    var lights: [String] = []
    var provided: [String] = []
    var flatAssociation = LibraryAssociation.automatic
    var darkAssociation = LibraryAssociation.automatic
    var cache: String = ""
    var settings: [LibrarySetting] = []
    var rigs: [LibraryRigSettings] = []
    var choices: [LibraryChoice] = []
    var groupOverrides: [LibraryJSON] = []
    var lightChoices: [LibraryLightChoice] = []
    var reviewKey: String?
    var incomplete = "stop"
    var sources: [LibrarySource] = []
    var accessURLs: [URL] = []
    enum CodingKeys: String, CodingKey {
        case operation, library, lights, provided, cache, settings, rigs, choices, groupOverrides, lightChoices, reviewKey, incomplete, sources, flatStarMasking, flatStability, flatAssociation, darkAssociation
    }
    var flatStarMasking = false
    var flatStability: LibraryJSON = LibraryPreferences().flatStability
    init(operation: String, library: URL? = nil, lights: [URL] = [], provided: [URL] = [], preferences: LibraryPreferences = .init(), reviewKey: String? = nil) {
        self.operation = operation; self.library = library?.path ?? ""; self.lights = lights.map(\.path)
        self.provided = provided.map(\.path)
        self.accessURLs = lights + provided + [library].compactMap { $0 }
        self.cache = CalibrationCachePaths.forLibrary(library?.path ?? "provided-calibration-frames").appendingPathComponent("graded-library").path
        settings = preferences.settings.sorted { $0.key < $1.key }.map { LibrarySetting(key: $0.key, value: $0.value) }
        rigs = preferences.rigs.sorted { $0.key < $1.key }.map { id, values in
            LibraryRigSettings(rig_uuid: id, settings: values.sorted { $0.key < $1.key }.map { LibrarySetting(key: $0.key, value: $0.value) })
        }
        groupOverrides = preferences.groupOverrides.map(\.cabiFields)
        lightChoices = preferences.lightChoices.map { .init(path: $0.path, fingerprint: $0.fingerprint, row: $0.row.cabiFields) }
        choices = preferences.choices; self.reviewKey = reviewKey; incomplete = preferences.incomplete
        flatStarMasking = preferences.flatStarMasking; flatStability = preferences.flatStability.cabiFields
        flatAssociation = preferences.flatAssociation; darkAssociation = preferences.darkAssociation
    }
}
enum CalibrationLibraryService {
    static func call(_ request: LibraryRequest, cancellation: CalibrationCancelSignal? = nil) throws -> Data {
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        var failure: UnsafeMutablePointer<CChar>?
        let result = json.withCString { request in
            seiza_calibration_files_json(request, cancellation?.pointer, nil, nil, &failure)
        }
        defer { if let result { seiza_string_free(result) }; if let failure { seiza_string_free(failure) } }
        if cancellation?.wasCancelled == true { throw CancellationError() }
        guard let result else { throw CalibrationServiceError.core(failure.map { String(cString: $0) } ?? "Could not prepare calibration.") }
        return Data(bytes: result, count: strlen(result))
    }
    static func perform(_ request: LibraryRequest) async throws -> LibraryReview {
        let cancellation = try CalibrationCancelSignal()
        return try await withTaskCancellationHandler {
            let task = Task.detached(priority: .userInitiated) {
                let urls = request.accessURLs
                let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
                defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
                let data = try call(request, cancellation: cancellation)
                let review = try JSONDecoder().decode(LibraryReview.self, from: data)
                guard review.lightOptions.count == request.lights.count, review.paths.count == request.lights.count, review.missing.count == review.paths.count, review.lightPaths.count == review.paths.count,
                    review.assignments.count == review.paths.count,
                    review.snapshot["selections"].array.count == review.paths.count,
                    review.assignments.allSatisfy({ (0..<review.sessionCount).contains($0) }),
                    request.operation != "execute" || review.fileSessions.count == review.sessionCount else {
                    throw CalibrationServiceError.invalidResponse("The calibration assignment plan is incomplete.")
                }
                return review
            }
            return try await task.value
        } onCancel: { cancellation.cancel() }
    }
    static func verify(_ sources: [LibrarySource]) throws {
        var request = LibraryRequest(operation: "verify"); request.sources = sources
        _ = try call(request)
    }
}
struct LibraryPreparedPlan: Sendable {
    let review: LibraryReview
    let originalPaths: [String]
    let accessURLs: [URL]
    init(review: LibraryReview, originalPaths: [String], accessURLs: [URL] = []) {
        self.review = review; self.originalPaths = originalPaths; self.accessURLs = accessURLs
    }
    func index(_ path: String) throws -> Int {
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let index = review.paths.firstIndex(of: canonical) ?? originalPaths.firstIndex(where: {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == canonical
        }) else { throw ImageStackError.invalidRequest("A light is missing from the reviewed calibration plan.") }
        return index
    }
    func session(for path: String) throws -> LibraryFileSession { review.fileSessions[review.assignments[try index(path)]] }
    func prepared(_ input: URL) throws -> URL { URL(fileURLWithPath: review.paths[try index(input.path)]) }
    func verifyActiveSources(for path: String) throws {
        let i = try index(path)
        let session = review.fileSessions[review.assignments[i]]
        let names = Set([review.paths[i], URL(fileURLWithPath: originalPaths[i]).resolvingSymlinksInPath().path]
            + [session.bias, session.dark, session.flat].compactMap { $0 })
        try CalibrationLibraryService.verify(review.sources.filter { names.contains($0.path) })
    }
    func preparedInputs(_ inputs: [URL], excludeIncomplete: Bool) throws -> [URL] {
        try inputs.filter { input in
            if !excludeIncomplete { return true }
            return !review.missing[try index(input.path)]
        }.map { try prepared($0) }
    }
}

@MainActor final class CalibrationLibraryModel: ObservableObject {
    @Published var preferences = LibraryPreferences.load() {
        didSet {
            if preferences.reviewInputs != oldValue.reviewInputs { invalidate() }
            if let data = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data, forKey: "gradedCalibrationPreferences.v1") }
        }
    }
    @Published var fields: [LibraryField] = []
    @Published var review: LibraryReview?
    @Published var busy = false
    @Published var stale = true
    @Published var error: String?
    var task: Task<Void, Never>?
    private var generation = UUID()
    func invalidate() { generation = UUID(); stale = true; task?.cancel(); busy = false }
    func loadSchema() {
        do {
            struct Schema: Decodable { let settings: [LibraryField] }
            fields = try JSONDecoder().decode(Schema.self, from: CalibrationLibraryService.call(LibraryRequest(operation: "schema"))).settings
        } catch { self.error = error.localizedDescription }
    }
    func analyze(library: URL?, lights: [URL], provided: [URL] = [], debounce: Bool = false) {
        invalidate(); busy = true; error = nil
        let current = generation
        let request = LibraryRequest(operation: "analyze", library: library, lights: lights, provided: provided, preferences: preferences)
        task = Task {
            do {
                if debounce { try await Task.sleep(for: .milliseconds(350)) }
                try Task.checkCancellation()
                let result = try await CalibrationLibraryService.perform(request)
                guard current == generation else { return }
                review = result; stale = false
            } catch {
                guard current == generation else { return }
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
            if current == generation { busy = false }
        }
    }
    func chooseGroupEdge(_ edge: LibraryJSON, choice: String?) {
        let row = edge["row"]
        preferences.groupOverrides.removeAll { $0["session_key"] == row["session_key"] && $0["family_key"] == row["family_key"] }
        if let choice, case .object(var values) = row.cabiFields {
            values["choice"] = .string(choice)
            values["chosenAt"] = .number(Date().timeIntervalSince1970.rounded(.down))
            preferences.groupOverrides.append(.object(values))
        }
    }
    func clearGroupChoice(_ row: LibraryJSON) {
        preferences.groupOverrides.removeAll { $0["anchor_frame"] == row["anchor_frame"] && $0["session_key"] == row["session_key"] }
    }
    func chooseLight(_ options: LibraryJSON, change: LibraryJSON? = nil, group: LibraryJSON? = nil, side: String? = nil) {
        let path = options["path"].text
        let key = change?["key"].text ?? "group"
        preferences.lightChoices.removeAll { $0.path == path && $0.row["change_key"].text == key }
        guard group != nil || side != nil else { return }
        let label = group?["label"].text ?? "\(side?.capitalized ?? "") of measured change"
        let row: LibraryJSON = .object([
            "light_guid": options["guid"], "change_key": .string(key), "rig_uuid": options["rig_uuid"],
            "change_start": change?["start"] ?? .null, "change_end": change?["end"] ?? .null,
            "choice": .string(side ?? "group"), "group_frame": group?["frame"] ?? .null,
            "group_session_key": group?["session_key"] ?? .null, "label": .string(label),
            "chosen_at": .number(Date().timeIntervalSince1970.rounded(.down))])
        preferences.lightChoices.append(.init(path: path, fingerprint: options["fingerprint"].text, row: row))
    }
    func clearLightChoices(_ options: LibraryJSON) {
        preferences.lightChoices.removeAll { $0.path == options["path"].text }
    }
    func choose(_ frame: LibraryFrame, _ choice: String?) {
        preferences.choices.removeAll { $0.path == frame.path }
        if let choice { preferences.choices.append(LibraryChoice(path: frame.path, fingerprint: frame.fingerprint, choice: choice)) }
    }
}

struct CalibrationLibrarySettingsView: View {
    @ObservedObject var model: CalibrationLibraryModel
    @State private var scope = ""
    var body: some View {
        DisclosureGroup("Calibration matching and grading settings") {
            Picker("Settings for", selection: $scope) {
                Text("All rigs").tag("")
                ForEach(model.review?.rigs ?? []) { Text($0.name).tag($0.id) }
            }
            ForEach(["matching", "darks", "flat_groups", "grades"], id: \.self) { group in
                DisclosureGroup(group.replacingOccurrences(of: "_", with: " ").capitalized) {
                    ForEach(model.fields.filter { $0.group == group && !["night_zone", "light_nights"].contains($0.key) }) { field in
                        VStack(alignment: .leading, spacing: 4) {
                            control(field)
                            Text(field.help).font(.caption).foregroundStyle(.secondary)
                            if values[field.key] != nil {
                                Button(scope.isEmpty ? "Use default" : "Inherit global setting") { update(field.key, nil) }.font(.caption)
                            }
                        }.padding(.vertical, 3)
                    }
                }
            }
            Text("Automatic flats use measured response groups and capture times. One-set mode retains every eligible compatible input across nights. Grades and explicit exclusions still apply.").font(.caption).foregroundStyle(.secondary)
            Toggle("Mask stars when building flats", isOn: $model.preferences.flatStarMasking)
            ForEach([("enabled", "Check flat-set stability"), ("trim_unstable", "Retry without drifting flats"),
                ("try_next_session", "Try another flat session"), ("retain_unstable", "Keep unstable flats with a warning")], id: \.0) { key, label in
                Toggle(label, isOn: Binding(get: { key == "try_next_session" && model.preferences.flatAssociation == .oneSet ? false : model.preferences.flatStability[key].boolean }, set: { enabled in
                    var values = ["enabled", "trim_unstable", "try_next_session", "retain_unstable"].reduce(into: [String: LibraryJSON]()) { $0[$1] = model.preferences.flatStability[$1] }
                    values[key] = .bool(enabled); model.preferences.flatStability = .object(values)
                })).disabled(key == "try_next_session" && model.preferences.flatAssociation == .oneSet)
            }
        }
        .task { if model.fields.isEmpty { model.loadSchema() } }
    }
    private var values: [String: LibraryJSON] { scope.isEmpty ? model.preferences.settings : model.preferences.rigs[scope] ?? [:] }
    private func value(_ field: LibraryField) -> LibraryJSON { values[field.key] ?? model.preferences.settings[field.key] ?? field.default }
    private func update(_ key: String, _ value: LibraryJSON?) {
        if scope.isEmpty { model.preferences.settings[key] = value }
        else { model.preferences.rigs[scope, default: [:]][key] = value }
    }
    @ViewBuilder private func control(_ field: LibraryField) -> some View {
        switch field.kind["type"].text {
        case "toggle": Toggle(field.label, isOn: Binding(get: { value(field).boolean }, set: { update(field.key, .bool($0)) }))
        case "choice":
            Picker(field.label, selection: Binding(get: { value(field).text }, set: { update(field.key, .string($0)) })) {
                ForEach(field.kind["options"].array, id: \.self) { Text($0["label"].text).tag($0["value"].text) }
            }
        case "limits":
            Text(field.label).font(.callout)
            ForEach(["suspect", "poor"], id: \.self) { level in
                let multiplier = field.kind["percent"].boolean ? 100.0 : 1.0
                HStack {
                    Toggle(level.capitalized, isOn: Binding(get: { value(field)[level] != .null }, set: { enabled in
                        var dict: [String: LibraryJSON] = ["suspect": value(field)["suspect"], "poor": value(field)["poor"]]
                        dict[level] = enabled ? field.default[level] == .null ? .number(0) : field.default[level] : .null
                        update(field.key, .object(dict))
                    }))
                    if value(field)[level] != .null {
                        TextField(level.capitalized, value: Binding(get: { (value(field)[level].number ?? 0) * multiplier }, set: { number in
                            var dict: [String: LibraryJSON] = ["suspect": value(field)["suspect"], "poor": value(field)["poor"]]
                            dict[level] = .number(number / multiplier); update(field.key, .object(dict))
                        }), format: .number).frame(width: 100)
                    }
                    Text(field.kind["unit"].text).foregroundStyle(.secondary)
                }
            }
        default:
            HStack {
                TextField(field.label, value: Binding(get: { value(field).number ?? 0 }, set: { update(field.key, .number($0)) }), format: .number)
                Text(field.kind["unit"].text).foregroundStyle(.secondary)
            }
        }
    }
}

struct CalibrationLibraryReviewView: View {
    @ObservedObject var model: CalibrationLibraryModel
    let library: URL?
    let lights: [URL]
    var provided: [URL] = []
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Calibration library").font(.title2)
                Spacer()
                Button("Analyze again") { model.analyze(library: library, lights: lights, provided: provided) }.disabled(model.busy)
                Button("Done") { dismiss() }
            }
            if model.busy { ProgressView("Measuring and matching calibration…") }
            if model.stale { Text("The plan needs analysis before it can be used.").foregroundStyle(.orange) }
            if let error = model.error { Text(error).foregroundStyle(.red) }
            TabView {
                Table(model.review?.frames ?? []) {
                    TableColumn("Frame") { Text(URL(fileURLWithPath: $0.path).lastPathComponent).help($0.path) }
                    TableColumn("Kind", value: \.kind)
                    TableColumn("Grade") { Text($0.isMaster ? "Existing master" : $0.grade?.capitalized ?? "Ungraded") }
                    TableColumn("Reason") { Text($0.error ?? $0.reason ?? $0.measurementState) }
                    TableColumn("Choice") { frame in
                        Menu(model.preferences.choices.first { $0.path == frame.path && $0.fingerprint == frame.fingerprint }.map { $0.choice == "use" ? "Use anyway" : "Keep out" } ?? "Automatic") {
                            Button("Keep out") { model.choose(frame, "exclude") }
                            Button("Use anyway") { model.choose(frame, "use") }
                            Button("Clear choice") { model.choose(frame, nil) }
                        }
                    }
                }.tabItem { Text("Calibration frames") }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if let review = model.review {
                            ForEach(Array(review.lightPaths.enumerated()), id: \.offset) { index, path in
                                Text(URL(fileURLWithPath: path).lastPathComponent).font(.headline).help(path)
                                Text(review.missing[index] ? "Incomplete calibration" : "Matched session \(review.assignments[index] + 1)")
                                let selection = review.snapshot["selections"].array[index]
                                Text("Flat association: \(selection["flat_basis"]["basis"].text.replacingOccurrences(of: "_", with: " "))").font(.caption)
                                if !selection["flat_family"]["by"].text.isEmpty {
                                    Text("Flat family: \(selection["flat_family"]["by"].text.capitalized)").font(.caption)
                                }
                                lightChoices(review.lightOptions[index])
                                ForEach(selection["flat_choices"].array, id: \.self) { choice in
                                    Text(choice["orphaned"].text.isEmpty ? choice["label"].text : choice["orphaned"].text).font(.caption).foregroundStyle(.secondary)
                                }
                                ForEach(["bias", "dark", "dark_flat", "flat"], id: \.self) { kind in
                                    let names = selection[kind].array.compactMap { id in review.frames.first { $0.id == id.text } }.map { URL(fileURLWithPath: $0.path).lastPathComponent }
                                    Text("\(kind.replacingOccurrences(of: "_", with: " ").capitalized): \(names.isEmpty ? "None" : names.joined(separator: ", "))").font(.caption)
                                }
                                Divider()
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding()
                }.tabItem { Text("Light matches") }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array((model.review?.snapshot["sessions"].array ?? []).enumerated()), id: \.offset) { index, session in
                            Text("Session \(index + 1)").font(.headline)
                            ForEach(Array(session["recipes"].array.enumerated()), id: \.offset) { _, recipe in
                                Text("\(recipe["kind"].text.capitalized): \(recipe["action"].text), \(recipe["inputs"].array.count) input(s)")
                                if !recipe["failure"].text.isEmpty { Text(recipe["failure"].text).font(.caption).foregroundStyle(.orange) }
                            }
                            Text("Flat application: \(session["application"]["flat_use"].text.replacingOccurrences(of: "_", with: " "))").font(.caption)
                            Divider()
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding()
                }.tabItem { Text("Master plan") }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if model.preferences.flatAssociation == .oneSet {
                            Text("All eligible compatible flats use one set.")
                        }
                        if let grouping = model.review?.grouping {
                            Text("\(model.review?.flatWork["corrections"].array.count ?? 0) planned flat corrections").font(.headline)
                            ForEach(model.review?.flatWork["corrections"].array ?? [], id: \.self) { correction in
                                Text("Carry flats to the \(correction["correction"]["light_side"].text) side of a measured change for \(correction["light_indices"].array.count) lights.").font(.caption)
                            }
                            ForEach(model.review?.flatWork["grouping"]["evidence"].array ?? [], id: \.self) { evidence in
                                Text("Light evidence: \(evidence["verdict"].text.capitalized)").font(.headline)
                                ForEach(evidence["fits"].array, id: \.self) { fit in
                                    Text("\(fit["filter"].text): \(fit["verdict"].text), \(Int(fit["lights"].number ?? 0)) sampled lights").font(.caption)
                                }
                            }
                            ForEach(model.review?.flatWork["group_edges"].array ?? [], id: \.self) { edge in
                                HStack {
                                    Text(edge["label"].text).font(.caption)
                                    Menu("Group edge") {
                                        Button("Split here") { model.chooseGroupEdge(edge, choice: "split") }
                                        Button("Join with previous group") { model.chooseGroupEdge(edge, choice: "join") }
                                        Button("Use measured grouping") { model.chooseGroupEdge(edge, choice: nil) }
                                    }.disabled(model.busy || model.stale)
                                }
                            }
                            ForEach(model.review?.flatWork["overrides"].array ?? [], id: \.self) { state in
                                HStack {
                                    Text(state["row"]["label"].text).font(.caption)
                                    Text(state["status"]["status"].text.capitalized).font(.caption)
                                    if !state["status"]["reason"].text.isEmpty { Text(state["status"]["reason"].text).font(.caption) }
                                    Button("Clear") { model.clearGroupChoice(state["row"]) }.disabled(model.busy)
                                }
                            }
                            Text("\(grouping["sessions"].array.count) measured flat sessions · \(grouping["families"].array.count) response families · \(grouping["events"].array.count) changes").font(.headline)
                            ForEach(Array(grouping["sessions"].array.enumerated()), id: \.offset) { index, session in
                                Text("Flat session \(index + 1): \(session["frame_uuids"].array.count) frames").font(.headline)
                                Text(session["night"].text)
                                Text(session["frame_uuids"].array.compactMap { id in model.review?.frames.first { $0.id == id.text } }.map { URL(fileURLWithPath: $0.path).lastPathComponent }.joined(separator: ", ")).font(.caption)
                                Divider()
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding()
                }.tabItem { Text("Flat groups") }
                Form { CalibrationLibrarySettingsView(model: model) }.tabItem { Text("Settings") }
            }
            ScrollView { VStack(alignment: .leading) { ForEach(model.review?.warnings ?? [], id: \.self) { Text($0).font(.caption) } } }.frame(maxHeight: 85)
        }.padding().frame(minWidth: 820, idealWidth: 1000, minHeight: 540, idealHeight: 650)
    }
    @ViewBuilder private func lightChoices(_ options: LibraryJSON) -> some View {
        Menu("Flat choices") {
            Button("Use automatic choices") { model.clearLightChoices(options) }
            ForEach(options["changes"].array, id: \.self) { change in
                Menu("Change \(change["key"].text.prefix(8))") {
                    Button("Before change") { model.chooseLight(options, change: change, side: "before") }
                    Button("After change") { model.chooseLight(options, change: change, side: "after") }
                    Button("Use automatic side") { model.chooseLight(options, change: change) }
                }
            }
            Menu("Use a flat group") {
                ForEach(options["groups"].array, id: \.self) { group in
                    Button(group["label"].text) { model.chooseLight(options, group: group) }
                }
            }
        }.disabled(model.busy || model.stale)
    }

}
