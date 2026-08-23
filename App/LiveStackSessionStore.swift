import CryptoKit
import Foundation

// MARK: - Persisted records

enum LiveStackFrameDisposition: Int, Codable, Sendable {
    case accepted = 0
    case rejected = 1
    case unreadable = 2
    case ignored = 3
}

struct LiveStackPersistedFrame: Codable, Equatable, Sendable {
    var path: String
    var disposition: LiveStackFrameDisposition
    var reason: String? = nil
    var exposureSeconds: Double? = nil
    var length: Int64 = 0
    var lastWriteUnixNanoseconds: Int64 = 0
    var processedAtUTC = Date()
    var fileIdentity: String? = nil
}

struct LiveStackCalibrationEpoch: Codable, Equatable, Sendable {
    var startsAtAcceptedFrame: Int
    var biasPath: String? = nil
    var darkPath: String? = nil
    var flatPath: String? = nil
    var darkExposureSeconds: Double? = nil
    var selectedAtUTC = Date()

    var hasAnyMasters: Bool {
        biasPath != nil || darkPath != nil || flatPath != nil
    }
}

/// Everything the app owns about a live session that the opaque native
/// context does not retain: the frame ledger, calibration epochs, exports,
/// SNR telemetry, and the identity used to reject a mismatched restore.
struct LiveStackPersistedState: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var sessionId: String
    var groupId: String
    var groupTitle: String
    var filterName: String? = nil
    var watchFolder: String
    var includesSubdirectories = false
    var outputPath = ""
    var stackOptionsJSON: String
    var createdAtUTC = Date()
    var updatedAtUTC = Date()
    var calibrationHistory: [LiveStackCalibrationEpoch] = []
    var exportedPaths: [String] = []
    var frames: [LiveStackPersistedFrame] = []
    var snrSamples: [LiveStackPersistedSnrSample] = []

    var isValid: Bool {
        schemaVersion == 1
            && !sessionId.trimmingCharacters(in: .whitespaces).isEmpty
            && !groupId.trimmingCharacters(in: .whitespaces).isEmpty
            && !watchFolder.trimmingCharacters(in: .whitespaces).isEmpty
            && exportedPaths.allSatisfy {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }
            && frames.allSatisfy { frame in
                frame.exposureSeconds.map { $0.isFinite && $0 > 0 } ?? true
            }
            && snrSamples.allSatisfy { sample in
                sample.cumulativeExposureSeconds.map { $0.isFinite && $0 >= 0 } ?? true
            }
    }
}

struct LiveStackGenerationManifest: Codable, Sendable {
    var schemaVersion = 1
    var generation: Int64
    var contextFileName: String
    var contextLength: Int64
    var publishedAtUTC = Date()
    var state: LiveStackPersistedState
    var nativeState: LiveStackNativeState

    /// The manifest-level native-state check, weaker than the ABI-read
    /// validation so older manifests stay restorable.
    static func isValidNativeState(_ state: LiveStackNativeState) -> Bool {
        state.schemaVersion == 1
            && state.width > 0 && state.height > 0
            && (state.channels == 1 || state.channels == 3)
            && state.acceptedFrames > 0
            && state.rejectedFrames >= 0
            && state.inputPaths.allSatisfy {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }
    }
}

private struct LiveStackGenerationPointer: Codable {
    var schemaVersion = 1
    var currentGeneration: Int64
    var previousGeneration: Int64? = nil

    var isValid: Bool {
        schemaVersion == 1
            && currentGeneration > 0
            && (previousGeneration.map { $0 > 0 && $0 < currentGeneration } ?? true)
    }
}

private struct LiveStackRetirement: Codable {
    var schemaVersion = 1
    var sessionId: String
    var retiredThroughGeneration: Int64
    var completedAtUTC = Date()

    var isValid: Bool {
        schemaVersion == 1
            && !sessionId.trimmingCharacters(in: .whitespaces).isEmpty
            && retiredThroughGeneration > 0
    }
}

// MARK: - Paths

enum LiveStackSessionPaths {
    static func baseDirectory() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("Seiza", isDirectory: true)
            .appendingPathComponent("LiveStacks", isDirectory: true)
    }

    /// One session root per watch folder: `{readable}-{12 hex}` derived from
    /// the case-folded normalized path.
    static func forWatchFolder(_ watchFolder: String) -> URL {
        let identity = SeizaDigest.pathIdentity(watchFolder, byteCount: 6)
        let leaf = URL(fileURLWithPath: watchFolder).lastPathComponent.lowercased()
        let readable = safeName(leaf, fallback: "capture", maximumLength: 64)
        return baseDirectory().appendingPathComponent("\(readable)-\(identity)")
    }

    static func safeGroupDirectoryName(_ groupId: String) -> String {
        let identity = SeizaDigest.hex(
            SHA256.hash(data: Data(groupId.utf8)), byteCount: 5)
        let readable = safeName(groupId, fallback: "filter", maximumLength: 48)
        return "\(readable)-\(identity)"
    }

    private static func safeName(
        _ value: String, fallback: String, maximumLength: Int
    ) -> String {
        var sanitized = String(
            value.map { character in
                character.isLetter && character.isASCII || character.isNumber && character.isASCII
                    || character == "-" || character == "_"
                    ? character
                    : "-"
            })
        while sanitized.hasPrefix("-") { sanitized.removeFirst() }
        while sanitized.hasSuffix("-") { sanitized.removeLast() }
        if sanitized.isEmpty { sanitized = fallback }
        return String(sanitized.prefix(maximumLength))
    }
}

// MARK: - Store

enum LiveStackSessionStoreError: LocalizedError {
    case alreadyActive(String)
    case invalidContext(String)

    var errorDescription: String? {
        switch self {
        case .alreadyActive(let message), .invalidContext(let message):
            return message
        }
    }
}

/// Generation-based checkpoint persistence for one live-stack group. Every
/// publish writes a fresh manifest plus opaque native context, then flips
/// the pointer; the previous complete generation stays recoverable until
/// the next successful publish.
actor LiveStackSessionStore {
    struct StoredGeneration: Sendable {
        var generation: Int64
        var manifestURL: URL
        var contextURL: URL
    }

    struct RestoreCandidate: Sendable {
        var generation: Int64
        var manifest: LiveStackGenerationManifest
        var manifestURL: URL
        var contextURL: URL
        var usedPreviousGeneration: Bool
    }

    nonisolated let groupDirectory: URL
    private var lockLease: CalibrationFileLease?
    private var lastAuthoritativeGeneration: Int64?

    init(sessionRootDirectory: URL, groupId: String) throws {
        groupDirectory = sessionRootDirectory.appendingPathComponent(
            LiveStackSessionPaths.safeGroupDirectoryName(groupId), isDirectory: true)
        try FileManager.default.createDirectory(
            at: groupDirectory, withIntermediateDirectories: true)
        let lockURL = groupDirectory.appendingPathComponent("session.lock")
        guard let lease = CalibrationFileLease.tryAcquireExclusive(at: lockURL) else {
            throw LiveStackSessionStoreError.alreadyActive(
                "This capture folder already has an active live-stack session, "
                    + "possibly in another window.")
        }
        lockLease = lease
    }

    func close() {
        lockLease?.release()
        lockLease = nil
    }

    // MARK: Publish

    func publish(
        state: LiveStackPersistedState,
        savingContextWith writer: @Sendable (String) async throws -> LiveStackNativeState
    ) async throws -> StoredGeneration {
        guard state.isValid else {
            throw LiveStackSessionStoreError.invalidContext(
                "The live-stack session state is incomplete and cannot be saved.")
        }
        let pointer = readPointer()
        let generation = try nextGeneration(after: pointer)
        let contextName = Self.contextFileName(generation)
        let manifestName = Self.manifestFileName(generation)
        let contextURL = groupDirectory.appendingPathComponent(contextName)
        let manifestURL = groupDirectory.appendingPathComponent(manifestName)

        let nativeState = try await writer(contextURL.path)
        guard LiveStackGenerationManifest.isValidNativeState(nativeState) else {
            throw LiveStackSessionStoreError.invalidContext(
                "The Seiza core reported invalid live-stack state for the checkpoint.")
        }
        try Task.checkCancellation()
        let contextAttributes = try? FileManager.default.attributesOfItem(
            atPath: contextURL.path)
        let contextLength = ((contextAttributes?[.size] as? NSNumber)?.int64Value) ?? 0
        guard contextLength > 0 else {
            throw LiveStackSessionStoreError.invalidContext(
                "The saved live-stack context is empty.")
        }

        let manifest = LiveStackGenerationManifest(
            generation: generation,
            contextFileName: contextName,
            contextLength: contextLength,
            state: state,
            nativeState: nativeState)
        try writeJSONAtomically(Self.encode(manifest), to: manifestURL)

        let previous = lastAuthoritativeGeneration ?? pointer?.currentGeneration
        let newPointer = LiveStackGenerationPointer(
            currentGeneration: generation,
            previousGeneration: previous)
        try writeJSONAtomically(
            Self.encode(newPointer),
            to: groupDirectory.appendingPathComponent("current.json"))

        cleanupOldGenerations(keeping: [generation, previous].compactMap { $0 })
        lastAuthoritativeGeneration = generation
        return StoredGeneration(
            generation: generation,
            manifestURL: manifestURL,
            contextURL: contextURL)
    }

    // MARK: Restore

    func restoreCandidates() -> [RestoreCandidate] {
        let retirement = readRetirement()
        var candidates: [RestoreCandidate] = []
        if let pointer = readPointer() {
            if let current = tryReadCandidate(
                generation: pointer.currentGeneration, usedPrevious: false) {
                candidates.append(current)
            }
            if let previousGeneration = pointer.previousGeneration,
                let previous = tryReadCandidate(
                    generation: previousGeneration, usedPrevious: true) {
                candidates.append(previous)
            }
        } else {
            let generations = knownGenerations().sorted(by: >)
            for (index, generation) in generations.enumerated() {
                if let candidate = tryReadCandidate(
                    generation: generation, usedPrevious: index > 0) {
                    candidates.append(candidate)
                }
            }
        }
        guard let retirement else { return candidates }
        return candidates.filter { candidate in
            !(candidate.generation <= retirement.retiredThroughGeneration
                && candidate.manifest.state.sessionId == retirement.sessionId)
        }
    }

    /// Accepts a restored generation only when it belongs to this store and
    /// the reopened native context describes the same checkpoint; success
    /// makes it the predecessor of the next publish.
    func tryAcceptRestoredGeneration(
        _ candidate: RestoreCandidate,
        actual: LiveStackNativeState
    ) -> Bool {
        let expectedManifest = groupDirectory.appendingPathComponent(
            Self.manifestFileName(candidate.generation))
        let expectedContext = groupDirectory.appendingPathComponent(
            Self.contextFileName(candidate.generation))
        guard LiveStackPath.equals(candidate.manifestURL.path, expectedManifest.path),
            LiveStackPath.equals(candidate.contextURL.path, expectedContext.path),
            candidate.manifest.nativeState.describesSameCheckpoint(actual)
        else { return false }
        lastAuthoritativeGeneration = candidate.generation
        return true
    }

    // MARK: Retire

    func retire(sessionId: String) throws {
        let generation = lastAuthoritativeGeneration
            ?? readPointer()?.currentGeneration
            ?? knownGenerations().max()
            ?? 0
        guard generation > 0 else { return }
        let retirement = LiveStackRetirement(
            sessionId: sessionId,
            retiredThroughGeneration: generation)
        try writeJSONAtomically(
            Self.encode(retirement),
            to: groupDirectory.appendingPathComponent("completed.json"))
    }

    // MARK: Internals

    static func manifestFileName(_ generation: Int64) -> String {
        String(format: "generation-%012lld.json", generation)
    }

    static func contextFileName(_ generation: Int64) -> String {
        String(format: "generation-%012lld.seiza-stack", generation)
    }

    private func nextGeneration(
        after pointer: LiveStackGenerationPointer?
    ) throws -> Int64 {
        let known = knownGenerations()
        let maximum = max(known.max() ?? 0, pointer?.currentGeneration ?? 0)
        return maximum + 1
    }

    private func knownGenerations() -> [Int64] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: groupDirectory, includingPropertiesForKeys: nil)) ?? []
        var generations: Set<Int64> = []
        for url in contents {
            let name = url.lastPathComponent
            guard name.hasPrefix("generation-") else { continue }
            let digits = name.dropFirst("generation-".count).prefix(12)
            guard digits.count == 12, digits.allSatisfy(\.isNumber),
                let generation = Int64(digits)
            else { continue }
            generations.insert(generation)
        }
        return Array(generations)
    }

    private func tryReadCandidate(
        generation: Int64, usedPrevious: Bool
    ) -> RestoreCandidate? {
        let manifestURL = groupDirectory.appendingPathComponent(
            Self.manifestFileName(generation))
        let contextURL = groupDirectory.appendingPathComponent(
            Self.contextFileName(generation))
        guard let data = try? Data(contentsOf: manifestURL),
            let manifest = try? Self.decoder().decode(
                LiveStackGenerationManifest.self, from: data)
        else { return nil }
        guard manifest.schemaVersion == 1,
            manifest.generation == generation,
            manifest.state.isValid,
            LiveStackGenerationManifest.isValidNativeState(manifest.nativeState),
            manifest.contextFileName == Self.contextFileName(generation)
        else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: contextURL.path),
            let size = (attributes[.size] as? NSNumber)?.int64Value,
            size == manifest.contextLength
        else { return nil }
        return RestoreCandidate(
            generation: generation,
            manifest: manifest,
            manifestURL: manifestURL,
            contextURL: contextURL,
            usedPreviousGeneration: usedPrevious)
    }

    private func readPointer() -> LiveStackGenerationPointer? {
        let url = groupDirectory.appendingPathComponent("current.json")
        guard let data = try? Data(contentsOf: url),
            let pointer = try? Self.decoder().decode(
                LiveStackGenerationPointer.self, from: data),
            pointer.isValid
        else { return nil }
        return pointer
    }

    private func readRetirement() -> LiveStackRetirement? {
        let url = groupDirectory.appendingPathComponent("completed.json")
        guard let data = try? Data(contentsOf: url),
            let retirement = try? Self.decoder().decode(
                LiveStackRetirement.self, from: data),
            retirement.isValid
        else { return nil }
        return retirement
    }

    private func cleanupOldGenerations(keeping: [Int64]) {
        let kept = Set(keeping)
        for generation in knownGenerations() where !kept.contains(generation) {
            try? FileManager.default.removeItem(
                at: groupDirectory.appendingPathComponent(
                    Self.manifestFileName(generation)))
            try? FileManager.default.removeItem(
                at: groupDirectory.appendingPathComponent(
                    Self.contextFileName(generation)))
        }
    }

    /// Writes JSON through a same-directory staging file, syncing before the
    /// rename so a torn write can never masquerade as a manifest.
    private func writeJSONAtomically(_ data: Data, to destination: URL) throws {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let staging = groupDirectory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(token).tmp")
        defer { try? FileManager.default.removeItem(at: staging) }
        FileManager.default.createFile(atPath: staging.path, contents: nil)
        let handle = try FileHandle(forWritingTo: staging)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: staging, to: destination)
    }

    private static func encode<Value: Encodable>(_ value: Value) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(value)) ?? Data()
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
