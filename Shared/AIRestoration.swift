import Foundation

struct AIProcessing: Codable, Equatable {
    var model: String?
    var backend: String?
    var precision: String?
    var tile: Int?
    var deviceId: Int?
    var high = 1.0
    var low = 1.0
    var scale = 5.0

    func validate() throws {
        guard (0...1).contains(high), (0...1).contains(low), scale > 0, scale <= 100,
              tile.map({ $0 > 0 }) ?? true, deviceId.map({ $0 >= 0 }) ?? true,
              model.map({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\\") }) ?? true
        else { throw SeizaCoreError.message("Invalid noise model or reduction settings.") }
    }
}

struct AIRegion: Equatable {
    let x, y, width, height: Int

    static func center(width: Int, height: Int) -> Self {
        let w = min(width, 768), h = min(height, 768)
        return Self(x: (width - w) / 2, y: (height - h) / 2, width: w, height: h)
    }
}

final class AICancellation {
    let signal = seiza_cancel_signal_create()
    private let lock = NSLock()
    private var cancelled = false
    func cancel() {
        lock.withLock { cancelled = true }
        seiza_cancel_signal_cancel(signal)
    }
    func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
    deinit { seiza_cancel_signal_free(signal) }
}

/// Each renderer retains its own file lease. Eviction never removes a file still being read.
final class AILinearFile {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".fits")
    deinit { try? FileManager.default.removeItem(at: url) }
}

final class AIRestoration {
    static let shared = AIRestoration()
    static var supported: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }
    struct Model: Decodable {
        let name, path, task, cardSha256: String
    }
    struct Catalog: Decodable {
        struct Entry: Decodable { let name: String }
        struct Latest: Decodable { let denoise: String? }
        let models: [Entry]
        let latest: Latest
    }
    private struct BlendReport: Decodable { let backend: String }
    private struct FileStamp: Equatable {
        let path: String
        let inode, device, bytes: UInt64
        let modified: Date
        init(_ url: URL) throws {
            path = url.resolvingSymlinksInPath().path
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            device = (attrs[.systemNumber] as? NSNumber)?.uint64Value ?? 0
            bytes = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            modified = attrs[.modificationDate] as? Date ?? .distantPast
        }
    }
    private struct Key: Equatable {
        let source: FileStamp
        let files: [FileStamp]
        let model: String
        let backend, precision: String?
        let tile, device: Int?
        let region: AIRegion?
    }
    private final class Residual {
        let pointer: OpaquePointer
        let cost: Int
        init(_ pointer: OpaquePointer, cost: Int) { self.pointer = pointer; self.cost = cost }
        deinit { seiza_file_restoration_free(pointer) }
    }
    private let lock = NSLock()
    private let store: URL
    private var residuals: [(Key, Residual)] = []
    private var blend: (Key, AIProcessing, AILinearFile)?
    private var automaticModel: String?
    init(store: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Seiza/Models", isDirectory: true)) { self.store = store }

    private func native<T: Decodable>(_ type: T.Type, _ call: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> UnsafeMutablePointer<CChar>?) throws -> T {
        var error: UnsafeMutablePointer<CChar>?
        let result = call(&error)
        defer { seiza_string_free(result); seiza_string_free(error) }
        guard let result else { throw failure(error) }
        return try JSONDecoder().decode(type, from: Data(bytes: result, count: strlen(result)))
    }

    private func failure(_ error: UnsafeMutablePointer<CChar>?) -> Error {
        SeizaCoreError.message(error.map { String(cString: $0) } ?? "The noise model could not complete this operation.")
    }
    private func models() throws -> [Model] {
        try native([Model].self) { seiza_model_list_json(store.path, $0) }.filter { $0.task == "denoise" }
    }
    func installed() throws -> [Model] { try lock.withLock { try models() } }
    func catalog() throws -> Catalog { try native(Catalog.self) { seiza_model_catalog_json(nil, $0) } }
    private func download(_ name: String?) throws -> Model {
        try native(Model.self) { seiza_model_download_json(name, store.path, nil, nil, nil, $0) }
    }
    func update(_ name: String?) throws -> Model {
        try lock.withLock { let result = try download(name); automaticModel = nil; return result }
    }
    func importBundle(_ url: URL) throws -> Model {
        try lock.withLock {
            let model = try native(Model.self) { seiza_model_install_json(url.path, store.path, $0) }
            automaticModel = nil
            return model
        }
    }
    func verify(_ name: String) throws {
        try lock.withLock {
            var error: UnsafeMutablePointer<CChar>?
            defer { seiza_string_free(error) }
            guard seiza_model_verify(name, store.path, &error) else { throw failure(error) }
        }
    }
    private func resolve(_ name: String?) throws -> Model {
        let installed = try models()
        if name == nil && automaticModel == nil {
            do { automaticModel = try catalog().latest.denoise }
            catch { guard let first = installed.first else { throw error }; automaticModel = first.name }
        }
        let requested = name ?? automaticModel
        return try installed.first { $0.name == requested } ?? download(requested)
    }

    /// Inference and model replacement are serialized. Blending a different strength reuses the residual.
    func prepare(_ source: URL, settings: AIProcessing, region: AIRegion? = nil, cancel: AICancellation? = nil) throws -> AILinearFile {
        guard Self.supported else { throw SeizaCoreError.message("AI noise reduction requires Apple silicon.") }
        try settings.validate()
        return try lock.withLock {
            try cancel?.check()
            let model = try resolve(settings.model)
            let folder = URL(fileURLWithPath: model.path)
            func key() throws -> Key {
                let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                    .filter { ["onnx", "json"].contains($0.pathExtension) }.sorted { $0.path < $1.path }
                return try Key(source: FileStamp(source), files: files.map(FileStamp.init), model: model.cardSha256,
                               backend: settings.backend, precision: settings.precision, tile: settings.tile,
                               device: settings.deviceId, region: region)
            }
            let initial = try key()
            try cancel?.check()
            if let blend, blend.0 == initial, blend.1 == settings { return blend.2 }
            let residual: Residual
            if let index = residuals.firstIndex(where: { $0.0 == initial }) {
                residual = residuals.remove(at: index).1
                residuals.append((initial, residual))
            } else {
                guard let library = Bundle.main.privateFrameworksURL?.appendingPathComponent("libonnxruntime.dylib"),
                      FileManager.default.isReadableFile(atPath: library.path) else {
                    throw SeizaCoreError.message("The bundled ONNX Runtime is missing. Reinstall Seiza.")
                }
                var options: [String: Any] = ["library": library.path]
                options["backend"] = settings.backend
                options["precision"] = settings.precision
                options["tile"] = settings.tile
                options["deviceId"] = settings.deviceId
                let json = String(decoding: try JSONSerialization.data(withJSONObject: options), as: UTF8.self)
                var error: UnsafeMutablePointer<CChar>?
                defer { seiza_string_free(error) }
                guard let handle = seiza_noise_model_open(model.path, json, &error) else { throw failure(error) }
                defer { seiza_noise_model_free(handle) }
                try cancel?.check()
                let pointer: OpaquePointer?
                if let r = region {
                    pointer = seiza_noise_model_denoise_file_region(handle, source.path, r.x, r.y, r.width, r.height,
                                                                   nil, cancel?.signal, nil, &error)
                } else {
                    pointer = seiza_noise_model_denoise_file(handle, source.path, false, nil, cancel?.signal, nil, &error)
                }
                guard let pointer else { throw failure(error) }
                let maximum = 384 * 1024 * 1024
                let header = try? SeizaCore.readHeader(url: source).headers
                func axis(_ n: Int, fallback: Double) -> Double {
                    if case .number(let value) = header?["NAXIS" + String(n)], value > 0 { return value }
                    return fallback
                }
                let pixels = (region.map { Double($0.width) * Double($0.height) }
                    ?? (axis(1, fallback: .infinity) * axis(2, fallback: .infinity)))
                let cost = pixels * axis(3, fallback: 1) * 24
                residual = Residual(pointer, cost: Int(min(cost, Double(maximum + 1))))
                try cancel?.check()
                if residual.cost <= maximum {
                    while residuals.count >= 2 || residuals.reduce(0, { $0 + $1.1.cost }) + residual.cost > maximum {
                        residuals.removeFirst()
                    }
                    residuals.append((initial, residual))
                }
            }
            try cancel?.check()
            let file = AILinearFile()
            let h = Float(settings.high), l = Float(settings.low), s = Float(settings.scale)
            let _: BlendReport = try native(BlendReport.self) {
                if region != nil {
                    return seiza_file_restoration_write_preview_in_context(residual.pointer, source.path, file.url.path, h, l, s, $0)
                }
                return seiza_file_restoration_write(residual.pointer, file.url.path, nil, h, l, s, $0)
            }
            try cancel?.check()
            guard try initial == key() else { throw SeizaCoreError.message("The image or model changed during noise reduction. Try again.") }
            blend = (initial, settings, file)
            return file
        }
    }
}
