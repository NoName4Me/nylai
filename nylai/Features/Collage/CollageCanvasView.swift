import AppKit

@MainActor
final class CollageCanvasView: NSView {
    var document: CollageDocument? {
        didSet { reloadDocument() }
    }
    var onDocumentChanged: (() -> Void)?

    private enum DragMode {
        case moving(UUID, start: CGPoint, origin: CGPoint)
        case resizing(UUID, handle: SelectionResizeHandle, start: CGPoint, frame: CGRect)
    }

    private var dragMode: DragMode?
    private let minimumItemSize: CGFloat = 36

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从归档创建拼图画布")
    }

    func reloadDocument() {
        guard let document else { return }
        setFrameSize(document.workspaceSize)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawWorkspace()
        guard let document else { return }
        for item in document.items {
            drawItem(item)
        }
        if let selected = document.selectedItem {
            drawSelection(around: selected.frame)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let document else { return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let selected = document.selectedItem,
           let handle = SelectionGeometry.handle(
               at: point,
               in: selected.frame,
               hitSize: 18
           ) {
            document.beginInteraction()
            dragMode = .resizing(
                selected.id,
                handle: handle,
                start: point,
                frame: selected.frame
            )
            return
        }
        if let item = document.items.reversed().first(where: { $0.frame.contains(point) }) {
            if event.clickCount >= 2 {
                document.select(item.id)
                document.bringForward()
                notifyChanged()
                return
            }
            document.select(item.id)
            document.beginInteraction()
            dragMode = .moving(item.id, start: point, origin: item.frame.origin)
            needsDisplay = true
            notifyChanged()
            return
        }
        document.select(nil)
        dragMode = nil
        needsDisplay = true
        notifyChanged()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let document, let dragMode else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch dragMode {
        case .moving(let id, let start, let origin):
            let frame = CGRect(
                x: origin.x + point.x - start.x,
                y: origin.y + point.y - start.y,
                width: document.items.first(where: { $0.id == id })?.frame.width ?? 1,
                height: document.items.first(where: { $0.id == id })?.frame.height ?? 1
            )
            document.updateFrame(frame, for: id)
        case .resizing(let id, let handle, let start, let frame):
            document.updateFrame(
                resizedFrame(
                    frame,
                    handle: handle,
                    delta: CGPoint(x: point.x - start.x, y: point.y - start.y)
                ),
                for: id
            )
        }
        reloadDocument()
        notifyChanged()
    }

    override func mouseUp(with event: NSEvent) {
        guard let document, dragMode != nil else { return }
        dragMode = nil
        document.endInteraction()
        reloadDocument()
        notifyChanged()
    }

    override func keyDown(with event: NSEvent) {
        guard let document else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            document.deleteSelected()
            reloadDocument()
            notifyChanged()
            return
        }
        if event.keyCode == 6, event.modifierFlags.contains(.command) {
            if event.modifierFlags.contains(.shift) {
                document.redo()
            } else {
                document.undo()
            }
            reloadDocument()
            notifyChanged()
            return
        }
        if let selected = document.selectedItem,
           let delta = arrowDelta(for: event) {
            document.beginInteraction()
            document.updateFrame(
                selected.frame.offsetBy(dx: delta.x, dy: delta.y),
                for: selected.id
            )
            document.endInteraction()
            reloadDocument()
            notifyChanged()
            return
        }
        super.keyDown(with: event)
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        if dragMode != nil {
            cursor = .closedHand
        } else if NSEvent.pressedMouseButtons != 0 {
            cursor = .closedHand
        } else {
            cursor = .openHand
        }
        addCursorRect(bounds, cursor: cursor)
    }

    private func drawWorkspace() {
        NSColor(calibratedRed: 0.94, green: 0.93, blue: 0.9, alpha: 1).setFill()
        bounds.fill()

        let gridSize: CGFloat = 24
        let grid = NSBezierPath()
        var x: CGFloat = 0
        while x <= bounds.maxX {
            grid.move(to: CGPoint(x: x, y: 0))
            grid.line(to: CGPoint(x: x, y: bounds.maxY))
            x += gridSize
        }
        var y: CGFloat = 0
        while y <= bounds.maxY {
            grid.move(to: CGPoint(x: 0, y: y))
            grid.line(to: CGPoint(x: bounds.maxX, y: y))
            y += gridSize
        }
        NSColor.black.withAlphaComponent(0.035).setStroke()
        grid.lineWidth = 0.5
        grid.stroke()
    }

    private func drawItem(_ item: CollageItem) {
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = CGSize(width: 0, height: 3)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSImage(cgImage: item.image, size: item.frame.size)
            .draw(
                in: item.frame,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawSelection(around frame: CGRect) {
        NylaiTheme.accent.withAlphaComponent(0.95).setStroke()
        let border = NSBezierPath(rect: frame)
        border.lineWidth = 2
        border.stroke()

        let points = SelectionGeometry.handlePoints(in: frame)
        for point in [
            points.topLeft, points.top, points.topRight,
            points.left, points.right,
            points.bottomLeft, points.bottom, points.bottomRight,
        ] {
            let handle = CGRect(
                x: point.x - 4.5,
                y: point.y - 4.5,
                width: 9,
                height: 9
            )
            NSColor.white.setFill()
            NSBezierPath(roundedRect: handle, xRadius: 2, yRadius: 2).fill()
            NylaiTheme.accent.setStroke()
            let outline = NSBezierPath(roundedRect: handle, xRadius: 2, yRadius: 2)
            outline.lineWidth = 1.25
            outline.stroke()
        }
    }

    private func resizedFrame(
        _ frame: CGRect,
        handle: SelectionResizeHandle,
        delta: CGPoint
    ) -> CGRect {
        let aspect = frame.width / max(frame.height, 1)
        let horizontalSign: CGFloat
        let verticalSign: CGFloat
        switch handle {
        case .topLeft:
            horizontalSign = -1
            verticalSign = -1
        case .top:
            horizontalSign = 0
            verticalSign = -1
        case .topRight:
            horizontalSign = 1
            verticalSign = -1
        case .left:
            horizontalSign = -1
            verticalSign = 0
        case .right:
            horizontalSign = 1
            verticalSign = 0
        case .bottomLeft:
            horizontalSign = -1
            verticalSign = 1
        case .bottom:
            horizontalSign = 0
            verticalSign = 1
        case .bottomRight:
            horizontalSign = 1
            verticalSign = 1
        }

        let widthFromHorizontal = frame.width + horizontalSign * delta.x
        let widthFromVertical = (frame.height + verticalSign * delta.y) * aspect
        let candidateWidth: CGFloat
        if horizontalSign == 0 {
            candidateWidth = widthFromVertical
        } else if verticalSign == 0 || abs(delta.x) >= abs(delta.y * aspect) {
            candidateWidth = widthFromHorizontal
        } else {
            candidateWidth = widthFromVertical
        }
        let width = max(minimumItemSize, candidateWidth)
        let height = max(minimumItemSize / aspect, width / aspect)
        let resolvedWidth = height * aspect

        var origin = frame.origin
        if horizontalSign < 0 {
            origin.x = frame.maxX - resolvedWidth
        } else if horizontalSign == 0 {
            origin.x = frame.midX - resolvedWidth / 2
        }
        if verticalSign < 0 {
            origin.y = frame.maxY - height
        } else if verticalSign == 0 {
            origin.y = frame.midY - height / 2
        }
        return CGRect(origin: origin, size: CGSize(width: resolvedWidth, height: height))
    }

    private func arrowDelta(for event: NSEvent) -> CGPoint? {
        let distance: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123:
            return CGPoint(x: -distance, y: 0)
        case 124:
            return CGPoint(x: distance, y: 0)
        case 125:
            return CGPoint(x: 0, y: distance)
        case 126:
            return CGPoint(x: 0, y: -distance)
        default:
            return nil
        }
    }

    private func notifyChanged() {
        onDocumentChanged?()
        needsDisplay = true
    }
}
