import AppKit
import SwiftUI

struct BoardCanvasRepresentable: NSViewRepresentable {
    let session: BoardSession
    // Read observable inputs in SwiftUI and pass them across the AppKit boundary.
    let board: BoardDocument
    let selection: Set<UUID>
    let tool: BoardTool
    let editingID: UUID?

    func makeNSView(context: Context) -> BoardCanvasView { BoardCanvasView(session: session) }
    func updateNSView(_ view: BoardCanvasView, context: Context) {
        view.needsDisplay = true
        view.syncEditor()
        view.window?.invalidateCursorRects(for: view)
    }
}

@MainActor
final class BoardCanvasView: NSView, NSTextViewDelegate {
    let session: BoardSession
    private enum Drag {
        case pan(start: CGPoint, viewport: BoardViewport)
        case move(start: CGPoint, items: [BoardItem])
        case resize(start: CGPoint, item: BoardItem)
        case rotate(start: CGPoint, item: BoardItem)
        case corner(start: CGPoint, item: BoardItem)
        case endpoint(item: BoardItem, index: Int)
        case marquee(start: CGPoint, previous: Set<UUID>)
        case stroke(start: CGPoint, kind: BoardKind)
        case noteText(BoardNoteTextLayout)
    }
    private struct NoteSelection {
        let itemID: UUID
        let anchor: Int
        var end: Int

        var range: NSRange {
            NSRange(location: min(anchor, end), length: abs(end - anchor))
        }
    }
    private var drag: Drag?
    private var preview: [BoardItem] = []
    private var marquee: CGRect?
    private var stroke: [CGPoint] = []
    private var spaceDown = false
    private var colorNoteID: UUID?
    private var noteEditor: BoardInlineTextView?
    private var noteScroll: NSScrollView?
    private var editorID: UUID?
    private var menuPoint: CGPoint?
    private var noteSelection: NoteSelection?
    private var noteTrackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    var viewport: BoardViewport { session.board.viewport }

    init(session: BoardSession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        session.focusCanvas = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
        session.selectedNoteText = { [weak self] in
            guard let self, let selection = self.noteSelection, selection.range.length > 0,
                  let text = self.selectableNoteText() else { return nil }
            guard NSMaxRange(selection.range) <= text.length else { return nil }
            return text.substring(with: selection.range)
        }
        registerForDraggedTypes([.fileURL, .png, .tiff, .string])
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        if session.viewportSize != bounds.size { session.viewportSize = bounds.size }
        layoutEditor()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard noteTrackingArea == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        noteTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let location = world(point(event))
        guard session.tool == .select, !spaceDown, let note = hit(location), note.kind == .note else {
            NSCursor.arrow.set()
            return
        }
        if !note.locked, BoardRenderer.noteHeaderRect(note.frame).contains(location),
           !BoardRenderer.noteColorRect(note.frame).contains(location), !BoardRenderer.noteCollapseRect(note.frame).contains(location) {
            NSCursor.openHand.set()
        } else if !note.isCollapsed, BoardRenderer.noteBodyRect(note.frame).contains(location),
                  BoardRenderer.todoLine(in: note, at: location) == nil {
            NSCursor.iBeam.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    func syncEditor() {
        let id = session.editingID
        if let selection = noteSelection,
           id != nil || session.tool != .select || !session.selection.contains(selection.itemID) {
            noteSelection = nil
        }
        if editorID == id { layoutEditor(); return }
        noteEditor?.onFinish = nil
        noteEditor?.onResign = nil
        noteEditor?.delegate = nil
        if let noteEditor, window?.firstResponder === noteEditor { window?.makeFirstResponder(self) }
        noteScroll?.removeFromSuperview()
        noteScroll = nil; noteEditor = nil; editorID = nil
        guard let id, session.board.items.contains(where: { $0.id == id }) else { return }
        let scroll = NSScrollView(frame: .zero)
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = BoardInlineTextView(frame: .zero)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.drawsBackground = false
        editor.allowsUndo = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainerInset = .zero
        editor.textColor = NSColor(calibratedWhite: 0.16, alpha: 1)
        editor.insertionPointColor = editor.textColor ?? .black
        editor.string = session.noteDraft
        editor.delegate = self
        editor.onFinish = { [weak self] in self?.finishInlineEdit() }
        editor.onResign = { [weak self] in
            guard let self, self.session.editingID == id else { return }
            self.session.finishEditing()
        }
        scroll.documentView = editor
        editorID = id; noteEditor = editor; noteScroll = scroll
        addSubview(scroll)
        layoutEditor()
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        DispatchQueue.main.async { [weak self, weak editor] in
            guard let self, let editor, self.editorID == id, self.session.editingID == id else { return }
            self.window?.makeFirstResponder(editor)
        }
    }

    private func layoutEditor() {
        guard let id = editorID, let editor = noteEditor, let scroll = noteScroll,
              let item = session.board.items.first(where: { $0.id == id }) else { return }
        let scale = viewport.zoom
        let frame = viewport.rect(item.frame, in: bounds.size)
        scroll.frame = BoardRenderer.noteBodyRect(frame, scale: scale)
        editor.minSize = CGSize(width: 0, height: scroll.contentSize.height)
        editor.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        if abs((editor.font?.pointSize ?? 0) - 14 * scale) > 0.1 { editor.font = .systemFont(ofSize: 14 * scale) }
        editor.frame.size = CGSize(width: scroll.contentSize.width, height: max(editor.frame.height, scroll.contentSize.height))
        editor.textContainer?.containerSize = CGSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
    }

    func textDidChange(_ notification: Notification) {
        if let editor = noteEditor, (notification.object as? NSTextView) === editor { session.noteDraft = editor.string }
    }

    private func finishInlineEdit() {
        session.finishEditing()
        window?.makeFirstResponder(self)
        syncEditor()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        drawGrid()
        let items = session.board.items
        for item in items {
            let shown = preview.first { $0.id == item.id } ?? item
            let frame = viewport.rect(shown.frame, in: bounds.size)
            guard viewport.rect(shown.rotatedBounds, in: bounds.size).intersects(dirtyRect.insetBy(dx: -30, dy: -30)) else { continue }
            let textRange = noteSelection.flatMap { $0.itemID == item.id ? $0.range : nil }
            BoardRenderer.draw(shown, in: frame, scale: viewport.zoom, store: session.store,
                               showsNoteControls: true, hidesNoteText: session.editingID == item.id, selectedNoteText: textRange)
        }
        for item in preview where !items.contains(where: { $0.id == item.id }) {
            BoardRenderer.draw(item, in: viewport.rect(item.frame, in: bounds.size), scale: viewport.zoom, store: session.store)
        }
        for item in items where session.selection.contains(item.id) {
            let shown = preview.first { $0.id == item.id } ?? item
            drawSelection(shown)
        }
        if let marquee {
            NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(rect: marquee).fill()
            NSColor.controlAccentColor.withAlphaComponent(0.75).setStroke()
            NSBezierPath(rect: marquee).stroke()
        }
    }

    private func displayFrame(_ item: BoardItem) -> CGRect {
        let frame = viewport.rect(item.frame, in: bounds.size)
        if let asset = item.asset, let image = session.store.image(asset) {
            return BoardGeometry.imageRect(frame, imageSize: image.size)
        }
        return frame
    }

    private let rotationHandleRadius: CGFloat = 14

    private func handles(_ item: BoardItem) -> (resize: CGPoint, rotation: CGPoint, corner: CGPoint) {
        let frame = displayFrame(item)
        let t = BoardGeometry.transform(frame, angle: item.angle)
        let rotationOffset = rotationHandleRadius / sqrt(2)
        return (CGPoint(x: frame.maxX, y: frame.maxY).applying(t),
                CGPoint(x: frame.maxX + rotationOffset, y: frame.minY - rotationOffset).applying(t),
                BoardGeometry.cornerRadiusHandle(frame, radius: item.radius * viewport.zoom).applying(t))
    }

    private func drawHandle(_ point: CGPoint, circle: Bool = false) {
        let rect = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
        let path = circle ? NSBezierPath(ovalIn: rect) : NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        NSColor.windowBackgroundColor.setFill(); path.fill()
        NSColor.controlAccentColor.setStroke(); path.lineWidth = 1.4; path.stroke()
    }

    private func drawSelection(_ item: BoardItem) {
        let frame = displayFrame(item)
        let single = session.selection.count == 1 && !item.locked && !item.isCollapsed
        if item.kind.isLine {
            for p in BoardGeometry.endpoints(item) { drawHandle(viewport.screen(p, in: bounds.size), circle: true) }
            return
        }
        let t = BoardGeometry.transform(frame, angle: item.angle)
        let corners = [frame.origin, CGPoint(x: frame.maxX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: frame.minX, y: frame.maxY)].map { $0.applying(t) }
        let outline = NSBezierPath()
        outline.move(to: corners[0]); for p in corners.dropFirst() { outline.line(to: p) }; outline.close()
        outline.lineWidth = 1.2
        if item.locked { outline.setLineDash([4, 3], count: 2, phase: 0) }
        NSColor.controlAccentColor.setStroke(); outline.stroke()
        guard single else { return }
        let h = handles(item)
        drawHandle(h.resize)
        if item.kind.isAnnotation {
            let r = rotationHandleRadius
            let control = r * 0.55228475
            let x = frame.maxX, y = frame.minY
            let arc = NSBezierPath()
            arc.move(to: CGPoint(x: x, y: y - r).applying(t))
            arc.curve(to: CGPoint(x: x + r, y: y).applying(t),
                      controlPoint1: CGPoint(x: x + control, y: y - r).applying(t),
                      controlPoint2: CGPoint(x: x + r, y: y - control).applying(t))
            arc.lineCapStyle = .round
            arc.lineWidth = 1.6
            arc.stroke()
        }
        if item.kind.supportsCornerRadius { drawHandle(h.corner, circle: true) }
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
        let screen = viewport.screen(p, in: bounds.size)
        return session.board.items.reversed().first { item in
            if item.kind.isLine {
                let ends = BoardGeometry.endpoints(item).map { viewport.screen($0, in: bounds.size) }
                guard ends.count == 2 else { return false }
                let a = ends[0], b = ends[1]
                let dx = b.x - a.x, dy = b.y - a.y
                let t = max(0, min(1, ((screen.x - a.x) * dx + (screen.y - a.y) * dy) / max(0.01, dx * dx + dy * dy)))
                return hypot(screen.x - a.x - t * dx, screen.y - a.y - t * dy) <= max(6, item.strokeWidth * viewport.zoom / 2 + 3)
            }
            let frame = displayFrame(item)
            let local = screen.applying(BoardGeometry.transform(frame, angle: -item.angle))
            return frame.insetBy(dx: -4, dy: -4).contains(local)
        }
    }

    override func mouseDown(with event: NSEvent) {
        noteSelection = nil
        session.finishEditing()
        syncEditor()
        needsDisplay = true
        window?.makeFirstResponder(self)
        let screen = point(event)
        let p = world(screen)
        if spaceDown {
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
        if let item = session.selected.first, session.selection.count == 1, !item.locked, !item.isCollapsed {
            func near(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) <= 10 }
            if item.kind.isLine {
                let endpoints = BoardGeometry.endpoints(item).map { viewport.screen($0, in: bounds.size) }
                if let index = endpoints.firstIndex(where: { near($0, screen) }) {
                    drag = .endpoint(item: item, index: index); return
                }
            } else {
                let h = handles(item)
                if item.kind.isAnnotation && hypot(screen.x - h.rotation.x, screen.y - h.rotation.y) <= 11 {
                    drag = .rotate(start: p, item: item); return
                }
                if item.kind.supportsCornerRadius && near(h.corner, screen)
                    && hypot(screen.x - h.corner.x, screen.y - h.corner.y) < hypot(screen.x - h.resize.x, screen.y - h.resize.y) {
                    drag = .corner(start: screen, item: item); return
                }
                if near(h.resize, screen) { drag = .resize(start: p, item: item); return }
            }
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
                if item.kind == .note { session.beginEditing(item.id); syncEditor(); return }
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
            if item.kind == .note, !BoardRenderer.noteHeaderRect(item.frame).contains(p) {
                if !item.isCollapsed, !event.modifierFlags.contains(.shift), BoardRenderer.noteBodyRect(item.frame).contains(p) {
                    let layout = BoardNoteTextLayout(item: item, frame: displayFrame(item), scale: viewport.zoom)
                    let index = layout.insertionIndex(at: screen)
                    noteSelection = NoteSelection(itemID: item.id, anchor: index, end: index)
                    drag = .noteText(layout)
                }
                return
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
        for color in BoardColor.noteColors {
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

    override func rightMouseDown(with event: NSEvent) {
        session.finishEditing(); syncEditor()
        window?.makeFirstResponder(self)
        let location = world(point(event))
        menuPoint = location
        let target = hit(location)
        if target?.id != noteSelection?.itemID { noteSelection = nil; needsDisplay = true }
        if let target { session.select(target, extending: false) } else { session.selection = [] }
        let menu = NSMenu()
        func add(_ title: String, _ selector: Selector, enabled: Bool = true) {
            let entry = menu.addItem(withTitle: L10n.shared.string(title), action: selector, keyEquivalent: "")
            entry.target = self; entry.isEnabled = enabled
        }
        menu.autoenablesItems = false
        if let target {
            add("复制", #selector(menuCopy))
            add("锁定 / 解锁", #selector(menuLock))
            if target.kind.isShape { add("填充 / 取消填充", #selector(menuFill), enabled: !target.locked) }
            if target.kind.isAnnotation { add("重置旋转", #selector(menuResetRotation), enabled: !target.locked) }
            add("移到最前", #selector(menuFront), enabled: !target.locked)
            add("移到最后", #selector(menuBack), enabled: !target.locked)
            add("编组", #selector(menuGroup), enabled: session.selection.count > 1)
            add("取消编组", #selector(menuUngroup), enabled: target.group != nil)
            menu.addItem(.separator())
            add("删除", #selector(menuDelete), enabled: !target.locked)
        } else {
            add("粘贴", #selector(menuPaste))
            add("新建便签", #selector(menuNote))
            add("全选", #selector(menuSelectAll))
            add("适应全部", #selector(menuFit))
            add("撤销", #selector(menuUndo), enabled: !session.store.undoStack.isEmpty)
            menu.addItem(.separator())
            add("清空画布", #selector(menuClear), enabled: !session.board.items.isEmpty)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        menuPoint = nil
    }
    @objc private func menuCopy() { session.copy() }
    @objc private func menuLock() { session.toggleLock() }
    @objc private func menuFill() { session.toggleSelectedShapeFill() }
    @objc private func menuResetRotation() { session.mutateSelected { $0.rotation = nil } }
    @objc private func menuFront() { session.layer(front: true) }
    @objc private func menuBack() { session.layer(front: false) }
    @objc private func menuGroup() { session.group() }
    @objc private func menuUngroup() { session.ungroup() }
    @objc private func menuDelete() { session.delete() }
    @objc private func menuPaste() { session.paste(at: menuPoint) }
    @objc private func menuNote() { session.addNote(at: menuPoint); syncEditor() }
    @objc private func menuSelectAll() { selectAll(nil) }
    @objc private func menuFit() { session.fit() }
    @objc private func menuUndo() { session.undo() }
    @objc private func menuClear() { session.confirmClear() }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let screen = point(event), p = world(screen)
        switch drag {
        case .noteText(let layout):
            noteSelection?.end = layout.insertionIndex(at: screen)
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
            let dx = p.x - start.x, dy = p.y - start.y
            let localDX = dx * cos(item.angle) + dy * sin(item.angle)
            let localDY = -dx * sin(item.angle) + dy * cos(item.angle)
            let width = max(item.kind == .note ? 100 : 18, item.frame.width + localDX)
            let height = item.kind == .image || event.modifierFlags.contains(.shift)
                ? width * item.frame.height / item.frame.width : max(item.kind == .note ? 64 : 18, item.frame.height + localDY)
            copy.frame.size = CGSize(width: width, height: height)
            if item.angle != 0 {
                let old = item.frame.origin.applying(BoardGeometry.transform(item.frame, angle: item.angle))
                let next = copy.frame.origin.applying(BoardGeometry.transform(copy.frame, angle: item.angle))
                copy.frame.origin.x += old.x - next.x
                copy.frame.origin.y += old.y - next.y
            }
            preview = [copy]
        case .rotate(let start, let item):
            var copy = item
            let center = CGPoint(x: item.frame.midX, y: item.frame.midY)
            var angle = item.angle + atan2(p.y - center.y, p.x - center.x) - atan2(start.y - center.y, start.x - center.x)
            if event.modifierFlags.contains(.shift) { angle = (angle / (.pi / 12)).rounded() * (.pi / 12) }
            copy.rotation = angle
            preview = [copy]
        case .corner(let start, let item):
            var copy = item
            let frame = displayFrame(item)
            let inverse = BoardGeometry.transform(frame, angle: -item.angle)
            copy.cornerRadius = BoardGeometry.draggedCornerRadius(
                from: start.applying(inverse), to: screen.applying(inverse), in: frame, radius: item.radius * viewport.zoom
            ) / viewport.zoom
            preview = [copy]
        case .endpoint(let item, let index):
            var copy = item
            let ends = BoardGeometry.endpoints(item)
            guard ends.count == 2 else { return }
            let other = ends[1 - index]
            let end = BoardGeometry.constrained(p, from: other, shape: false, control: event.modifierFlags.contains(.control), shift: event.modifierFlags.contains(.shift))
            BoardGeometry.setEndpoints(&copy, index == 0 ? end : other, index == 1 ? end : other)
            preview = [copy]
        case .marquee(let start, let previous):
            let rect = makeRect(start, screen)
            marquee = rect
            let selected = session.board.items.filter { rect.intersects(viewport.rect($0.rotatedBounds, in: bounds.size)) }
            session.selection = previous.union(selected.map(\.id))
        case .stroke(let start, let kind):
            if kind == .pen || kind == .marker {
                if let last = stroke.last, hypot(p.x - last.x, p.y - last.y) >= 1 / viewport.zoom { stroke.append(p) }
            } else {
                var end = BoardGeometry.constrained(p, from: start, shape: kind.isShape, control: event.modifierFlags.contains(.control), shift: event.modifierFlags.contains(.shift))
                if kind == .triangle && event.modifierFlags.contains(.control) { end.y = start.y + (end.y - start.y) * sqrt(3) / 2 }
                stroke = [start, end]
            }
            let rect = strokeBounds(stroke)
            let normalized = stroke.map { CGPoint(x: ($0.x - rect.minX) / rect.width, y: ($0.y - rect.minY) / rect.height) }
            let id = preview.first?.id ?? UUID()
            preview = [BoardItem(id: id, kind: kind, frame: rect, color: session.color,
                                 points: normalized, strokeWidth: session.strokeWidth, dashed: session.dashed, translucent: session.translucent, filled: kind.isShape && session.filled)]
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let drag {
            switch drag {
            case .move, .resize, .rotate, .corner, .endpoint:
                let changes = preview
                session.store.editBoard(session.board.id) { board in
                    for item in changes {
                        if let i = board.items.firstIndex(where: { $0.id == item.id }), !board.items[i].locked {
                            board.items[i] = item
                        }
                    }
                }
            case .stroke(_, let kind):
                if preview.isEmpty, let first = stroke.first, kind == .pen || kind == .marker {
                    preview = [BoardItem(kind: kind, frame: CGRect(origin: first, size: CGSize(width: 1, height: 1)),
                                         color: session.color, points: [.zero], strokeWidth: session.strokeWidth, dashed: session.dashed, translucent: session.translucent)]
                }
                let items = preview
                session.store.editBoard(session.board.id) { $0.items.append(contentsOf: items) }
            case .pan:
                session.store.flush()
            case .marquee, .noteText: break
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
        session.finishEditing(); syncEditor()
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
        if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           let key = event.charactersIgnoringModifiers?.uppercased(), let tool = BoardTool.allCases.first(where: { $0.shortcut == key }) {
            session.chooseTool(tool); return
        }
        if command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v": session.paste(); return
            case "c": session.copy(); return
            case "a": selectAll(nil); return
            case "z": if event.modifierFlags.contains(.shift) { session.redo() } else { session.undo() }; return
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
        case 53: noteSelection = nil; clearDrag(); session.selection = []; session.tool = .select
        case 123, 124, 125, 126:
            guard noteSelection == nil else { return }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let dx: CGFloat = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
            let dy: CGFloat = event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0
            session.mutateSelected { $0.frame = $0.frame.offsetBy(dx: dx, dy: dy) }
        default: super.keyDown(with: event)
        }
    }
    override func flagsChanged(with event: NSEvent) {
        session.showsToolShortcuts = event.modifierFlags.contains(.option)
        if session.showsToolShortcuts { session.toolbarCollapsed = false }
        super.flagsChanged(with: event)
    }
    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceDown = false } else { super.keyUp(with: event) }
    }
    override func resignFirstResponder() -> Bool {
        spaceDown = false
        session.showsToolShortcuts = false
        clearDrag()
        return super.resignFirstResponder()
    }
    @objc func paste(_ sender: Any?) { session.paste() }
    @objc func copy(_ sender: Any?) { session.copy() }
    override func selectAll(_ sender: Any?) {
        if let selection = noteSelection, let text = selectableNoteText() {
            noteSelection = NoteSelection(itemID: selection.itemID, anchor: 0, end: text.length)
            needsDisplay = true
        } else {
            session.selection = Set(session.board.items.map(\.id))
        }
    }

    private func selectableNoteText() -> NSString? {
        guard let id = noteSelection?.itemID, session.tool == .select, session.editingID == nil,
              session.selection.contains(id),
              let item = session.board.items.first(where: { $0.id == id && !$0.isCollapsed }) else { return nil }
        return BoardRenderer.noteText(item.text, scale: 1, darkInk: false).string as NSString
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        session.paste(sender.draggingPasteboard, at: world(convert(sender.draggingLocation, from: nil)))
        return true
    }
}

@MainActor
private final class BoardInlineTextView: NSTextView {
    var onFinish: (() -> Void)?
    var onResign: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), event.keyCode == 53 || (event.keyCode == 36 && event.modifierFlags.contains(.command)) {
            onFinish?()
            return
        }
        super.keyDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onResign?() }
        return accepted
    }
}
