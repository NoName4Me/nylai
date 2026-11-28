import AppKit
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
    func testNoteBodySelectsDisplayedTextAndOnlyHeaderStartsDragging() throws {
        let fixture = BoardCanvasFixture()
        defer { fixture.close() }
        let boardID = fixture.store.active.id
        let id = fixture.store.addText("# Alpha Beta", boardID: boardID, at: CGPoint(x: -120, y: -80))
        let item = try XCTUnwrap(fixture.store.active.items.first)
        let frame = fixture.canvas.viewport.rect(item.frame, in: fixture.canvas.bounds.size)
        let body = BoardRenderer.noteBodyRect(frame)
        let width = ("Alpha" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 21, weight: .semibold)]).width
        let start = CGPoint(x: body.minX + 0.5, y: body.minY + 12)
        let end = CGPoint(x: body.minX + width, y: start.y)
        try fixture.drag(from: start, to: end)
        XCTAssertEqual(fixture.store.active.items.first?.frame, item.frame)
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        fixture.session.copy(clipboard)
        XCTAssertEqual(clipboard.string(forType: .string), "Alpha")
        try fixture.key(.keyDown, code: 124)
        XCTAssertEqual(fixture.store.active.items.first?.frame, item.frame)

        let header = CGPoint(x: frame.midX, y: frame.minY + 14)
        try fixture.drag(from: header, to: CGPoint(x: header.x + 38, y: header.y + 21))
        XCTAssertEqual(fixture.store.active.items.first?.frame, item.frame.offsetBy(dx: 38, dy: 21))

        let movedBodyPoint = CGPoint(x: start.x + 38, y: start.y + 21)
        fixture.canvas.mouseDown(with: try fixture.mouse(.leftMouseDown, at: movedBodyPoint, clicks: 2))
        XCTAssertEqual(fixture.session.editingID, id)
        XCTAssertEqual(fixture.session.noteDraft, "# Alpha Beta")
    }

    @MainActor
    func testCanvasDrawsFilledShapesTogglesSelectionAndKeepsSpacePan() throws {
        let fixture = BoardCanvasFixture()
        defer { fixture.close() }
        fixture.session.chooseTool(.ellipse)
        fixture.session.filled = true
        try fixture.drag(from: CGPoint(x: 80, y: 80), to: CGPoint(x: 180, y: 170))
        let ellipse = try XCTUnwrap(fixture.store.active.items.first)
        XCTAssertEqual(ellipse.kind, .ellipse)
        XCTAssertEqual(ellipse.filled, true)
        try fixture.key(.keyDown, code: 53)
        XCTAssertEqual(fixture.session.tool, .select)

        let rectangle = BoardItem(kind: .rectangle, frame: CGRect(x: 20, y: 10, width: 80, height: 60))
        fixture.store.editBoard(fixture.store.active.id) { $0.items.append(rectangle) }
        fixture.session.selection = [ellipse.id, rectangle.id]
        fixture.session.toggleSelectedShapeFill()
        XCTAssertTrue(fixture.session.selected.allSatisfy { $0.filled == true })
        fixture.session.toggleSelectedShapeFill()
        XCTAssertTrue(fixture.session.selected.allSatisfy { $0.filled == false })

        let center = fixture.canvas.viewport.center
        try fixture.key(.keyDown, code: 49)
        try fixture.drag(from: CGPoint(x: 260, y: 160), to: CGPoint(x: 290, y: 180))
        try fixture.key(.keyUp, code: 49)
        XCTAssertEqual(fixture.canvas.viewport.center, CGPoint(x: center.x - 30, y: center.y - 20))
        XCTAssertFalse(BoardTool.allCases.contains { $0.shortcut == "H" })
    }

    @MainActor
    func testTranslucentFilledShapeHasNoOpaqueEdge() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BoardStore(directory: directory)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 100,
            pixelsHigh: 80,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        let item = BoardItem(
            kind: .rectangle,
            frame: CGRect(x: 10, y: 10, width: 80, height: 60),
            color: .black,
            strokeWidth: 4,
            translucent: true,
            filled: true
        )
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 100, height: 80).fill()
        BoardRenderer.draw(item, in: item.frame, scale: 1, store: store)
        NSGraphicsContext.restoreGraphicsState()

        let center = try XCTUnwrap(bitmap.colorAt(x: 50, y: 40)).alphaComponent
        let innerEdge = try XCTUnwrap(bitmap.colorAt(x: 11, y: 40)).alphaComponent
        XCTAssertEqual(center, 0.35, accuracy: 0.03)
        XCTAssertEqual(innerEdge, center, accuracy: 0.03)
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

    func testCornerRadiusHandleProjectsDragAlongRectangleDiagonal() {
        let frame = CGRect(x: 10, y: 20, width: 320, height: 120)
        let base = BoardGeometry.cornerRadiusHandle(frame, radius: 0)
        let target = BoardGeometry.cornerRadiusHandle(frame, radius: 24)
        XCTAssertEqual((frame.maxX - target.x) / frame.width, (frame.maxY - target.y) / frame.height, accuracy: 0.001)
        XCTAssertEqual(BoardGeometry.draggedCornerRadius(from: base, to: target, in: frame, radius: 0), 24, accuracy: 0.001)
        XCTAssertEqual(BoardGeometry.cornerRadiusHandle(frame, radius: 60), CGPoint(x: frame.midX, y: frame.midY))
        let perpendicular = CGPoint(x: target.x + 12, y: target.y - 32)
        XCTAssertEqual(BoardGeometry.draggedCornerRadius(from: target, to: perpendicular, in: frame, radius: 24), 24, accuracy: 0.001)
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

@MainActor
private final class BoardCanvasFixture {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store: BoardStore
    let session: BoardSession
    let canvas: BoardCanvasView
    private let window: NSWindow

    init() {
        store = BoardStore(directory: directory)
        session = BoardSession(store: store)
        session.snap = false
        canvas = BoardCanvasView(session: session)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 660, height: 420), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
    }

    func close() {
        session.finishEditing()
        store.flush()
        window.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func mouse(_ type: NSEvent.EventType, at point: CGPoint, clicks: Int = 1) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1))
    }

    func drag(from start: CGPoint, to end: CGPoint) throws {
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: start))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: end))
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: end))
    }

    func key(_ type: NSEvent.EventType, code: UInt16) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        if type == .keyDown { canvas.keyDown(with: event) } else { canvas.keyUp(with: event) }
    }
}
