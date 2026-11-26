import XCTest
@testable import nylai

final class BoardAndLauncherTests: XCTestCase {
    func testViewportKeepsWorldAnchorAndNegativeCoordinates() {
        let size = CGSize(width: 800, height: 600)
        let anchor = CGPoint(x: 120, y: 210)
        var viewport = BoardViewport(center: CGPoint(x: -200, y: -100), zoom: 1)
        let before = viewport.world(anchor, in: size)
        viewport.magnify(2, at: anchor, in: size)
        let after = viewport.world(anchor, in: size)
        XCTAssertEqual(before.x, after.x, accuracy: 0.0001)
        XCTAssertEqual(before.y, after.y, accuracy: 0.0001)
        XCTAssertEqual(viewport.screen(before, in: size).x, anchor.x, accuracy: 0.0001)
    }

    @MainActor
    func testBoardPersistsTodoAndUndo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BoardStore(directory: directory)
        let board = store.active.id
        let id = store.addText("- [ ] hello", boardID: board, at: CGPoint(x: -40, y: -30))
        store.toggleTodo(boardID: board, itemID: id, line: 0)
        XCTAssertEqual(store.active.items.first?.text, "- [x] hello")
        store.undo()
        XCTAssertEqual(store.active.items.first?.text, "- [ ] hello")
        store.redo()
        store.flush()
        let restored = BoardStore(directory: directory)
        XCTAssertEqual(restored.active.items.first?.text, "- [x] hello")
        XCTAssertEqual(restored.active.items.first?.frame.origin.x, -40)
    }

    @MainActor
    func testCollapsedNotePersistsAndRestoresHeight() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BoardStore(directory: directory)
        let board = store.active.id
        let id = store.addText("hello", boardID: board, at: CGPoint(x: -40, y: -30))
        let original = try XCTUnwrap(store.active.items.first)
        store.toggleNoteCollapse(boardID: board, itemID: id)
        XCTAssertEqual(store.active.items.first?.frame.height, 36)
        let restored = BoardStore(directory: directory)
        XCTAssertEqual(restored.active.items.first?.expandedHeight, original.frame.height)
        restored.toggleNoteCollapse(boardID: board, itemID: id)
        XCTAssertEqual(restored.active.items.first?.frame, original.frame)
        XCTAssertNil(restored.active.items.first?.expandedHeight)
        XCTAssertEqual(restored.active.items.first?.text, "hello")
        let session = BoardSession(store: restored)
        session.resetZoom()
        XCTAssertEqual(restored.active.viewport.zoom, 1)
        XCTAssertEqual(restored.active.viewport.center, CGPoint(x: original.frame.midX, y: original.frame.midY))
        restored.flush()
    }

    @MainActor
    func testInlineNoteEditingCommitsAndKeepsOneUndoStep() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BoardStore(directory: directory)
        let session = BoardSession(store: store)
        session.addNote(at: .zero)
        XCTAssertNotNil(session.editingID)
        session.noteDraft = "# Title"
        session.noteDraft += "\n- [ ] Task"
        session.finishEditing()
        XCTAssertNil(session.editingID)
        XCTAssertEqual(store.active.items.first?.text, "# Title\n- [ ] Task")
        XCTAssertEqual(BoardStore(directory: directory).active.items.first?.text, "# Title\n- [ ] Task")
        session.undo()
        XCTAssertEqual(store.active.items.first?.text, "")
    }

    @MainActor
    func testDrawingStyleAndLegacyMarkerPersist() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BoardStore(directory: directory)
        let styled = BoardItem(kind: .arrow, frame: CGRect(x: 0, y: 0, width: 100, height: 50),
                               points: [.zero, CGPoint(x: 1, y: 1)], strokeWidth: 8, dashed: true, translucent: true)
        let marker = BoardItem(kind: .marker, frame: CGRect(x: 0, y: 0, width: 100, height: 50), strokeWidth: 3)
        store.editBoard(store.active.id) { $0.items += [styled, marker] }
        let items = BoardStore(directory: directory).active.items
        XCTAssertEqual(items, [styled, marker])
        XCTAssertEqual(items[0].strokeOpacity, 0.35)
        XCTAssertEqual(items[1].strokeOpacity, 0.3)
        XCTAssertEqual(items[1].effectiveStrokeWidth, 12)
        XCTAssertFalse(BoardColor.noteColors.contains(.clear))
    }

    func testBoardGeometryConstraintsAndEndpointOrder() {
        let start = CGPoint(x: 10, y: 10)
        let square = BoardGeometry.constrained(CGPoint(x: 40, y: 25), from: start, shape: true, control: true, shift: false)
        XCTAssertEqual(square, CGPoint(x: 40, y: 40))
        let horizontal = BoardGeometry.constrained(CGPoint(x: 40, y: 12), from: start, shape: false, control: false, shift: true)
        XCTAssertEqual(horizontal.y, 10, accuracy: 0.001)
        var item = BoardItem(kind: .arrow, frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        BoardGeometry.setEndpoints(&item, CGPoint(x: 100, y: 50), CGPoint(x: -10, y: 20))
        XCTAssertEqual(BoardGeometry.endpoints(item), [CGPoint(x: 100, y: 50), CGPoint(x: -10, y: 20)])
        let fit = BoardGeometry.imageRect(CGRect(x: 0, y: 0, width: 200, height: 100), imageSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(fit, CGRect(x: 50, y: 0, width: 100, height: 100))
    }

    @MainActor
    func testClearBoardUndoAndShapeStyle() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BoardStore(directory: directory)
        let session = BoardSession(store: store)
        let shape = BoardItem(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 100, height: 50),
                              rotation: .pi / 4, cornerRadius: 10, filled: true)
        store.editBoard(store.active.id) { $0.items.append(shape) }
        XCTAssertEqual(BoardStore(directory: directory).active.items.first, shape)
        session.clearBoard()
        XCTAssertTrue(store.active.items.isEmpty)
        session.undo()
        XCTAssertEqual(store.active.items, [shape])
    }

    @MainActor
    func testCorruptBoardDataIsNotOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("index.json")
        let damaged = Data("invalid".utf8)
        try damaged.write(to: url)
        let store = BoardStore(directory: directory)
        XCTAssertNotNil(store.loadError)
        store.create("new")
        store.flush()
        XCTAssertEqual(try Data(contentsOf: url), damaged)
    }

    func testLauncherQueriesAndRanking() throws {
        XCTAssertEqual(LauncherQuery("file:  report", scope: .all), LauncherQuery("report", scope: .files))
        XCTAssertEqual(LauncherQuery("board 待办", scope: .all).scope, .boards)
        let exact = try XCTUnwrap(LauncherRank.score(query: "Safari", title: "Safari", keywords: "", subtitle: ""))
        let fuzzy = try XCTUnwrap(LauncherRank.score(query: "safri", title: "Safari", keywords: "", subtitle: ""))
        XCTAssertGreaterThan(exact, fuzzy)
        XCTAssertNotNil(LauncherRank.score(query: "wx", title: "微信", keywords: "", subtitle: ""))
        XCTAssertNil(LauncherRank.score(query: "zzzz", title: "Safari", keywords: "", subtitle: ""))
    }

    func testQuicklinksAndCalculations() throws {
        let link = LauncherQuicklink(title: "Search", alias: "s", target: "https://example.com/?q={query}")
        let url = try XCTUnwrap(link.resolve(argument: "a&b=中文"))
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "a&b=中文")
        XCTAssertNil(LauncherQuicklink(title: "Bad", alias: "b", target: "javascript:alert(1)").resolve(argument: ""))
        XCTAssertEqual(LauncherCalculation.evaluate("2 + 3 * (4 - 1)"), "11")
        XCTAssertNil(LauncherCalculation.evaluate("1/0"))
        XCTAssertNil(LauncherCalculation.evaluate("2+3;"))
        XCTAssertEqual(LauncherCalculation.convert("1 km to m"), "1000 m")
        XCTAssertEqual(LauncherCalculation.color("#FF0080"), "RGB(255, 0, 128)")
    }

    @MainActor
    func testLauncherPreferencesPersistWithoutRecordingPrivateHistory() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = LauncherPreferences(directory: directory)
        preferences.update { $0.browserTabs = true }
        preferences.record("app:example")
        preferences.record("clip:private")
        let restored = LauncherPreferences(directory: directory)
        XCTAssertTrue(restored.configuration.browserTabs)
        XCTAssertEqual(restored.configuration.usage["app:example"], 1)
        XCTAssertNil(restored.configuration.usage["clip:private"])
    }
}
