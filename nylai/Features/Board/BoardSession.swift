import AppKit
import UniformTypeIdentifiers
import Observation

enum BoardTool: String, CaseIterable, Identifiable {
    case select, hand, note, pen, eraser, line, arrow, rectangle, ellipse, triangle, diamond, star
    static let shapes: [Self] = [.rectangle, .ellipse, .triangle, .diamond, .star]
    var isShape: Bool { Self.shapes.contains(self) }
    var showsDrawingStyle: Bool { isShape || self == .pen || self == .line || self == .arrow }
    var shortcut: String {
        switch self {
        case .select: "V"; case .hand: "H"; case .note: "N"; case .pen: "B"; case .eraser: "E"
        case .line: "L"; case .arrow: "A"; case .rectangle: "R"; case .ellipse: "O"
        case .triangle: "T"; case .diamond: "D"; case .star: "S"
        }
    }
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .hand: "hand.draw"
        case .note: "note.text"
        case .pen: "pencil.tip"
        case .eraser: "eraser"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .triangle: "triangle"
        case .diamond: "diamond"
        case .star: "star"
        }
    }
    var title: String {
        switch self {
        case .select: L10n.shared.string("选择")
        case .hand: L10n.shared.string("平移")
        case .note: L10n.shared.string("便签")
        case .pen: L10n.shared.string("画笔")
        case .eraser: L10n.shared.string("橡皮擦")
        case .line: L10n.shared.string("直线")
        case .arrow: L10n.shared.string("箭头")
        case .rectangle: L10n.shared.string("矩形")
        case .ellipse: L10n.shared.string("圆形")
        case .triangle: L10n.shared.string("三角形")
        case .diamond: L10n.shared.string("菱形")
        case .star: L10n.shared.string("星形")
        }
    }
    var kind: BoardKind? { BoardKind(rawValue: rawValue) }
}

@MainActor
@Observable
final class BoardSession {
    let store: BoardStore
    var selection: Set<UUID> = []
    var tool: BoardTool = .select { didSet { if tool.isShape { lastShape = tool } } }
    var lastShape: BoardTool = .rectangle
    var color: BoardColor = .black
    var filled = false
    var showsToolShortcuts = false
    var toolbarCollapsed = false
    var focusCanvas: (() -> Void)?
    var strokeWidth: CGFloat = 4
    var dashed = false
    var translucent = false
    var snap = true
    private(set) var editingID: UUID?
    @ObservationIgnored private var editingBoardID: UUID?
    @ObservationIgnored var noteDraft = ""
    var viewportSize = CGSize(width: 800, height: 600)
    var floating = false
    var onPinNote: ((UUID, UUID) -> Void)?

    init(store: BoardStore) { self.store = store }
    var board: BoardDocument { store.active }
    var selected: [BoardItem] { board.items.filter { selection.contains($0.id) } }

    func switchBoard(_ id: UUID) {
        finishEditing()
        selection = []
        store.select(id)
    }

    func focus(_ id: UUID) {
        finishEditing()
        guard let item = board.items.first(where: { $0.id == id }) else { return }
        selection = [id]
        var view = board.viewport
        view.center = CGPoint(x: item.frame.midX, y: item.frame.midY)
        view.zoom = min(1.5, max(view.zoom, 0.7))
        store.viewport(view, boardID: board.id)
    }

    func resetZoom() {
        finishEditing()
        let bounds = board.items.map(\.rotatedBounds).reduce(CGRect.null) { $0.union($1) }
        var view = BoardViewport()
        if !bounds.isNull { view.center = CGPoint(x: bounds.midX, y: bounds.midY) }
        store.viewport(view, boardID: board.id)
    }

    func fit() {
        finishEditing()
        let bounds = board.items.map(\.rotatedBounds).reduce(CGRect.null) { $0.union($1) }
        var view = BoardViewport()
        if !bounds.isNull {
            view.center = CGPoint(x: bounds.midX, y: bounds.midY)
            view.zoom = max(0.08, min(5, (viewportSize.width - 100) / max(1, bounds.width),
                                      (viewportSize.height - 100) / max(1, bounds.height)))
        }
        store.viewport(view, boardID: board.id)
    }

    func zoom(_ factor: CGFloat) {
        finishEditing()
        var view = board.viewport
        view.magnify(factor, at: CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2), in: viewportSize)
        store.viewport(view, boardID: board.id)
    }

    func addNote(at point: CGPoint? = nil) {
        finishEditing()
        let center = board.viewport.center
        let id = store.addText("", boardID: board.id,
            at: point ?? CGPoint(x: center.x - 120, y: center.y - 80), color: .yellow)
        beginEditing(id)
    }

    func beginEditing(_ id: UUID) {
        if editingID == id { return }
        finishEditing()
        guard let item = board.items.first(where: { $0.id == id && $0.kind == .note && !$0.locked }) else { return }
        if item.isCollapsed { store.toggleNoteCollapse(boardID: board.id, itemID: id) }
        selection = [id]
        tool = .select
        if board.viewport.zoom < 0.65 { focus(id) }
        editingBoardID = board.id
        noteDraft = item.text
        editingID = id
    }

    func finishEditing() {
        guard let id = editingID, let boardID = editingBoardID else { return }
        let draft = noteDraft
        editingID = nil
        editingBoardID = nil
        noteDraft = ""
        store.updateText(draft, boardID: boardID, itemID: id)
    }

    func chooseTool(_ value: BoardTool) {
        finishEditing()
        tool = value
        toolbarCollapsed = false
        focusCanvas?()
    }

    func clearBoard() {
        finishEditing()
        guard !board.items.isEmpty else { return }
        store.editBoard(board.id) { $0.items.removeAll() }
        selection = []
    }

    func confirmClear() {
        guard !board.items.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = L10n.shared.string("清空当前画布？")
        alert.informativeText = L10n.shared.string("将移除所有对象，可撤销此操作。")
        alert.addButton(withTitle: L10n.shared.string("清空"))
        alert.addButton(withTitle: L10n.shared.string("取消"))
        if alert.runModal() == .alertFirstButtonReturn { clearBoard() }
    }

    func undo() { finishEditing(); store.undo() }
    func redo() { finishEditing(); store.redo() }

    func select(_ item: BoardItem, extending: Bool) {
        let ids = Set(board.items.filter { $0.id == item.id || (item.group != nil && $0.group == item.group) }.map(\.id))
        if extending {
            if ids.isSubset(of: selection) { selection.subtract(ids) } else { selection.formUnion(ids) }
        } else if !selection.contains(item.id) { selection = ids }
    }

    func mutateSelected(includeLocked: Bool = false, _ edit: (inout BoardItem) -> Void) {
        let ids = selection
        store.editBoard(board.id) { board in
            for i in board.items.indices where ids.contains(board.items[i].id) && (includeLocked || !board.items[i].locked) {
                edit(&board.items[i])
            }
        }
    }

    func delete() {
        finishEditing()
        let ids = selection
        store.editBoard(board.id) { $0.items.removeAll { ids.contains($0.id) && !$0.locked } }
        selection.formIntersection(Set(board.items.map(\.id)))
    }

    func group() {
        finishEditing()
        guard selected.count > 1, selected.allSatisfy({ !$0.locked }) else { return }
        let id = UUID()
        mutateSelected { $0.group = id }
    }
    func ungroup() { finishEditing(); mutateSelected { $0.group = nil } }
    func toggleLock() {
        finishEditing()
        let lock = selected.contains { !$0.locked }
        mutateSelected(includeLocked: true) { $0.locked = lock }
    }
    func layer(front: Bool) {
        finishEditing()
        let ids = selection
        store.editBoard(board.id) { board in
            let moved = board.items.filter { ids.contains($0.id) && !$0.locked }
            let rest = board.items.filter { !ids.contains($0.id) || $0.locked }
            board.items = front ? rest + moved : moved + rest
        }
    }

    func paste(_ pasteboard: NSPasteboard = .general, at point: CGPoint? = nil) {
        finishEditing()
        let origin = point ?? store.nextCapturePoint(in: board.id)
        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage], !images.isEmpty {
            for (i, image) in images.enumerated() {
                store.addImage(image, boardID: board.id, at: CGPoint(x: origin.x + CGFloat(i) * 24, y: origin.y + CGFloat(i) * 24))
            }
        } else if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            for (i, url) in urls.enumerated() {
                if let image = NSImage(contentsOf: url) {
                    store.addImage(image, boardID: board.id, at: CGPoint(x: origin.x + CGFloat(i) * 24, y: origin.y + CGFloat(i) * 24))
                }
            }
        } else if let text = pasteboard.string(forType: .string), !text.isEmpty {
            selection = [store.addText(text, boardID: board.id, at: origin, color: .yellow)]
        }
    }

    func copy() {
        finishEditing()
        let items = selected
        if items.count == 1, let item = items.first {
            if item.kind == .note {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.text, forType: .string)
                return
            }
            if let asset = item.asset, let image = store.image(asset) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
                return
            }
        }
        export(copy: true)
    }

    func export(copy: Bool = false) {
        finishEditing()
        let items = selected.isEmpty ? board.items : selected
        guard let image = BoardRenderer.export(items, store: store) else {
            store.error = L10n.shared.string("画布为空或导出尺寸过大。")
            return
        }
        if copy {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = board.title + ".png"
            guard panel.runModal() == .OK, let url = panel.url,
                  let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let data = bitmap.representation(using: .png, properties: [:]) else { return }
            do { try data.write(to: url, options: .atomic) }
            catch { store.error = error.localizedDescription }
        }
    }
}
