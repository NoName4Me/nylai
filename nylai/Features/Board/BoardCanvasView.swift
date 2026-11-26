import AppKit
import SwiftUI

struct BoardCanvasRepresentable: NSViewRepresentable {
    let session: BoardSession
    // Read observable inputs in SwiftUI and pass them across the AppKit boundary.
    let board: BoardDocument
    let selection: Set<UUID>
    let tool: BoardTool

    func makeNSView(context: Context) -> BoardCanvasView { BoardCanvasView(session: session) }
    func updateNSView(_ view: BoardCanvasView, context: Context) {
        view.needsDisplay = true
        view.window?.invalidateCursorRects(for: view)
    }
}

@MainActor
final class BoardCanvasView: NSView {
    let session: BoardSession
    private enum Drag {
        case pan(start: CGPoint, viewport: BoardViewport)
        case move(start: CGPoint, items: [BoardItem])
        case resize(start: CGPoint, item: BoardItem)
        case marquee(start: CGPoint, previous: Set<UUID>)
        case stroke(start: CGPoint, kind: BoardKind)
    }
    private var drag: Drag?
    private var preview: [BoardItem] = []
    private var marquee: CGRect?
    private var stroke: [CGPoint] = []
    private var spaceDown = false
    private var colorNoteID: UUID?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var viewport: BoardViewport { session.board.viewport }

    init(session: BoardSession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        registerForDraggedTypes([.fileURL, .png, .tiff, .string])
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        if session.viewportSize != bounds.size { session.viewportSize = bounds.size }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        drawGrid()
        let items = session.board.items
        for item in items {
            let shown = preview.first { $0.id == item.id } ?? item
            let frame = viewport.rect(shown.frame, in: bounds.size)
            guard frame.intersects(dirtyRect.insetBy(dx: -20, dy: -20)) else { continue }
            BoardRenderer.draw(shown, in: frame, scale: viewport.zoom, store: session.store, showsNoteControls: true)
        }
        for item in preview where !items.contains(where: { $0.id == item.id }) {
            BoardRenderer.draw(item, in: viewport.rect(item.frame, in: bounds.size), scale: viewport.zoom, store: session.store)
        }
        for item in items where session.selection.contains(item.id) {
            let shown = preview.first { $0.id == item.id } ?? item
            let frame = viewport.rect(shown.frame, in: bounds.size)
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(rect: frame.insetBy(dx: -2, dy: -2))
            outline.lineWidth = 1.2
            if item.locked { outline.setLineDash([4, 3], count: 2, phase: 0) }
            outline.stroke()
            if session.selection.count == 1 && !item.locked && !item.isCollapsed {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: handle(frame), xRadius: 2, yRadius: 2).fill()
            }
        }
        if let marquee {
            NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(rect: marquee).fill()
            NSColor.controlAccentColor.withAlphaComponent(0.75).setStroke()
            NSBezierPath(rect: marquee).stroke()
        }
    }

    private func drawGrid() {
        let spacing = max(12, 24 * viewport.zoom)
        let origin = viewport.screen(.zero, in: bounds.size)
        let startX = origin.x.truncatingRemainder(dividingBy: spacing)
        let startY = origin.y.truncatingRemainder(dividingBy: spacing)
        NSColor.secondaryLabelColor.withAlphaComponent(0.22).setFill()
        let path = NSBezierPath()
        var x = startX
        while x < bounds.width {
            var y = startY
            while y < bounds.height {
                path.appendOval(in: CGRect(x: x, y: y, width: 1.2, height: 1.2))
                y += spacing
            }
            x += spacing
        }
        path.fill()
    }

    private func handle(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.maxX - 4, y: rect.maxY - 4, width: 8, height: 8)
    }
    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }
    private func world(_ p: CGPoint) -> CGPoint { viewport.world(p, in: bounds.size) }
    private func hit(_ p: CGPoint) -> BoardItem? {
        session.board.items.reversed().first { $0.frame.insetBy(dx: -4 / viewport.zoom, dy: -4 / viewport.zoom).contains(p) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let screen = point(event)
        let p = world(screen)
        if spaceDown || session.tool == .hand {
            drag = .pan(start: screen, viewport: viewport)
            return
        }
        if session.tool == .note {
            session.addNote(at: p)
            return
        }
        if session.tool == .eraser {
            if let item = hit(p), item.kind != .note, item.kind != .image, !item.locked {
                session.store.editBoard(session.board.id) { $0.items.removeAll { $0.id == item.id } }
            }
            return
        }
        if let kind = session.tool.kind {
            session.selection = []
            stroke = [p]
            drag = .stroke(start: p, kind: kind)
            return
        }
        if let item = session.selected.first, session.selection.count == 1, !item.locked, !item.isCollapsed,
           handle(viewport.rect(item.frame, in: bounds.size)).insetBy(dx: -5, dy: -5).contains(screen) {
            drag = .resize(start: p, item: item)
            return
        }
        if let item = hit(p) {
            if item.kind == .note, !item.locked, event.clickCount == 1, !event.modifierFlags.contains(.shift) {
                if BoardRenderer.noteColorRect(item.frame).contains(p) { showNoteColors(item, event: event); return }
                if BoardRenderer.noteCollapseRect(item.frame).contains(p) {
                    session.store.toggleNoteCollapse(boardID: session.board.id, itemID: item.id); return
                }
            }
            if event.clickCount == 1, !event.modifierFlags.contains(.shift), let line = BoardRenderer.todoLine(in: item, at: p) {
                session.store.toggleTodo(boardID: session.board.id, itemID: item.id, line: line)
                return
            }
            session.select(item, extending: event.modifierFlags.contains(.shift))
            if event.clickCount == 2, !item.locked {
                if item.kind == .note { session.editingID = item.id; return }
                if let asset = item.asset, let image = session.store.image(asset) {
                    let panel = NSWindow(contentRect: CGRect(origin: .zero, size: CGSize(width: 720, height: 520)),
                        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                    panel.isReleasedWhenClosed = false
                    let view = NSImageView(image: image)
                    view.imageScaling = .scaleProportionallyUpOrDown
                    panel.contentView = view
                    panel.title = L10n.shared.string("图片预览")
                    panel.center()
                    panel.makeKeyAndOrderFront(nil)
                    return
                }
            }
            drag = .move(start: p, items: session.selected.filter { !$0.locked })
        } else {
            if event.clickCount == 2 { session.addNote(at: p); return }
            let previous = event.modifierFlags.contains(.shift) ? session.selection : []
            session.selection = previous
            drag = .marquee(start: screen, previous: previous)
        }
        needsDisplay = true
    }

    private func showNoteColors(_ item: BoardItem, event: NSEvent) {
        colorNoteID = item.id
        let menu = NSMenu()
        for color in BoardColor.allCases {
            let entry = menu.addItem(withTitle: color.title, action: #selector(changeNoteColor(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = color.rawValue
            entry.state = item.color == color ? .on : .off
            let image = NSImage(size: CGSize(width: 15, height: 15))
            image.lockFocus()
            (color == .clear ? NSColor.controlBackgroundColor : color.paper).setFill()
            NSBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 13, height: 13)).fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 13, height: 13)).stroke()
            image.unlockFocus()
            entry.image = image
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        colorNoteID = nil
    }

    @objc private func changeNoteColor(_ sender: NSMenuItem) {
        guard let id = colorNoteID, let raw = sender.representedObject as? String,
              let color = BoardColor(rawValue: raw) else { return }
        session.store.editBoard(session.board.id) { board in
            guard let i = board.items.firstIndex(where: { $0.id == id && !$0.locked }) else { return }
            board.items[i].color = color
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let screen = point(event), p = world(screen)
        switch drag {
        case .pan(let start, var view):
            view.center.x -= (screen.x - start.x) / view.zoom
            view.center.y -= (screen.y - start.y) / view.zoom
            session.store.viewport(view, boardID: session.board.id)
        case .move(let start, let items):
            var dx = p.x - start.x, dy = p.y - start.y
            if session.snap, let first = items.first, !event.modifierFlags.contains(.option) {
                let threshold = 5 / viewport.zoom
                let moving = first.frame.offsetBy(dx: dx, dy: dy)
                let others = session.board.items.filter { !session.selection.contains($0.id) }
                let xs = others.flatMap { [$0.frame.minX, $0.frame.midX, $0.frame.maxX] }
                let ys = others.flatMap { [$0.frame.minY, $0.frame.midY, $0.frame.maxY] }
                if let delta = nearestDelta([moving.minX, moving.midX, moving.maxX], targets: xs, threshold: threshold) { dx += delta }
                if let delta = nearestDelta([moving.minY, moving.midY, moving.maxY], targets: ys, threshold: threshold) { dy += delta }
            }
            preview = items.map { item in var copy = item; copy.frame = item.frame.offsetBy(dx: dx, dy: dy); return copy }
        case .resize(let start, let item):
            var copy = item
            let width = max(item.kind == .note ? 100 : 18, item.frame.width + p.x - start.x)
            let height = item.kind == .image || event.modifierFlags.contains(.shift)
                ? width * item.frame.height / item.frame.width : max(item.kind == .note ? 64 : 18, item.frame.height + p.y - start.y)
            copy.frame.size = CGSize(width: width, height: height)
            preview = [copy]
        case .marquee(let start, let previous):
            let rect = makeRect(start, screen)
            marquee = rect
            let selected = session.board.items.filter { rect.intersects(viewport.rect($0.frame, in: bounds.size)) }
            session.selection = previous.union(selected.map(\.id))
        case .stroke(let start, let kind):
            if kind == .pen || kind == .marker {
                if let last = stroke.last, hypot(p.x - last.x, p.y - last.y) >= 1 / viewport.zoom { stroke.append(p) }
            } else {
                stroke = [start, p]
            }
            let rect = strokeBounds(stroke)
            let normalized = stroke.map { CGPoint(x: ($0.x - rect.minX) / rect.width, y: ($0.y - rect.minY) / rect.height) }
            let id = preview.first?.id ?? UUID()
            preview = [BoardItem(id: id, kind: kind, frame: rect, color: session.color,
                                 points: normalized, strokeWidth: session.strokeWidth)]
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let drag {
            switch drag {
            case .move, .resize:
                let changes = preview
                session.store.editBoard(session.board.id) { board in
                    for item in changes {
                        if let i = board.items.firstIndex(where: { $0.id == item.id }), !board.items[i].locked {
                            board.items[i].frame = item.frame
                        }
                    }
                }
            case .stroke(_, let kind):
                if preview.isEmpty, let first = stroke.first, kind == .pen || kind == .marker {
                    preview = [BoardItem(kind: kind, frame: CGRect(origin: first, size: CGSize(width: 1, height: 1)),
                                         color: session.color, points: [.zero], strokeWidth: session.strokeWidth)]
                }
                let items = preview
                session.store.editBoard(session.board.id) { $0.items.append(contentsOf: items) }
            case .pan:
                session.store.flush()
            case .marquee: break
            }
        }
        clearDrag()
    }

    private func clearDrag() {
        drag = nil; preview = []; marquee = nil; stroke = []; needsDisplay = true
    }
    private func makeRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    private func strokeBounds(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        let x = xs.min() ?? 0, y = ys.min() ?? 0
        return CGRect(x: x, y: y, width: max(1, (xs.max() ?? x) - x), height: max(1, (ys.max() ?? y) - y))
    }
    private func nearestDelta(_ values: [CGFloat], targets: [CGFloat], threshold: CGFloat) -> CGFloat? {
        values.flatMap { value in targets.map { $0 - value } }
            .filter { abs($0) <= threshold }.min { abs($0) < abs($1) }
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        drag = .pan(start: point(event), viewport: viewport)
    }
    override func otherMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func otherMouseUp(with event: NSEvent) { mouseUp(with: event) }

    override func scrollWheel(with event: NSEvent) {
        var view = viewport
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            view.magnify(exp(event.scrollingDeltaY * 0.012), at: point(event), in: bounds.size)
        } else {
            view.center.x -= event.scrollingDeltaX / view.zoom
            view.center.y -= event.scrollingDeltaY / view.zoom
        }
        session.store.viewport(view, boardID: session.board.id)
        needsDisplay = true
    }
    override func magnify(with event: NSEvent) {
        var view = viewport
        view.magnify(1 + event.magnification, at: point(event), in: bounds.size)
        session.store.viewport(view, boardID: session.board.id)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        if command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v": session.paste(); return
            case "c": session.copy(); return
            case "a": selectAll(nil); return
            case "z": if event.modifierFlags.contains(.shift) { session.store.redo() } else { session.store.undo() }; return
            case "g": if event.modifierFlags.contains(.shift) { session.ungroup() } else { session.group() }; return
            case "0": if event.modifierFlags.contains(.shift) { session.fit() } else { session.resetZoom() }; return
            case "+", "=": session.zoom(1.25); return
            case "-": session.zoom(0.8); return
            default: break
            }
        }
        switch event.keyCode {
        case 49: spaceDown = true
        case 51, 117: session.delete()
        case 53: clearDrag(); session.selection = []; session.tool = .select
        case 123, 124, 125, 126:
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let dx: CGFloat = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
            let dy: CGFloat = event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0
            session.mutateSelected { $0.frame = $0.frame.offsetBy(dx: dx, dy: dy) }
        default: super.keyDown(with: event)
        }
    }
    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceDown = false } else { super.keyUp(with: event) }
    }
    override func resignFirstResponder() -> Bool {
        spaceDown = false
        clearDrag()
        return super.resignFirstResponder()
    }
    @objc func paste(_ sender: Any?) { session.paste() }
    @objc func copy(_ sender: Any?) { session.copy() }
    override func selectAll(_ sender: Any?) { session.selection = Set(session.board.items.map(\.id)) }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        session.paste(sender.draggingPasteboard, at: world(convert(sender.draggingLocation, from: nil)))
        return true
    }
}
