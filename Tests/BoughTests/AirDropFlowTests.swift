import AppKit
import XCTest
@testable import Bough

@MainActor
final class AirDropFlowTests: XCTestCase {
    private var tempRoots: [URL] = []

    override func tearDownWithError() throws {
        for root in tempRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoots.removeAll()
        try super.tearDownWithError()
    }

    func testClassifierTreatsFilesURLsAndTextAsMixedDraft() throws {
        let file = URL(fileURLWithPath: "/tmp/report.pdf")
        let folder = URL(fileURLWithPath: "/tmp/Folder", isDirectory: true)
        let link = try XCTUnwrap(URL(string: "https://example.com/path"))

        let result = AirDropItemClassifier().classify(
            AirDropPasteboardPayload(
                fileURLs: [file, folder],
                remoteURLs: [link],
                text: "include this note"
            ),
            source: .drag
        )

        guard case .supported(let draft) = result else {
            return XCTFail("Expected supported AirDrop draft")
        }
        XCTAssertEqual(draft.mode, .readyWithOptionalText)
        XCTAssertEqual(draft.fileURLs, [file, folder])
        XCTAssertEqual(draft.remoteURLs, [link])
        XCTAssertEqual(draft.textPreviews.first?.text, "include this note")
        XCTAssertEqual(draft.summary.title, "3 个项目已准备")
        XCTAssertEqual(draft.summary.detail, "1 个文件、1 个文件夹、1 个链接 · 可包含 1 段文字为 1 个 .txt")
        XCTAssertEqual(draft.displaySummary(includeText: true).title, "4 个项目已准备")
        XCTAssertEqual(draft.displaySummary(includeText: true).detail, "1 个文件、1 个文件夹、1 个链接、1 个 .txt")
    }

    func testClassifierTreatsPlainURLStringAsURLNotTextFile() throws {
        let result = AirDropItemClassifier().classify(
            AirDropPasteboardPayload(text: "https://example.com/share"),
            source: .drag
        )

        guard case .supported(let draft) = result else {
            return XCTFail("Expected supported URL draft")
        }
        XCTAssertEqual(draft.mode, .ready)
        XCTAssertEqual(draft.remoteURLs.map(\.absoluteString), ["https://example.com/share"])
        XCTAssertTrue(draft.textSnippets.isEmpty)
        XCTAssertEqual(draft.summary.title, "1 个链接已准备")
        XCTAssertNil(draft.summary.detail)
    }

    func testClassifierRequiresConfirmationForPureTextAndTruncatesPreview() throws {
        let longText = String(repeating: "a", count: 140) + "\nsecond line\nthird line"
        let result = AirDropItemClassifier().classify(
            AirDropPasteboardPayload(text: longText),
            source: .drag
        )

        guard case .supported(let draft) = result else {
            return XCTFail("Expected supported text draft")
        }
        XCTAssertEqual(draft.mode, .needsTextConfirmation)
        XCTAssertEqual(draft.summary.title, "1 个项目已准备")
        XCTAssertEqual(draft.summary.detail, "1 个 .txt")
        XCTAssertEqual(draft.textPreviews.first?.isTruncated, true)
        XCTAssertEqual(draft.textPreviews.first?.text.count, 123)
    }

    func testTemporaryTextFileStoreCreatesUTF8FileAndCleansTransferDirectory() throws {
        let root = makeTempRoot()
        let store = AirDropTemporaryTextFileStore(
            baseDirectoryProvider: { root },
            dateProvider: { Date(timeIntervalSince1970: 1_800_000_000) },
            uuidProvider: { UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")! }
        )

        let temporaryFile = try store.createTextFile(text: "hello")

        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryFile.fileURL.path))
        XCTAssertEqual(try String(contentsOf: temporaryFile.fileURL, encoding: .utf8), "hello")
        XCTAssertEqual(temporaryFile.fileURL.lastPathComponent, "Bough AirDrop Text 2027-01-15 08.00.00.txt")

        try store.cleanup(temporaryFile)

        XCTAssertTrue(store.isCleanedUp(temporaryFile))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryFile.directoryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryFile.directoryURL.deletingLastPathComponent().path))
    }

    func testFlowCleansTemporaryTextDirectoryAfterSuccessfulShare() throws {
        let root = makeTempRoot()
        let performer = FakeAirDropSharePerformer()
        let controller = makeController(root: root, performer: performer)

        controller.prepare(payload: AirDropPasteboardPayload(text: "send me"), source: .drag)
        controller.submit(includeText: true)

        guard case .opening(let transfer) = controller.state else {
            return XCTFail("Expected opening state")
        }
        let temporaryFile = try XCTUnwrap(transfer.temporaryTextFiles.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryFile.directoryURL.path))
        XCTAssertEqual(performer.items.count, 1)

        performer.succeed()

        XCTAssertEqual(controller.state, .complete(AirDropCompletion(cleanedTemporaryTextFile: true)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryFile.directoryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryFile.directoryURL.deletingLastPathComponent().path))
    }

    func testFlowMarksMixedTransferTemporaryTextCleanupAfterSuccessfulShare() throws {
        let root = makeTempRoot()
        let performer = FakeAirDropSharePerformer()
        let controller = makeController(root: root, performer: performer)
        let file = URL(fileURLWithPath: "/tmp/report.pdf")

        controller.prepare(payload: AirDropPasteboardPayload(fileURLs: [file], text: "include this note"), source: .drag)
        controller.submit(includeText: true)

        guard case .opening(let transfer) = controller.state else {
            return XCTFail("Expected opening state")
        }
        let temporaryFile = try XCTUnwrap(transfer.temporaryTextFiles.first)
        XCTAssertEqual(performer.items.count, 2)

        performer.succeed()

        XCTAssertEqual(controller.state, .complete(AirDropCompletion(cleanedTemporaryTextFile: true)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryFile.directoryURL.path))
    }

    func testFlowDoesNotShowTemporaryTextCleanupForPlainFileShare() throws {
        let root = makeTempRoot()
        let performer = FakeAirDropSharePerformer()
        let controller = makeController(root: root, performer: performer)
        let file = URL(fileURLWithPath: "/tmp/report.pdf")

        controller.prepare(payload: AirDropPasteboardPayload(fileURLs: [file]), source: .drag)
        controller.submit()

        guard case .opening(let transfer) = controller.state else {
            return XCTFail("Expected opening state")
        }
        XCTAssertTrue(transfer.temporaryTextFiles.isEmpty)

        performer.succeed()

        XCTAssertEqual(controller.state, .complete(AirDropCompletion(cleanedTemporaryTextFile: false)))
    }

    func testFlowCleansTemporaryTextDirectoryWhenAirDropServiceUnavailable() throws {
        let root = makeTempRoot()
        let performer = FakeAirDropSharePerformer()
        performer.shouldStart = false
        let controller = makeController(root: root, performer: performer)

        controller.prepare(payload: AirDropPasteboardPayload(text: "send me"), source: .drag)
        controller.submit(includeText: true)

        XCTAssertEqual(controller.state, .unavailable("此项目无法使用 AirDrop"))
        let textRoot = root.appendingPathComponent("BoughAirDropText", isDirectory: true)
        let residualItems = try? FileManager.default.contentsOfDirectory(atPath: textRoot.path)
        XCTAssertTrue((residualItems ?? []).isEmpty)
    }

    func testPureTextCancelDoesNotCreateTemporaryFile() throws {
        let root = makeTempRoot()
        let performer = FakeAirDropSharePerformer()
        let controller = makeController(root: root, performer: performer)

        controller.prepare(payload: AirDropPasteboardPayload(text: "send me"), source: .drag)
        controller.submit(includeText: false)

        XCTAssertEqual(controller.state, .cancelled)
        XCTAssertTrue(performer.items.isEmpty)
        let textRoot = root.appendingPathComponent("BoughAirDropText", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: textRoot.path))
    }

    func testAppendAddsMoreItemsAndDedupesFilesURLs() throws {
        let root = makeTempRoot()
        let performer = FakeAirDropSharePerformer()
        let controller = makeController(root: root, performer: performer)
        let file = URL(fileURLWithPath: "/tmp/report.pdf")
        let link = try XCTUnwrap(URL(string: "https://example.com/share"))

        controller.prepare(payload: AirDropPasteboardPayload(fileURLs: [file]), source: .panel)
        controller.append(
            payload: AirDropPasteboardPayload(fileURLs: [file], remoteURLs: [link]),
            source: .drag
        )

        guard case .ready(let draft) = controller.state else {
            return XCTFail("Expected appended ready draft")
        }
        XCTAssertEqual(draft.fileURLs, [file])
        XCTAssertEqual(draft.remoteURLs, [link])
        XCTAssertTrue(draft.textSnippets.isEmpty)
        XCTAssertEqual(draft.summary.detail, "1 个文件、1 个链接")
    }

    func testAppendFilesAfterTextKeepsTextInMixedDraftAndCanIncludeTxt() throws {
        let root = makeTempRoot()
        let performer = FakeAirDropSharePerformer()
        let controller = makeController(root: root, performer: performer)
        let first = URL(fileURLWithPath: "/tmp/first.txt")
        let second = URL(fileURLWithPath: "/tmp/second.txt")

        controller.prepare(payload: AirDropPasteboardPayload(text: "include this note"), source: .drag)
        controller.append(payload: AirDropPasteboardPayload(fileURLs: [first, second]), source: .drag)

        guard case .ready(let draft) = controller.state else {
            return XCTFail("Expected mixed ready draft")
        }
        XCTAssertEqual(draft.mode, .readyWithOptionalText)
        XCTAssertEqual(draft.fileURLs, [first, second])
        XCTAssertEqual(draft.textSnippets, ["include this note"])
        XCTAssertEqual(draft.summary.title, "2 个项目已准备")
        XCTAssertEqual(draft.summary.detail, "2 个文件 · 可包含 1 段文字为 1 个 .txt")
        XCTAssertEqual(draft.displaySummary(includeText: true).title, "3 个项目已准备")

        controller.submit(includeText: true)

        guard case .opening(let transfer) = controller.state else {
            return XCTFail("Expected opening state")
        }
        let temporaryFile = try XCTUnwrap(transfer.temporaryTextFiles.first)
        XCTAssertEqual(performer.items.count, 3)
        XCTAssertEqual(try String(contentsOf: temporaryFile.fileURL, encoding: .utf8), "include this note")
    }

    func testAppendSecondTextKeepsSeparateTxtItemsAndDuplicates() throws {
        let root = makeTempRoot()
        let performer = FakeAirDropSharePerformer()
        let controller = makeController(root: root, performer: performer)

        controller.prepare(payload: AirDropPasteboardPayload(text: "same note"), source: .drag)
        controller.append(payload: AirDropPasteboardPayload(text: "same note"), source: .drag)

        guard case .confirmingText(let draft) = controller.state else {
            return XCTFail("Expected confirming text draft")
        }
        XCTAssertEqual(draft.textSnippets, ["same note", "same note"])
        XCTAssertEqual(draft.displaySummary(includeText: true).title, "2 个项目已准备")
        XCTAssertEqual(draft.displaySummary(includeText: true).detail, "2 个 .txt")

        controller.submit(includeText: true)

        guard case .opening(let transfer) = controller.state else {
            return XCTFail("Expected opening state")
        }
        XCTAssertEqual(transfer.temporaryTextFiles.count, 2)
        XCTAssertEqual(performer.items.count, 2)
        XCTAssertEqual(
            try transfer.temporaryTextFiles.map { try String(contentsOf: $0.fileURL, encoding: .utf8) },
            ["same note", "same note"]
        )
    }

    func testAppendTextToExistingFileCreatesOptionalTextDraft() {
        let root = makeTempRoot()
        let performer = FakeAirDropSharePerformer()
        let controller = makeController(root: root, performer: performer)
        let file = URL(fileURLWithPath: "/tmp/report.pdf")

        controller.prepare(payload: AirDropPasteboardPayload(fileURLs: [file]), source: .panel)
        controller.append(payload: AirDropPasteboardPayload(text: "include this note"), source: .drag)

        guard case .ready(let draft) = controller.state else {
            return XCTFail("Expected mixed ready draft")
        }
        XCTAssertEqual(draft.mode, .readyWithOptionalText)
        XCTAssertEqual(draft.fileURLs, [file])
        XCTAssertEqual(draft.textSnippets, ["include this note"])
        XCTAssertEqual(draft.summary.title, "1 个文件已准备")
        XCTAssertEqual(draft.summary.detail, "可包含 1 段文字为 1 个 .txt")
    }

    func testNativeAirDropDialogCloseCleansTextAndShowsIncomplete() throws {
        let root = makeTempRoot()
        let performer = FakeAirDropSharePerformer()
        let controller = makeController(root: root, performer: performer)

        controller.prepare(payload: AirDropPasteboardPayload(text: "send me"), source: .drag)
        controller.submit(includeText: true)

        guard case .opening(let transfer) = controller.state else {
            return XCTFail("Expected opening state")
        }
        let temporaryFile = try XCTUnwrap(transfer.temporaryTextFiles.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryFile.directoryURL.path))

        performer.closeNativeDialog()

        XCTAssertEqual(controller.state, .failed("AirDrop 未完成"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryFile.directoryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryFile.directoryURL.deletingLastPathComponent().path))
    }

    func testSynchronousShareCompletionDoesNotLeaveFlowOpening() throws {
        let root = makeTempRoot()
        let performer = FakeAirDropSharePerformer()
        performer.synchronousResult = .success(())
        let controller = makeController(root: root, performer: performer)
        let file = URL(fileURLWithPath: "/tmp/report.pdf")

        controller.prepare(payload: AirDropPasteboardPayload(fileURLs: [file]), source: .drag)
        controller.submit()

        XCTAssertEqual(controller.state, .complete(AirDropCompletion(cleanedTemporaryTextFile: false)))
    }

    func testNativeDelegateDefersDidShareItemsBeforeComplete() throws {
        let source = try Self.sourceFile("Sources/Bough/AirDropFlow.swift")

        XCTAssertTrue(source.contains("func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {"))
        XCTAssertTrue(source.contains("finishAfterSuccessfulShareSettles()"))
        XCTAssertTrue(source.contains("private func finishAfterSuccessfulShareSettles()"))
        XCTAssertTrue(source.contains("pendingSuccessTask?.cancel()"))
    }

    private func makeController(root: URL, performer: FakeAirDropSharePerformer) -> AirDropFlowController {
        AirDropFlowController(
            textFileStore: AirDropTemporaryTextFileStore(
                baseDirectoryProvider: { root },
                dateProvider: { Date(timeIntervalSince1970: 1_800_000_000) },
                uuidProvider: { UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")! }
            ),
            sharePerformer: performer
        )
    }

    private func makeTempRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoughAirDropFlowTests-\(UUID().uuidString)", isDirectory: true)
        tempRoots.append(root)
        return root
    }

    private static func sourceFile(_ relativePath: String) throws -> String {
        let url = TestHelpers.repoRoot(from: #filePath).appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

@MainActor
private final class FakeAirDropSharePerformer: AirDropSharePerforming {
    var shouldStart = true
    var synchronousResult: Result<Void, Error>?
    var items: [Any] = []
    private var completion: ((Result<Void, Error>) -> Void)?

    func perform(items: [Any], completion: @escaping (Result<Void, Error>) -> Void) -> Bool {
        guard shouldStart else { return false }
        self.items = items
        if let synchronousResult {
            completion(synchronousResult)
            return true
        }
        self.completion = completion
        return true
    }

    func succeed() {
        completion?(.success(()))
        completion = nil
    }

    func closeNativeDialog() {
        completion?(.failure(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)))
        completion = nil
    }
}
