import AppKit
import SwiftUI
import XCTest
@testable import Seiza

final class ImagePathListTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ path: String, _ text: String = "") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url.standardizedFileURL
    }

    func testTXTResolvesAbsoluteRelativeAndParentPathsInListOrder() throws {
        let first = try write("z frame.fits")
        let second = try write("night/a.xisf")
        let list = try write("lists/images.TXT", "\n  \"\(first.path)\" \r\n../night/a.xisf\n../night/./a.xisf\nmissing.fits\nnotes.txt\n")
        let scan = try ImageCollection.scan(from: [list])
        XCTAssertEqual(scan.images, [first, second])
        XCTAssertTrue(scan.includesList)
        XCTAssertFalse(scan.includesDirectory)
        XCTAssertEqual(scan.issues.count, 2)
        XCTAssertEqual(Set(scan.issues.compactMap(\.line)), [5, 6])
    }

    func testCSVRecognizesAllHeaderAliasesWithCaseAndWhitespace() throws {
        let image = try write("frame.FIT")
        for header in ["path", "file_path", "FilePath", "file", "FileName", " FILE ", " File_Path "] {
            let list = try write("images.csv", "rating,\(header)\r\n5,frame.FIT\r\n")
            let scan = try ImageCollection.scan(from: [list])
            XCTAssertEqual(scan.images, [image], header)
            XCTAssertTrue(scan.issues.isEmpty, header)
        }
    }

    func testCSVHandlesQuotedCommasEscapedQuotesAndMultilineFields() throws {
        let image = try write("frame, \"one\".FITS")
        let list = try write("images.csv", "rating,filepath,note\r\n5,\"frame, \"\"one\"\".FITS\",\"a\nmultiline note\"\r\n4,missing.fits,no\n3\n")
        let scan = try ImageCollection.scan(from: [list])
        XCTAssertEqual(scan.images, [image])
        XCTAssertEqual(Set(scan.issues.compactMap(\.line)), [4, 5])
    }

    func testHeaderlessCSVUsesOnlyFirstColumnAndDoesNotSwitchAfterImageData() throws {
        let first = try write("first.png")
        let second = try write("other.fits")
        let list = try write("images.csv", "first.png,other.fits\nfirst.png,duplicate\nother.fits,File\n")
        let scan = try ImageCollection.scan(from: [list])
        XCTAssertEqual(scan.images, [first, second])
        XCTAssertTrue(scan.issues.isEmpty)
    }

    func testSubframeSelectorPreambleAndApprovalFlags() throws {
        let first = try write("approved.fits")
        let second = try write("rejected.fits")
        let list = try write("subframes.csv", "SubframeSelector 1.9\nSubframe Scale,1.25\nCamera Gain,0.7\nApproval expression,\"FWHM < 5\"\n\nIndex,Approved,Locked,File,Weight\n1,true,false,approved.fits,1\n2,false,true,rejected.fits,0.5\n3,true,false,missing.fits,0.1\n")
        let scan = try ImageCollection.scan(from: [list])
        XCTAssertEqual(scan.images, [first, second])
        XCTAssertEqual(scan.issues.count, 1)
        XCTAssertEqual(scan.issues.first?.line, 9)
    }

    func testCSVSkipsBlankLinesButCountsEmptyAndMissingPathCells() throws {
        let image = try write("frame.fits")
        let list = try write("images.csv", "rating,path\n\n \t \n1,frame.fits\n2,\n3\n4,missing.fits\n5,missing.fits\n")
        let scan = try ImageCollection.scan(from: [list])
        XCTAssertEqual(scan.images, [image])
        XCTAssertEqual(scan.issues.count, 4)
        XCTAssertEqual(Set(scan.issues.compactMap(\.line)), [5, 6, 7, 8])
        XCTAssertEqual(Set(scan.issues.map(\.id)).count, 4)
    }

    func testMalformedCSVThrowsLineErrorWithoutPartialResult() throws {
        try write("first.fits")
        for malformed in ["\"unterminated\n", "\"first.fits\"trailing\n", "fir\"st.fits\n", "\"first\" \".fits\"\n"] {
            let list = try write("images.csv", "path\nfirst.fits\n" + malformed)
            XCTAssertThrowsError(try ImageCollection.scan(from: [list])) { error in
                XCTAssertEqual((error as? ImagePathList.InvalidCSV)?.line, 3)
            }
        }
    }

    func testEmptyAndMissingListsAreDistinct() throws {
        let list = try write("empty.txt", "\n  \n")
        let empty = try ImageCollection.scan(from: [list])
        XCTAssertTrue(empty.images.isEmpty)
        XCTAssertTrue(empty.includesList)
        XCTAssertTrue(empty.issues.isEmpty)
        XCTAssertThrowsError(try ImagePathList.read(root.appendingPathComponent("missing.txt")))
    }

    func testBOMAndUTF16Lists() throws {
        let image = try write("étoile.fits")
        let list = root.appendingPathComponent("images.csv")
        for encoding in [String.Encoding.utf8, .utf16] {
            try XCTUnwrap("\u{FEFF}path\nétoile.fits\n".data(using: encoding)).write(to: list)
            XCTAssertEqual(try ImageCollection.scan(from: [list]).images, [image])
        }
    }

    func testInvalidEncodingFailsInsteadOfSilentlyChangingPaths() throws {
        let list = root.appendingPathComponent("images.txt")
        try Data([0xFF, 0xFF]).write(to: list)
        XCTAssertThrowsError(try ImagePathList.read(list))
    }

    func testSymlinksAliasesAndOverlappingRootsAreDeduplicated() throws {
        let image = try write("original.fits")
        let link = root.appendingPathComponent("linked.fits")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: image)
        let alias = root.appendingPathComponent("Image alias")
        try URL.writeBookmarkData(image.bookmarkData(options: [.suitableForBookmarkFile], includingResourceValuesForKeys: nil, relativeTo: nil), to: alias)
        let list = try write("images.txt", "original.fits\nlinked.fits\nImage alias\n")
        let scan = try ImageCollection.scan(from: [list, image])
        XCTAssertEqual(scan.images, [image])
        XCTAssertTrue(scan.issues.isEmpty)
    }

    func testListDoesNotExpandFoldersOrImportOtherLists() throws {
        try write("nested.fits/frame.fits")
        try write("other.txt", "nested.fits/frame.fits\n")
        let list = try write("images.txt", "nested.fits\nother.txt\n")
        let scan = try ImageCollection.scan(from: [list])
        XCTAssertTrue(scan.images.isEmpty)
        XCTAssertEqual(scan.issues.count, 2)
        XCTAssertTrue(scan.directories.isEmpty)
    }

    func testFolderScanDoesNotImportListsAndHandlesFolderNamedCSV() throws {
        let image = try write("folder.csv/frame.fits")
        let external = try write("elsewhere/extra.fits")
        try write("folder.csv/paths.txt", "\(external.path)\n")
        let scan = try ImageCollection.scan(from: [root.appendingPathComponent("folder.csv")])
        XCTAssertEqual(scan.images, [image])
        XCTAssertFalse(scan.includesList)
    }

    func testInvalidNullPathIsReported() throws {
        let list = try write("images.txt", "bad\0path.fits\n")
        let scan = try ImageCollection.scan(from: [list])
        XCTAssertTrue(scan.images.isEmpty)
        XCTAssertEqual(scan.issues.count, 1)
        XCTAssertEqual(scan.issues.first?.line, 1)
    }

    func testIssuesFromDifferentListsKeepDistinctSourceLocations() throws {
        let first = try write("first.csv", "path\nmissing.fits\n")
        let second = try write("second.csv", "path\nmissing.fits\n")
        let scan = try ImageCollection.scan(from: [first, second])
        XCTAssertEqual(scan.issues.count, 2)
        XCTAssertEqual(Set(scan.issues.compactMap(\.list)), [first, second])
        XCTAssertEqual(Set(scan.issues.map(\.id)).count, 2)
    }

    func testCSVGroupsByEachImageDirectoryIncludingRepeatedFolderNames() throws {
        let first = try write("night2/lights/frame.fits")
        let second = try write("night1/lights/frame10.fits")
        let third = try write("night1/lights/frame2.fits")
        let list = try write("lists/images.csv", "path\n../night2/lights/frame.fits\n../night1/lights/frame10.fits\n../night1/lights/frame2.fits\n")
        let scan = try ImageCollection.scan(from: [list])
        let collection = ImageBrowserCollection(urls: scan.images, directories: scan.directories)
        let groups = collection.groups(for: .path)

        XCTAssertEqual(scan.images, [first, second, third])
        XCTAssertEqual(groups.map(\.title), ["night1/lights", "night2/lights"])
        XCTAssertEqual(groups.map(\.imageIndices), [[2, 1], [0]])
        XCTAssertEqual(Set(groups.map(\.id)).count, 2)
        XCTAssertFalse(groups.contains { $0.title == "lists" || $0.title == "images.csv" })
    }

    func testPermissionErrorsRequestAccessOnlyForExplicitListEntries() throws {
        let image = try write("restricted.fits")
        let list = try write("images.txt", "restricted.fits\n")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: image.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: image.path) }
        let scan = try ImageCollection.scan(from: [list])
        XCTAssertTrue(scan.images.isEmpty)
        XCTAssertEqual(scan.issues.first?.needsAccess, true)
    }

    func testCancellationPrecedesFileReading() async throws {
        let missing = root.appendingPathComponent("missing.csv")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ImagePathList.read(missing)
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
    }
}

@MainActor
final class ImagePathListWindowTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, _ text: String = "") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func waitForViewer(_ window: NSWindow) async throws -> ViewerView {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while window.title.hasPrefix("Loading "), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try XCTUnwrap((window.contentViewController as? NSHostingController<ViewerView>)?.rootView)
    }

    func testListOpensAsOneBrowserCollectionIncludingSingleImage() async throws {
        let image = try write("frame.png")
        let list = try write("images.csv", "path\nframe.png\nmissing.fits\n")
        let delegate = AppDelegate()
        delegate.open(list)
        let window = try XCTUnwrap(delegate.documentWindow(for: list))
        defer { window.close() }
        let view = try await waitForViewer(window)
        XCTAssertEqual(view.urls, [image])
        XCTAssertTrue(view.showsImageBrowser)
        XCTAssertEqual(view.collectionName, "images.csv")
        XCTAssertEqual(view.scanIssues.count, 1)
        XCTAssertNil(delegate.documentWindow(for: image))
    }

    func testCSVStartsWithDirectoryGroupsRegardlessOfRememberedGrouping() async throws {
        let defaults = UserDefaults.standard
        let savedGrouping = defaults.object(forKey: "imageBrowserGrouping")
        defer {
            if let savedGrouping { defaults.set(savedGrouping, forKey: "imageBrowserGrouping") }
            else { defaults.removeObject(forKey: "imageBrowserGrouping") }
        }
        let firstFolder = root.appendingPathComponent("night1", isDirectory: true)
        let secondFolder = root.appendingPathComponent("night2", isDirectory: true)
        for folder in [firstFolder, secondFolder] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let first = firstFolder.appendingPathComponent("z.fits")
        let second = secondFolder.appendingPathComponent("a.fits")
        try Data().write(to: first)
        try Data().write(to: second)
        let list = try write("images.csv", "path\nnight2/a.fits\nnight1/z.fits\n")

        for preference in [ImageBrowserGrouping.none, .filter, .fileType] {
            defaults.set(preference.rawValue, forKey: "imageBrowserGrouping")
            let delegate = AppDelegate()
            delegate.open(list)
            let window = try XCTUnwrap(delegate.documentWindow(for: list))
            let view = try await waitForViewer(window)
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while window.title != "z.fits", ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            // Path grouping starts in night1; every remembered mode would start
            // at the first CSV row or its naturally earlier filename instead.
            XCTAssertEqual(window.title, "z.fits", preference.rawValue)
            XCTAssertEqual(view.browserCollection.groups(for: .path).map(\.title), ["night1", "night2"])
            XCTAssertEqual(view.browserCollection.groups(for: .path).map { $0.imageIndices.count }, [1, 1])
            XCTAssertEqual(defaults.string(forKey: "imageBrowserGrouping"), preference.rawValue)
            window.close()
        }
    }

    func testDroppedListReplacesExistingWindowAndRekeysSession() async throws {
        let old = try write("old.png")
        let first = try write("z.fits")
        let second = try write("a.fits")
        let list = try write("images.txt", "z.fits\na.fits\n")
        let delegate = AppDelegate()
        delegate.open(old)
        let window = try XCTUnwrap(delegate.documentWindow(for: old))
        defer { window.close() }
        delegate.replaceContents(of: window, with: [list])
        let view = try await waitForViewer(window)
        XCTAssertEqual(view.urls, [first, second])
        XCTAssertTrue(view.showsImageBrowser)
        XCTAssertTrue(delegate.documentWindow(for: list) === window)
        XCTAssertNil(delegate.documentWindow(for: old))
    }

    func testMalformedReplacementRestoresPreviousViewer() async throws {
        let old = try write("old.png")
        let list = try write("broken.csv", "path\n\"unterminated\n")
        let failed = expectation(description: "Malformed list reported")
        let delegate = AppDelegate(
            collectionScanner: { try await ImageCollection.scanInBackground(from: $0) },
            collectionErrorPresenter: { error in
                XCTAssertTrue(error is ImagePathList.InvalidCSV)
                failed.fulfill()
            }
        )
        delegate.open(old)
        let window = try XCTUnwrap(delegate.documentWindow(for: old))
        defer { window.close() }
        let previous = window.contentViewController
        delegate.replaceContents(of: window, with: [list])
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertTrue(window.contentViewController === previous)
        XCTAssertEqual(window.title, "old.png")
        XCTAssertTrue(delegate.documentWindow(for: old) === window)
        XCTAssertNil(delegate.documentWindow(for: list))
    }

    func testMalformedNewListClosesLoadingWindowAndReportsError() async throws {
        let list = try write("broken.csv", "path\n\"unterminated\n")
        let failed = expectation(description: "Malformed list reported")
        let delegate = AppDelegate(
            collectionScanner: { try await ImageCollection.scanInBackground(from: $0) },
            collectionErrorPresenter: { _ in failed.fulfill() }
        )
        delegate.open(list)
        let window = try XCTUnwrap(delegate.documentWindow(for: list))
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertFalse(window.isVisible)
        XCTAssertNil(delegate.documentWindow(for: list))
    }

    private actor AccessScan {
        var calls = 0
        let image: URL
        let denied: URL
        init(image: URL, denied: URL) { self.image = image; self.denied = denied }
        func scan() -> ImageCollection.Scan {
            calls += 1
            return ImageCollection.Scan(
                images: calls == 1 ? [image] : [image, denied], directories: [],
                issues: calls == 1 ? [.init(url: denied, message: "Permission denied", line: 3, needsAccess: true)] : [],
                includesList: true
            )
        }
    }

    func testGrantingFolderAccessRetriesListAndKeepsOneCollection() async throws {
        let image = try write("first.png")
        let denied = try write("second.png")
        let list = try write("images.csv")
        let probe = AccessScan(image: image, denied: denied)
        let requested = expectation(description: "Folder access requested")
        let folder = root!
        let delegate = AppDelegate(
            collectionScanner: { _ in await probe.scan() },
            collectionAccessRequester: { urls, _ in
                XCTAssertEqual(urls, [denied])
                requested.fulfill()
                return [folder]
            }
        )
        delegate.open(list)
        let window = try XCTUnwrap(delegate.documentWindow(for: list))
        defer { window.close() }
        await fulfillment(of: [requested], timeout: 3)
        let view = try await waitForViewer(window)
        XCTAssertEqual(view.urls, [image, denied])
        XCTAssertTrue(view.scanIssues.isEmpty)
        let calls = await probe.calls
        XCTAssertEqual(calls, 2)
    }

    func testCancelingFolderAccessKeepsReadableImagesAndReportsDeniedEntry() async throws {
        let image = try write("first.png")
        let denied = try write("second.png")
        let list = try write("images.csv")
        let probe = AccessScan(image: image, denied: denied)
        let delegate = AppDelegate(
            collectionScanner: { _ in await probe.scan() },
            collectionAccessRequester: { _, _ in [] }
        )
        delegate.open(list)
        let window = try XCTUnwrap(delegate.documentWindow(for: list))
        defer { window.close() }
        let view = try await waitForViewer(window)
        XCTAssertEqual(view.urls, [image])
        XCTAssertEqual(view.scanIssues.first?.url, denied)
        let calls = await probe.calls
        XCTAssertEqual(calls, 1)
    }

    func testClosingWindowDuringAccessRequestDiscardsResultWithoutRetry() async throws {
        let image = try write("first.png")
        let denied = try write("second.png")
        let list = try write("images.csv")
        let probe = AccessScan(image: image, denied: denied)
        let requested = expectation(description: "Access request awaiting response")
        var response: CheckedContinuation<[URL], Never>?
        let delegate = AppDelegate(
            collectionScanner: { _ in await probe.scan() },
            collectionAccessRequester: { _, _ in
                await withCheckedContinuation {
                    response = $0
                    requested.fulfill()
                }
            }
        )
        delegate.open(list)
        let window = try XCTUnwrap(delegate.documentWindow(for: list))
        await fulfillment(of: [requested], timeout: 3)
        window.close()
        try XCTUnwrap(response).resume(returning: [root])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(delegate.documentWindow(for: list))
        let calls = await probe.calls
        XCTAssertEqual(calls, 1)
    }
}
