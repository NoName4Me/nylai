import AppKit
import Observation

enum BoardTool: String, CaseIterable, Identifiable {
    case select, hand, note, pen, marker, eraser, line, arrow, rectangle, ellipse
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .hand: "hand.draw"
        case .note: "note.text"
        case .pen: "pencil.tip"
        case .marker: "highlighter"
        case .eraser: "eraser"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        }
    }
    var title: String {
        switch self {
        case .select: L10n.shared.string("选择")
        case .hand: L10n.shared.string("平移")
        case .note: L10n.shared.string("便签")
        case .pen: L10n.shared.string("画笔")
        case .marker: L10n.shared.string("马克笔")
        case .eraser: L10n.shared.string("橡皮擦")
        case .line: L10n.shared.string("直线")
        case .arrow: L10n.shared.string("箭头")
        case .rectangle: L10n.shared.string("矩形")
        case .ellipse: L10n.shared.string("椭圆")
        }
    }
    var kind: BoardKind? { BoardKind(rawValue: rawValue) }
}

@MainActor
@Observable
final class BoardSession {
    let store: BoardStore
    var selection: Set<UUID> = []
    var tool: BoardTool = .select
    var color: BoardColor = .yellow
    var strokeWidth: CGFloat = 3
    var snap = true
    var editingID: UUID?
    var viewportSize = CGSize(width: 800, height: 600)
    var floating = false
    var onPinNote: ((UUID, UUID) -> Void)?

    init(store: BoardStore) { self.store = store }
    var board: BoardDocument { store.active }
    var selected: [BoardItem] { board.items.filter { selection.contains($0.id) } }

    func switchBoard(_ id: UUID) {
        selection = []
        editingID = nil
        store.select(id)
    }

    func focus(_ id: UUID) {
        guard let item = board.items.first(where: { $0.id == id }) else { return }
        selection = [id]
        var view = board.viewport
        view.center = CGPoint(x: item.frame.midX, y: item.frame.midY)
        view.zoom = min(1.5, max(view.zoom, 0.7))
        store.viewport(view, boardID: board.id)
    }

    func fit() {
        let bounds = board.items.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        var view = BoardViewport()
        if !bounds.isNull {
            view.center = CGPoint(x: bounds.midX, y: bounds.midY)
            view.zoom = max(0.08, min(5, (viewportSize.width - 100) / max(1, bounds.width),
                                      (viewportSize.height - 100) / max(1, bounds.height)))
        }
        store.viewport(view, boardID: board.id)
    }

    func zoom(_ factor: CGFloat) {
        var view = board.viewport
        view.magnify(factor, at: CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2), in: viewportSize)
        store.viewport(view, boardID: board.id)
    }

    func addNote(at point: CGPoint? = nil) {
        let center = board.viewport.center
        let id = store.addText("", boardID: board.id,
            at: point ?? CGPoint(x: center.x - 120, y: center.y - 80), color: color)
        selection = [id]
        editingID = id
        tool = .select
    }

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
        let ids = selection
        store.editBoard(board.id) { $0.items.removeAll { ids.contains($0.id) && !$0.locked } }
        selection.formIntersection(Set(board.items.map(\.id)))
    }

    func group() {
        guard selected.count > 1, selected.allSatisfy({ !$0.locked }) else { return }
        let id = UUID()
        mutateSelected { $0.group = id }
    }
    func ungroup() { mutateSelected { $0.group = nil } }
    func toggleLock() {
        let lock = selected.contains { !$0.locked }
        mutateSelected(includeLocked: true) { $0.locked = lock }
    }
    func layer(front: Bool) {
        let ids = selection
        store.editBoard(board.id) { board in
            let moved = board.items.filter { ids.contains($0.id) && !$0.locked }
            let rest = board.items.filter { !ids.contains($0.id) || $0.locked }
            board.items = front ? rest + moved : moved + rest
        }
    }

    func paste(_ pasteboard: NSPasteboard = .general, at point: CGPoint? = nil) {
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
            selection = [store.addText(text, boardID: board.id, at: origin, color: color)]
        }
    }

    func copy() {
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
