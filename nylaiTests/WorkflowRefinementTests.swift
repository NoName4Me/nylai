import AppKit
import XCTest
@testable import nylai

@MainActor
final class WorkflowRefinementTests: XCTestCase {
    func testSameContentLegacySnippetsKeepEveryNameAfterMigration() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.snippets.save(SavedSnippet(name: "生产地址", group: "工作", text: "https://example.com"))
        try fixture.snippets.save(SavedSnippet(name: "备用入口", group: "常用", text: "https://example.com"))
        try fixture.groups.migrateLegacyItems(history: fixture.history, snippets: fixture.snippets)
        let record = try XCTUnwrap(fixture.history.allRecords.first)
        XCTAssertEqual(fixture.history.allRecords.count, 1)
        let name = try XCTUnwrap(fixture.groups.name(for: record.id))
        XCTAssertTrue(name.contains("生产地址"))
        XCTAssertTrue(name.contains("备用入口"))
        XCTAssertTrue(fixture.groups.groups.allSatisfy { $0.recordIDs.contains(record.id) })
        let reopened = try ClipboardGroupsStore(fileURL: fixture.root.appendingPathComponent("groups.json"))
        XCTAssertEqual(reopened.name(for: record.id), name)
    }
    func testGroupsMigratePinsAndSnippetsWithoutEvictingExistingHistory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let saved = try fixture.add("旧置顶")
        try fixture.history.setPinned(true, id: saved.id)
        let ordinary = try fixture.add("原有历史")
        var settings = fixture.history.settings
        settings.maximumItems = 1
        try fixture.history.updateSettings(settings)
        try fixture.snippets.save(SavedSnippet(name: "命令", group: "工作", text: "git status"))
        try fixture.groups.migrateLegacyItems(history: fixture.history, snippets: fixture.snippets)
        XCTAssertNotNil(fixture.history.allRecords.first { $0.id == ordinary.id })
        XCTAssertTrue(fixture.groups.groups.contains { $0.recordIDs.contains(saved.id) })
        let work = try XCTUnwrap(fixture.groups.groups.first { $0.name == "工作" })
        let imported = try XCTUnwrap(fixture.history.allRecords.first { work.recordIDs.contains($0.id) })
        XCTAssertEqual(fixture.history.text(for: imported), "git status")
        XCTAssertTrue(imported.isPinned)
        try fixture.groups.migrateLegacyItems(history: fixture.history, snippets: fixture.snippets)
        XCTAssertEqual(fixture.history.allRecords.count, 3)
        XCTAssertEqual(fixture.groups.groups.count, 2)
        let reopened = try ClipboardGroupsStore(fileURL: fixture.root.appendingPathComponent("groups.json"))
        XCTAssertEqual(reopened.groups, fixture.groups.groups)
    }

    func testMovingBetweenGroupsKeepsContentProtectedAndRejectsDuplicateNames() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = try fixture.add("分组内容")
        let a = ClipboardGroup(name: "工作", color: .green)
        let b = ClipboardGroup(name: "个人", color: .blue)
        try fixture.groups.save(a)
        try fixture.groups.save(b)
        XCTAssertThrowsError(try fixture.groups.save(ClipboardGroup(name: " 工作 ")))
        try fixture.groups.setMembership([record.id], groupID: a.id, included: true, history: fixture.history)
        try fixture.groups.setMembership([record.id], groupID: b.id, included: true, history: fixture.history)
        try fixture.groups.delete(a.id, history: fixture.history)
        XCTAssertTrue(try XCTUnwrap(fixture.history.allRecords.first { $0.id == record.id }).isPinned)
        try fixture.history.clearOrdinary()
        XCTAssertEqual(fixture.history.text(for: record), "分组内容")
        try fixture.groups.delete(b.id, history: fixture.history)
        XCTAssertFalse(try XCTUnwrap(fixture.history.allRecords.first { $0.id == record.id }).isPinned)
    }

    func testVisibleCheckboxSelectionMergesInVisibleOrderAndPinnedCopyStaysOpen() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.add("第一条")
        let second = try fixture.add("第二条")
        let pasteboard = RefinementPasteboard()
        let model = ClipboardPanelModel(store: fixture.history, pasteboard: pasteboard, targetApplication: nil, groups: fixture.groups)
        model.isSelecting = true
        model.isPinned = true
        var closes = 0
        model.onClose = { closes += 1 }
        model.choose(first)
        model.choose(second)
        model.copyChecked()
        XCTAssertEqual(pasteboard.text, model.visibleRecords.compactMap { fixture.history.text(for: $0) }.joined(separator: "\n"))
        XCTAssertEqual(closes, 0)
        model.joinWithSpace = true
        model.copyChecked()
        XCTAssertFalse(try XCTUnwrap(pasteboard.text).contains("\n"))
        model.isPinned = false
        model.copyChecked()
        XCTAssertEqual(closes, 1)
    }

    func testOCRSelectionLinksUTF16TextRangesToImageLinesInBothLayouts() {
        let lines = [RecognizedTextLine(text: "中文😀", box: CGRect(x: 0.1, y: 0.7, width: 0.3, height: 0.1)),
                     RecognizedTextLine(text: "Error 42", box: CGRect(x: 0.1, y: 0.5, width: 0.4, height: 0.1))]
        for layout in RecognizedTextLayout.allCases {
            let document = RecognizedTextDocument(lines: lines, layout: layout)
            XCTAssertEqual(document.ranges[0], NSRange(location: 0, length: 4))
            XCTAssertEqual(document.indexes(intersecting: NSRange(location: 2, length: 2)), [0])
            XCTAssertEqual(document.indexes(intersecting: NSRange(location: 5, length: 5)), [1])
            let both = document.range(for: [0, 1])
            XCTAssertEqual(both, NSRange(location: 0, length: (document.text as NSString).length))
            XCTAssertEqual(document.indexes(intersecting: both!), [0, 1])
        }
    }

    func testScrollControlsAreHorizontalOutsideBottomRightAndDoNotActivateApp() throws {
        let selection = CGRect(x: 400, y: 260, width: 600, height: 400)
        let frame = ScrollCaptureCompletionWindow.placement(selection: selection, screen: CGRect(x: 0, y: 0, width: 1440, height: 900))
        XCTAssertGreaterThan(frame.width, frame.height)
        XCTAssertEqual(frame.maxX, selection.maxX)
        XCTAssertLessThan(frame.maxY, selection.minY)
        let window = ScrollCaptureCompletionWindow(selectionGlobalRect: selection, screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                                   onComplete: {}, onCopy: {}, onSave: {}, onCancel: {})
        defer { window.close() }
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
        let buttons = try XCTUnwrap(window.contentView).subviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 4)
        XCTAssertTrue(buttons.allSatisfy { $0.image != nil && $0.imagePosition == .imageOnly })
    }
}

@MainActor
private struct Fixture {
    let root: URL
    let history: ClipboardHistoryStore
    let groups: ClipboardGroupsStore
    let snippets: SnippetStore
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        history = try ClipboardHistoryStore(directoryURL: root,
                                            settingsStore: ClipboardSettingsStore(fileURL: root.appendingPathComponent("settings.json")))
        groups = try ClipboardGroupsStore(fileURL: root.appendingPathComponent("groups.json"))
        snippets = try SnippetStore(fileURL: root.appendingPathComponent("snippets.json"))
    }
    func add(_ text: String) throws -> ClipboardRecord {
        try XCTUnwrap(history.add(ClipboardCapture(content: .text(text), sourceBundleIdentifier: nil, sourceName: nil,
                                                   contentHash: try XCTUnwrap(ClipboardContentIdentifier.text(text)))))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
private final class RefinementPasteboard: ClipboardPasteboardAccessing {
    var changeCount = 0
    var accessState: ClipboardPasteboardAccessState { .allowed }
    var text: String?
    func inspect() throws -> ClipboardPasteboardInspection { ClipboardPasteboardInspection(changeCount: changeCount, types: [], items: [], sourceBundleIdentifier: nil) }
    func data(forItemAt index: Int, type: String) -> Data? { nil }
    func string(forItemAt index: Int, type: String) -> String? { nil }
    func write(_ content: ClipboardContent, sourceBundleIdentifier: String) throws {
        if case .text(let text) = content { self.text = text }
        changeCount += 1
    }
}
