import AppKit
import Foundation

enum AirDropEntrySource: String, Equatable {
    case panel
    case drag
    case preview
}

struct AirDropPasteboardPayload: Equatable {
    var fileURLs: [URL] = []
    var remoteURLs: [URL] = []
    var textSnippets: [String] = []

    init(fileURLs: [URL] = [], remoteURLs: [URL] = [], text: String? = nil) {
        self.init(
            fileURLs: fileURLs,
            remoteURLs: remoteURLs,
            textSnippets: text.map { [$0] } ?? []
        )
    }

    init(fileURLs: [URL] = [], remoteURLs: [URL] = [], textSnippets: [String]) {
        self.fileURLs = fileURLs
        self.remoteURLs = remoteURLs
        self.textSnippets = textSnippets
    }

    func merged(with other: AirDropPasteboardPayload) -> AirDropPasteboardPayload {
        AirDropPasteboardPayload(
            fileURLs: fileURLs + other.fileURLs,
            remoteURLs: remoteURLs + other.remoteURLs,
            textSnippets: textSnippets + other.textSnippets
        )
    }
}

struct AirDropPasteboardSnapshot: Equatable {
    let changeCount: Int
    let payload: AirDropPasteboardPayload
}

struct AirDropTextPreview: Equatable {
    let text: String
    let isTruncated: Bool
}

struct AirDropSummary: Equatable {
    let title: String
    let detail: String?
    let itemCount: Int
}

enum AirDropDraftMode: Equatable {
    case ready
    case needsTextConfirmation
    case readyWithOptionalText
}

struct AirDropDraft: Equatable {
    let source: AirDropEntrySource
    let fileURLs: [URL]
    let remoteURLs: [URL]
    let textSnippets: [String]
    let textPreviews: [AirDropTextPreview]
    let mode: AirDropDraftMode
    let summary: AirDropSummary

    var primaryItemCount: Int { fileURLs.count + remoteURLs.count }
    var hasPrimaryItems: Bool { primaryItemCount > 0 }
    var textItemCount: Int { textSnippets.count }
    var hasTextItems: Bool { !textSnippets.isEmpty }

    var payload: AirDropPasteboardPayload {
        AirDropPasteboardPayload(fileURLs: fileURLs, remoteURLs: remoteURLs, textSnippets: textSnippets)
    }

    func displaySummary(includeText: Bool) -> AirDropSummary {
        let includedTextCount = includeText ? textItemCount : 0
        let itemCount = primaryItemCount + includedTextCount
        let detail = itemCountDetail(includeText: includeText)
        return AirDropSummary(
            title: "\(itemCount) 个项目已准备",
            detail: detail,
            itemCount: itemCount
        )
    }

    func itemCountDetail(includeText: Bool) -> String? {
        let fileCount = fileURLs.filter { !$0.hasDirectoryPath }.count
        let folderCount = fileURLs.filter(\.hasDirectoryPath).count
        let linkCount = remoteURLs.count
        var parts: [String] = [
            Self.countText(fileCount, label: "文件"),
            Self.countText(folderCount, label: "文件夹"),
            Self.countText(linkCount, label: "链接")
        ].compactMap { $0 }

        if includeText, textItemCount > 0 {
            parts.append("\(textItemCount) 个 .txt")
        }

        let countDetail = parts.isEmpty ? nil : parts.joined(separator: "、")
        guard !includeText, textItemCount > 0 else {
            return countDetail
        }

        let optionalTextDetail = "可包含 \(textItemCount) 段文字为 \(textItemCount) 个 .txt"
        return [countDetail, optionalTextDetail]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private static func countText(_ count: Int, label: String) -> String? {
        guard count > 0 else { return nil }
        return "\(count) 个\(label)"
    }
}

enum AirDropClassification: Equatable {
    case supported(AirDropDraft)
    case unsupported
}

struct AirDropTemporaryTextFile: Equatable {
    let fileURL: URL
    let directoryURL: URL
}

struct AirDropTransfer: Equatable {
    let draft: AirDropDraft
    let includeText: Bool
    let temporaryTextFiles: [AirDropTemporaryTextFile]
    let sharingItems: [URL]
}

struct AirDropCompletion: Equatable {
    let cleanedTemporaryTextFile: Bool
}

enum AirDropFlowState: Equatable {
    case idle
    case ready(AirDropDraft)
    case confirmingText(AirDropDraft)
    case opening(AirDropTransfer)
    case complete(AirDropCompletion)
    case unavailable(String)
    case failed(String)
    case cancelled
    case cleanupError(String)
}

enum AirDropTextFileError: Error, Equatable {
    case emptyText
}

final class AirDropItemClassifier {
    private let maxPreviewCharacters: Int

    init(maxPreviewCharacters: Int = 120) {
        self.maxPreviewCharacters = maxPreviewCharacters
    }

    func classify(_ payload: AirDropPasteboardPayload, source: AirDropEntrySource) -> AirDropClassification {
        let fileURLs = unique(payload.fileURLs.filter(\.isFileURL))
        let remoteURLs = unique(payload.remoteURLs.filter { !$0.isFileURL })
        let textSnippets = normalizedTextSnippets(payload.textSnippets, fileURLs: fileURLs, remoteURLs: remoteURLs)

        if fileURLs.isEmpty, remoteURLs.isEmpty {
            if textSnippets.count == 1, let text = textSnippets.first, let url = remoteURL(fromPlainText: text) {
                return .supported(makeDraft(
                    source: source,
                    fileURLs: [],
                    remoteURLs: [url],
                    textSnippets: [],
                    mode: .ready
                ))
            }
            guard !textSnippets.isEmpty else { return .unsupported }
            return .supported(makeDraft(
                source: source,
                fileURLs: [],
                remoteURLs: [],
                textSnippets: textSnippets,
                mode: .needsTextConfirmation
            ))
        }

        return .supported(makeDraft(
            source: source,
            fileURLs: fileURLs,
            remoteURLs: remoteURLs,
            textSnippets: textSnippets,
            mode: textSnippets.isEmpty ? .ready : .readyWithOptionalText
        ))
    }

    private func makeDraft(
        source: AirDropEntrySource,
        fileURLs: [URL],
        remoteURLs: [URL],
        textSnippets: [String],
        mode: AirDropDraftMode
    ) -> AirDropDraft {
        AirDropDraft(
            source: source,
            fileURLs: fileURLs,
            remoteURLs: remoteURLs,
            textSnippets: textSnippets,
            textPreviews: textSnippets.map(makePreview),
            mode: mode,
            summary: makeSummary(fileURLs: fileURLs, remoteURLs: remoteURLs, textCount: textSnippets.count, mode: mode)
        )
    }

    private func normalizedTextSnippets(
        _ rawSnippets: [String],
        fileURLs: [URL],
        remoteURLs: [URL]
    ) -> [String] {
        rawSnippets.compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            let duplicateFile = fileURLs.contains { url in
                trimmed == url.absoluteString || trimmed == url.path
            }
            let duplicateRemote = remoteURLs.contains { url in
                trimmed == url.absoluteString
            }
            return duplicateFile || duplicateRemote ? nil : raw
        }
    }

    private func remoteURL(fromPlainText text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              !url.isFileURL else {
            return nil
        }
        return url
    }

    private func makePreview(for text: String) -> AirDropTextPreview {
        let twoLines = text.components(separatedBy: .newlines).prefix(2).joined(separator: "\n")
        guard twoLines.count > maxPreviewCharacters else {
            return AirDropTextPreview(text: twoLines, isTruncated: twoLines != text)
        }
        let end = twoLines.index(twoLines.startIndex, offsetBy: maxPreviewCharacters)
        return AirDropTextPreview(text: String(twoLines[..<end]) + "...", isTruncated: true)
    }

    private func makeSummary(
        fileURLs: [URL],
        remoteURLs: [URL],
        textCount: Int,
        mode: AirDropDraftMode
    ) -> AirDropSummary {
        let itemCount = fileURLs.count + remoteURLs.count
        if itemCount == 0, textCount > 0 {
            return AirDropSummary(
                title: "\(textCount) 个项目已准备",
                detail: "\(textCount) 个 .txt",
                itemCount: textCount
            )
        }
        let countDetail = itemCountDetail(fileURLs: fileURLs, remoteURLs: remoteURLs)
        if itemCount == 1 {
            return AirDropSummary(
                title: "\(countDetail ?? "1 个项目")已准备",
                detail: mode == .readyWithOptionalText ? "可包含 \(textCount) 段文字为 \(textCount) 个 .txt" : nil,
                itemCount: 1
            )
        }
        let detail: String?
        switch mode {
        case .readyWithOptionalText:
            detail = [countDetail, "可包含 \(textCount) 段文字为 \(textCount) 个 .txt"]
                .compactMap { $0 }
                .joined(separator: " · ")
        case .needsTextConfirmation, .ready:
            detail = countDetail
        }
        return AirDropSummary(title: "\(itemCount) 个项目已准备", detail: detail, itemCount: itemCount)
    }

    private func itemCountDetail(fileURLs: [URL], remoteURLs: [URL]) -> String? {
        let fileCount = fileURLs.filter { !$0.hasDirectoryPath }.count
        let folderCount = fileURLs.filter(\.hasDirectoryPath).count
        let linkCount = remoteURLs.count
        let parts: [String] = [
            countText(fileCount, label: "文件"),
            countText(folderCount, label: "文件夹"),
            countText(linkCount, label: "链接")
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "、")
    }

    private func countText(_ count: Int, label: String) -> String? {
        guard count > 0 else { return nil }
        return "\(count) 个\(label)"
    }

    private func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let key = url.isFileURL ? url.standardizedFileURL.absoluteString : url.absoluteString
            guard seen.insert(key).inserted else { continue }
            result.append(url)
        }
        return result
    }
}

struct AirDropPasteboardReader {
    func snapshot(from pasteboard: NSPasteboard) -> AirDropPasteboardSnapshot {
        AirDropPasteboardSnapshot(
            changeCount: pasteboard.changeCount,
            payload: payload(from: pasteboard)
        )
    }

    func payload(from pasteboard: NSPasteboard) -> AirDropPasteboardPayload {
        let fileURLs = readURLs(from: pasteboard, fileOnly: true)
        let allURLs = readURLs(from: pasteboard, fileOnly: false)
        let remoteURLs = allURLs.filter { !$0.isFileURL }
        return AirDropPasteboardPayload(
            fileURLs: fileURLs,
            remoteURLs: remoteURLs,
            text: pasteboard.string(forType: .string)
        )
    }

    private func readURLs(from pasteboard: NSPasteboard, fileOnly: Bool) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: fileOnly
        ]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL] ?? []
        return urls.map { $0 as URL }
    }
}

final class AirDropTemporaryTextFileStore {
    private let fileManager: FileManager
    private let baseDirectoryProvider: () -> URL
    private let dateProvider: () -> Date
    private let uuidProvider: () -> UUID

    init(
        fileManager: FileManager = .default,
        baseDirectoryProvider: @escaping () -> URL = { FileManager.default.temporaryDirectory },
        dateProvider: @escaping () -> Date = Date.init,
        uuidProvider: @escaping () -> UUID = UUID.init
    ) {
        self.fileManager = fileManager
        self.baseDirectoryProvider = baseDirectoryProvider
        self.dateProvider = dateProvider
        self.uuidProvider = uuidProvider
    }

    func createTextFiles(texts: [String]) throws -> [AirDropTemporaryTextFile] {
        var temporaryFiles: [AirDropTemporaryTextFile] = []
        do {
            for text in texts {
                temporaryFiles.append(try createTextFile(text: text))
            }
            return temporaryFiles
        } catch {
            try? cleanup(temporaryFiles)
            throw error
        }
    }

    func createTextFile(text: String) throws -> AirDropTemporaryTextFile {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AirDropTextFileError.emptyText
        }

        let directory = baseDirectoryProvider()
            .appendingPathComponent("BoughAirDropText", isDirectory: true)
            .appendingPathComponent(uuidProvider().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = directory.appendingPathComponent(fileName(for: dateProvider()), isDirectory: false)
        try text.data(using: .utf8)?.write(to: fileURL, options: .atomic)
        return AirDropTemporaryTextFile(fileURL: fileURL, directoryURL: directory)
    }

    func cleanup(_ temporaryFile: AirDropTemporaryTextFile?) throws {
        guard let temporaryFile else { return }
        try cleanup([temporaryFile])
    }

    func cleanup(_ temporaryFiles: [AirDropTemporaryTextFile]) throws {
        guard !temporaryFiles.isEmpty else { return }
        for temporaryFile in temporaryFiles {
            if fileManager.fileExists(atPath: temporaryFile.directoryURL.path) {
                try fileManager.removeItem(at: temporaryFile.directoryURL)
            }
        }
        if let rootURL = temporaryFiles.first?.directoryURL.deletingLastPathComponent(),
           let remaining = try? fileManager.contentsOfDirectory(atPath: rootURL.path),
           remaining.isEmpty {
            try? fileManager.removeItem(at: rootURL)
        }
    }

    func isCleanedUp(_ temporaryFile: AirDropTemporaryTextFile?) -> Bool {
        guard let temporaryFile else { return true }
        return !fileManager.fileExists(atPath: temporaryFile.directoryURL.path)
    }

    func isCleanedUp(_ temporaryFiles: [AirDropTemporaryTextFile]) -> Bool {
        temporaryFiles.allSatisfy { isCleanedUp($0) }
    }

    private func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Bough AirDrop Text \(formatter.string(from: date)).txt"
    }
}

@MainActor
protocol AirDropSharePerforming: AnyObject {
    func perform(items: [Any], completion: @escaping (Result<Void, Error>) -> Void) -> Bool
}

@MainActor
final class NativeAirDropSharePerformer: NSObject, AirDropSharePerforming, NSSharingServiceDelegate {
    private var activeService: NSSharingService?
    private var completion: ((Result<Void, Error>) -> Void)?
    private var pendingSuccessTask: Task<Void, Never>?
    private let successSettleDelay: TimeInterval

    init(successSettleDelay: TimeInterval = 1.5) {
        self.successSettleDelay = successSettleDelay
        super.init()
    }

    deinit {
        pendingSuccessTask?.cancel()
        activeService?.delegate = nil
    }

    func perform(items: [Any], completion: @escaping (Result<Void, Error>) -> Void) -> Bool {
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            return false
        }
        pendingSuccessTask?.cancel()
        self.completion = completion
        activeService = service
        service.delegate = self
        service.perform(withItems: items)
        return true
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        finishAfterSuccessfulShareSettles()
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        finish(.failure(error))
    }

    private func finishAfterSuccessfulShareSettles() {
        pendingSuccessTask?.cancel()
        let delay = successSettleDelay
        pendingSuccessTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            self?.finish(.success(()))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        pendingSuccessTask?.cancel()
        pendingSuccessTask = nil
        let completion = completion
        self.completion = nil
        activeService?.delegate = nil
        activeService = nil
        completion?(result)
    }
}

@MainActor
final class AirDropFlowController {
    private let classifier: AirDropItemClassifier
    private let textFileStore: AirDropTemporaryTextFileStore
    private let sharePerformer: AirDropSharePerforming

    private(set) var state: AirDropFlowState = .idle {
        didSet { onStateChange?(state) }
    }

    var onStateChange: ((AirDropFlowState) -> Void)?

    init(
        classifier: AirDropItemClassifier = AirDropItemClassifier(),
        textFileStore: AirDropTemporaryTextFileStore = AirDropTemporaryTextFileStore(),
        sharePerformer: AirDropSharePerforming? = nil
    ) {
        self.classifier = classifier
        self.textFileStore = textFileStore
        self.sharePerformer = sharePerformer ?? NativeAirDropSharePerformer()
    }

    @discardableResult
    func prepare(payload: AirDropPasteboardPayload, source: AirDropEntrySource) -> AirDropFlowState {
        switch classifier.classify(payload, source: source) {
        case .unsupported:
            state = .unavailable("此项目无法使用 AirDrop")
        case .supported(let draft):
            state = draft.mode == .needsTextConfirmation ? .confirmingText(draft) : .ready(draft)
        }
        return state
    }

    @discardableResult
    func append(payload: AirDropPasteboardPayload, source: AirDropEntrySource) -> AirDropFlowState {
        guard let draft = currentDraft else {
            return prepare(payload: payload, source: source)
        }
        return prepare(payload: draft.payload.merged(with: payload), source: source)
    }

    func reset() {
        state = .idle
    }

    func submit(includeText: Bool = false) {
        guard let draft = currentDraft else { return }
        guard includeText || draft.hasPrimaryItems else {
            cancel()
            return
        }

        do {
            let temporaryFiles = try makeTemporaryFilesIfNeeded(for: draft, includeText: includeText)
            let sharingItems = draft.fileURLs + draft.remoteURLs + temporaryFiles.map(\.fileURL)
            let transfer = AirDropTransfer(
                draft: draft,
                includeText: includeText,
                temporaryTextFiles: temporaryFiles,
                sharingItems: sharingItems
            )
            guard !sharingItems.isEmpty else {
                state = .unavailable("此项目无法使用 AirDrop")
                return
            }
            state = .opening(transfer)
            let started = sharePerformer.perform(items: sharingItems.map { $0 as NSURL }) { [weak self] result in
                self?.finishTransfer(transfer, result: result)
            }
            if !started {
                try textFileStore.cleanup(temporaryFiles)
                state = .unavailable("此项目无法使用 AirDrop")
            }
        } catch {
            state = .cleanupError("无法准备临时文件")
        }
    }

    func cancel() {
        if case .opening(let transfer) = state {
            do {
                try textFileStore.cleanup(transfer.temporaryTextFiles)
                state = .cancelled
            } catch {
                state = .cleanupError("无法清理临时文件")
            }
        } else {
            state = .cancelled
        }
    }

    private var currentDraft: AirDropDraft? {
        switch state {
        case .ready(let draft), .confirmingText(let draft):
            return draft
        default:
            return nil
        }
    }

    private func makeTemporaryFilesIfNeeded(
        for draft: AirDropDraft,
        includeText: Bool
    ) throws -> [AirDropTemporaryTextFile] {
        guard includeText else { return [] }
        return try textFileStore.createTextFiles(texts: draft.textSnippets)
    }

    private func finishTransfer(_ transfer: AirDropTransfer, result: Result<Void, Error>) {
        guard case .opening(let activeTransfer) = state, activeTransfer == transfer else {
            try? textFileStore.cleanup(transfer.temporaryTextFiles)
            return
        }

        do {
            try textFileStore.cleanup(transfer.temporaryTextFiles)
            guard textFileStore.isCleanedUp(transfer.temporaryTextFiles) else {
                state = .cleanupError("无法清理临时文件")
                return
            }
        } catch {
            state = .cleanupError("无法清理临时文件")
            return
        }

        switch result {
        case .success:
            state = .complete(AirDropCompletion(cleanedTemporaryTextFile: !transfer.temporaryTextFiles.isEmpty))
        case .failure:
            state = .failed("AirDrop 未完成")
        }
    }
}
