import Foundation

struct SkySolvedFrame: Sendable {
    let url: URL
    let wcs: WCSResult
    let width: Int64
    let height: Int64
}

struct SkyPanel: Identifiable, Sendable {
    let id: String
    let frames: [SkySolvedFrame]
    var title: String { id.replacingOccurrences(of: "panel-", with: "Panel ") }
    var position: String {
        String(format: "RA %.3f°, Dec %.3f°", frames[0].wcs.crval[0], frames[0].wcs.crval[1])
    }
}

struct SkyField: Identifiable, Sendable {
    let id: String
    let panels: [SkyPanel]
}

struct SkySolveFailure: Identifiable, Sendable {
    let url: URL
    let reason: String
    var id: URL { url }
}

/// Input selection only. Native star registration still decides integration eligibility.
enum SkyPanelGrouping {
    static func group(_ frames: [SkySolvedFrame], overlaps: [[Double]]) throws -> [SkyField] {
        guard overlaps.count == frames.count,
            overlaps.allSatisfy({ $0.count == frames.count && $0.allSatisfy { $0.isFinite && (0...1).contains($0) } }) else {
            throw ImageStackError.invalidRequest("Invalid sky-footprint overlap matrix.")
        }
        func coverage(_ i: Int, _ j: Int) -> Double { min(overlaps[i][j], overlaps[j][i]) }
        var panels: [[Int]] = []
        for i in frames.indices.sorted(by: { frames[$0].url.path < frames[$1].url.path }) {
            // Complete-link clustering prevents dither chains swallowing a mosaic.
            if let panel = panels.firstIndex(where: { $0.allSatisfy { coverage(i, $0) >= 0.85 } }) {
                panels[panel].append(i)
            } else { panels.append([i]) }
        }
        var remaining = Set(panels.indices)
        var fields: [SkyField] = []
        while let seed = remaining.min() {
            remaining.remove(seed)
            var connected = [seed]
            var k = 0
            while k < connected.count {
                for other in remaining.sorted() {
                    if panels[connected[k]].contains(where: { i in panels[other].contains { coverage(i, $0) >= 0.05 } }) {
                        remaining.remove(other)
                        connected.append(other)
                    }
                }
                k += 1
            }
            fields.append(SkyField(id: "field-\(fields.count + 1)", panels: connected.sorted().map { p in
                SkyPanel(id: "panel-\(p + 1)", frames: panels[p].map { frames[$0] })
            }))
        }
        return fields
    }
}

struct SkySourceStamp: Equatable, Sendable {
    let size: UInt64
    let modified: Date
    let device: UInt64
    let inode: UInt64
    static func capture(_ url: URL) throws -> Self {
        let a = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        guard let size = a[.size] as? NSNumber, let modified = a[.modificationDate] as? Date,
            let device = a[.systemNumber] as? NSNumber, let inode = a[.systemFileNumber] as? NSNumber else {
            throw ImageStackError.invalidRequest("Could not identify the source file.")
        }
        return Self(size: size.uint64Value, modified: modified, device: device.uint64Value, inode: inode.uint64Value)
    }
}

struct SkyPanelAnalysis: Sendable {
    let fields: [SkyField]
    let failures: [SkySolveFailure]
    let sources: [URL: SkySourceStamp]
    let solved: [SkySolvedFrame]
    let overlaps: [[Double]]

    func sourcesUnchanged(_ selected: [URL]) -> Bool {
        selected.allSatisfy { url in
            guard let stamp = sources[url], let current = try? SkySourceStamp.capture(url) else { return false }
            return stamp == current
        }
    }

    func selectedGroups(_ selected: [URL], splitByFilter: Bool) -> [ImageStackGroup] {
        let selected = Set(selected)
        let index = Dictionary(uniqueKeysWithValues: solved.enumerated().map { ($0.element.url, $0.offset) })
        var outputs: [ImageStackGroup] = []
        for (fieldIndex, field) in fields.enumerated() {
            let urls = field.panels.flatMap(\.frames).map(\.url).filter(selected.contains)
            guard !urls.isEmpty else { continue }
            for filter in ImageStackGrouping.groups(for: urls, splitByFilter: splitByFilter) {
                let indices = filter.inputs.compactMap { index[$0] }
                let frames = indices.map { solved[$0] }
                let matrix = indices.map { i in indices.map { overlaps[i][$0] } }
                // Recompute connectivity using only selected lights of this filter.
                guard let regions = try? SkyPanelGrouping.group(frames, overlaps: matrix) else { continue }
                for (region, component) in regions.enumerated() {
                    let fieldName = "Sky field \(fieldIndex + 1)" + (regions.count > 1 ? " region \(region + 1)" : "")
                    let suffix = "field-\(fieldIndex + 1)" + (regions.count > 1 ? "-region-\(region + 1)" : "")
                        + (filter.filter.map { "-" + $0.filenameSuffix } ?? "")
                    outputs.append(ImageStackGroup(id: "\(field.id)-\(filter.id)-\(region)", filter: filter.filter,
                        inputs: component.panels.flatMap(\.frames).map(\.url), fieldTitle: fieldName, outputSuffix: suffix))
                }
            }
        }
        return outputs
    }
}

enum SkyPanelService {
    static func validateSolution(_ solution: SolveResult) throws {
        guard solution.solvedFrom != "header-unchecked", solution.matchedStars > 0 else {
            throw ImageStackError.invalidRequest("No stars confirmed the image's coordinates.")
        }
    }

    static func analyze(_ urls: [URL], catalog: URL?, progress: @Sendable (String) -> Void) throws -> SkyPanelAnalysis {
        guard (2...512).contains(urls.count) else {
            throw ImageStackError.invalidRequest("Select between 2 and 512 lights to solve and group.")
        }
        let accessed = (urls + [catalog].compactMap { $0 }).filter { $0.startAccessingSecurityScopedResource() }
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
        let status = try SeizaCore.catalogStatus(catalogDirectory: catalog)
        guard status.readyForSolving else {
            throw ImageStackError.invalidRequest("Install solving catalogs in Settings before grouping panels.")
        }
        var solved: [SkySolvedFrame] = []
        var failures: [SkySolveFailure] = []
        var stamps: [URL: SkySourceStamp] = [:]
        for (i, url) in urls.enumerated() {
            try Task.checkCancellation()
            progress("Solving \(i + 1)/\(urls.count): \(url.lastPathComponent)")
            do {
                let before = try SkySourceStamp.capture(url)
                let probe = try CalibrationService.probe(path: url.path)
                guard !probe.isMaster,
                    ![CalibrationFrameRole.bias, CalibrationFrameRole.dark, CalibrationFrameRole.darkFlat, CalibrationFrameRole.flat].contains(probe.role) else {
                    throw ImageStackError.invalidRequest("This is a calibration frame, not a light exposure.")
                }
                guard let width = probe.signature.width, let height = probe.signature.height, width > 0, height > 0 else {
                    throw ImageStackError.invalidRequest("Image dimensions could not be read.")
                }
                let solution = try SeizaCore.solve(url: url, catalogDirectory: catalog)
                try validateSolution(solution)
                guard before == (try SkySourceStamp.capture(url)) else {
                    throw ImageStackError.invalidRequest("The source changed during solving. Solve it again.")
                }
                solved.append(SkySolvedFrame(url: url, wcs: solution.wcs, width: width, height: height))
                stamps[url] = before
            } catch is CancellationError { throw CancellationError() }
            catch { failures.append(SkySolveFailure(url: url, reason: error.localizedDescription)) }
        }
        let matrix = try overlapMatrix(solved, progress: progress)
        try Task.checkCancellation()
        return SkyPanelAnalysis(fields: try SkyPanelGrouping.group(solved, overlaps: matrix), failures: failures,
            sources: stamps, solved: solved, overlaps: matrix)
    }

    static func overlapMatrix(_ frames: [SkySolvedFrame], progress: (String) -> Void = { _ in }) throws -> [[Double]] {
        let footprints: [[String: Any]] = try frames.map { frame in
            let wcs = String(decoding: try JSONEncoder().encode(frame.wcs), as: UTF8.self)
            var error: UnsafeMutablePointer<CChar>?
            defer { if let error { seiza_string_free(error) } }
            guard let header = wcs.withCString({ seiza_wcs_fits_header_json($0, &error) }) else {
                throw ImageStackError.core(CalibrationService.takeOwnedError(&error, fallback: "Invalid WCS."))
            }
            defer { seiza_string_free(header) }
            guard let response = try JSONSerialization.jsonObject(with: Data(bytes: header, count: strlen(header))) as? [String: Any],
                let cards = response["cards"] as? [String: Any] else {
                throw ImageStackError.core("Invalid WCS headers.")
            }
            return ["width": frame.width, "height": frame.height, "wcsHeaders": cards]
        }
        var matrix: [[Double]] = []
        for row in stride(from: 0, to: frames.count, by: 8) {
            try Task.checkCancellation()
            progress("Comparing sky footprints: \(row)/\(frames.count)")
            let request = String(decoding: try JSONSerialization.data(withJSONObject: ["frames": footprints,
                "startRow": row, "rowCount": min(8, frames.count - row)]), as: UTF8.self)
            var error: UnsafeMutablePointer<CChar>?
            defer { if let error { seiza_string_free(error) } }
            guard let result = request.withCString({ seiza_mac_sky_overlaps_json($0, &error) }) else {
                throw ImageStackError.core(CalibrationService.takeOwnedError(&error, fallback: "Could not compare sky footprints."))
            }
            defer { seiza_string_free(result) }
            matrix += try JSONDecoder().decode([[Double]].self, from: Data(bytes: result, count: strlen(result)))
        }
        return matrix
    }
}
