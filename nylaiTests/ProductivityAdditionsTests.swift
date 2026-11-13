import AppKit
import XCTest
@testable import nylai

final class ProductivityAdditionsTests: XCTestCase {
    func testRecognizedLinesPreserveOrMergeWithoutEmptyLines() {
        let lines = ["  错误信息 ", "", "Error 42\n"]
        XCTAssertEqual(RecognizedTextLayout.lines.format(lines), "错误信息\nError 42")
        XCTAssertEqual(RecognizedTextLayout.paragraph.format(lines), "错误信息 Error 42")
    }

    @MainActor
    func testLocalVisionRecognizesChineseAndEnglish() async throws {
        let image = try textImage("截图文字 Error 42")
        let result = try await ScreenshotTextRecognition.recognize(image, layout: .lines)
        XCTAssertTrue(result.contains("截图文字"), result)
        XCTAssertTrue(result.contains("Error 42"), result)
    }

    @MainActor
    func testBlankImageDoesNotProduceSuccessfulEmptyRecognition() async throws {
        do {
            _ = try await ScreenshotTextRecognition.recognize(textImage(""), layout: .lines)
            XCTFail("Blank image must not succeed")
        } catch is TextRecognitionError { }
    }

    @MainActor
    func testSnippetsPersistSearchEditAndDeleteIndependently() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("snippets.json")
        let store = try SnippetStore(fileURL: file)
        var snippet = SavedSnippet(name: "  工作邮箱 ", group: "联系", text: "  name@example.com\n")
        try store.save(snippet)
        let reloaded = try SnippetStore(fileURL: file)
        XCTAssertEqual(reloaded.matches("工作").first?.name, "工作邮箱")
        XCTAssertEqual(reloaded.matches("联系").first?.text, snippet.text)
        XCTAssertEqual(reloaded.matches("EXAMPLE").count, 1)
        snippet.text = "updated"
        try reloaded.save(snippet)
        XCTAssertEqual(reloaded.snippets.count, 1)
        XCTAssertEqual(try SnippetStore(fileURL: file).snippets.first?.text, "updated")
        try reloaded.delete(snippet.id)
        XCTAssertTrue(try SnippetStore(fileURL: file).snippets.isEmpty)
    }

    @MainActor
    func testSnippetWriteFailureAndInvalidDraftDoNotChangeMemory() throws {
        struct FailingWriter: ShortcutBindingFileWriting {
            func write(_ data: Data, to url: URL) throws { throw CocoaError(.fileWriteNoPermission) }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SnippetStore(fileURL: directory.appendingPathComponent("snippets.json"), writer: FailingWriter())
        XCTAssertThrowsError(try store.save(SavedSnippet(name: "Name", group: "", text: "Text")))
        XCTAssertThrowsError(try store.save(SavedSnippet(name: " ", group: "", text: "Text")))
        XCTAssertTrue(store.snippets.isEmpty)
    }

    func testWheelZoomKeepsAspectAnchorAndBounds() {
        let frame = CGRect(x: 200, y: 200, width: 400, height: 200)
        let anchor = CGPoint(x: 400, y: 300)
        let visible = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let zoom = PinnedImageLayout.zoomedFrame(frame, factor: 1.5, anchor: anchor,
                                               imageSize: CGSize(width: 800, height: 400), visibleFrame: visible)
        XCTAssertEqual(zoom.width, 600)
        XCTAssertEqual(zoom.height, 300)
        XCTAssertEqual(zoom.midX, anchor.x)
        XCTAssertEqual(zoom.midY, anchor.y)
        let limit = PinnedImageLayout.zoomedFrame(zoom, factor: 100, anchor: anchor,
                                                imageSize: CGSize(width: 800, height: 400), visibleFrame: visible)
        XCTAssertTrue(visible.contains(limit))
        XCTAssertEqual(limit.width / limit.height, 2)
        for size in [CGSize(width: 300, height: 3000), CGSize(width: 5000, height: 200)] {
            let initial = PinnedImageLayout.initialSize(imageSize: size, visibleFrame: visible)
            XCTAssertEqual(initial.width / initial.height, size.width / size.height, accuracy: 0.0001)
            let frame = CGRect(x: 0, y: 0, width: initial.width, height: initial.height)
            let result = PinnedImageLayout.zoomedFrame(frame, factor: 2, anchor: .zero, imageSize: size, visibleFrame: visible)
            XCTAssertTrue(visible.contains(result), "\(size) -> \(result)")
            XCTAssertEqual(result.width / result.height, size.width / size.height, accuracy: 0.0001)
        }
    }

    @MainActor
    func testHistoryToSnippetSurvivesHistoryClearAndCopiesUsingKeyboardSelection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = try ClipboardHistoryStore(directoryURL: directory,
                                               settingsStore: ClipboardSettingsStore(fileURL: directory.appendingPathComponent("settings.json")))
        let snippets = try SnippetStore(fileURL: directory.appendingPathComponent("snippets.json"))
        let text = "第一行\nError 42"
        let record = try XCTUnwrap(history.add(ClipboardCapture(content: .text(text), sourceBundleIdentifier: nil,
                                                              sourceName: nil, contentHash: try XCTUnwrap(ClipboardContentIdentifier.text(text)))))
        let pasteboard = SnippetTestPasteboard()
        let model = ClipboardPanelModel(store: history, pasteboard: pasteboard, targetApplication: nil, snippets: snippets)
        model.saveAsSnippet(record)
        let draft = try XCTUnwrap(model.snippetDraft)
        XCTAssertEqual(draft.text, text)
        try snippets.save(draft)
        try history.clearAll()
        XCTAssertEqual(try SnippetStore(fileURL: directory.appendingPathComponent("snippets.json")).snippets.first?.text, text)
        model.section = .snippets
        model.searchText = "Error"
        model.selectNext(1)
        var closed = false
        model.onClose = { closed = true }
        model.copySelectedOrFirst()
        XCTAssertEqual(pasteboard.text, text)
        XCTAssertTrue(closed)
    }

    @MainActor
    private func textImage(_ text: String) throws -> CGImage {
        let image = NSImage(size: CGSize(width: 900, height: 160))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 900, height: 160).fill()
        (text as NSString).draw(at: CGPoint(x: 30, y: 50), withAttributes: [
            .font: NSFont.systemFont(ofSize: 46), .foregroundColor: NSColor.black,
        ])
        image.unlockFocus()
        return try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }
}

@MainActor
private final class SnippetTestPasteboard: ClipboardPasteboardAccessing {
    var changeCount = 0
    var accessState: ClipboardPasteboardAccessState { .allowed }
    var text: String?
    func inspect() throws -> ClipboardPasteboardInspection {
        ClipboardPasteboardInspection(changeCount: changeCount, types: [], items: [], sourceBundleIdentifier: nil)
    }
    func data(forItemAt index: Int, type: String) -> Data? { nil }
    func string(forItemAt index: Int, type: String) -> String? { nil }
    func write(_ content: ClipboardContent, sourceBundleIdentifier: String) throws {
        if case .text(let value) = content { text = value }
        changeCount += 1
    }
}
