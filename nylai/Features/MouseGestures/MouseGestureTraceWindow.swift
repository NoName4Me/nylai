import AppKit

@MainActor
final class MouseGestureTraceWindow: NSWindow {
    private let traceView = MouseGestureTraceView(frame: .zero)

    init() {
        let frame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        contentView = traceView
    }

    func update(points: [CGPoint], destination: CGPoint?, isCancelled: Bool) {
        traceView.update(
            points: points,
            destination: destination,
            isCancelled: isCancelled
        )
        if !isVisible {
            orderFrontRegardless()
        }
    }

    func clear() {
        orderOut(nil)
        traceView.update(points: [], destination: nil, isCancelled: false)
    }
}

@MainActor
private final class MouseGestureTraceView: NSView {
    private var points: [CGPoint] = []
    private var destination: CGPoint?
    private var isCancelled = false

    override var isFlipped: Bool { false }

    func update(points: [CGPoint], destination: CGPoint?, isCancelled: Bool) {
        self.points = points
        self.destination = destination
        self.isCancelled = isCancelled
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard points.count > 1 else { return }
        let converted = points.map(localPoint(fromScreen:))
        let path = NSBezierPath()
        path.move(to: converted[0])
        for point in converted.dropFirst() {
            path.line(to: point)
        }
        NSColor.black.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 7
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()

        (isCancelled ? NSColor.systemRed : NylaiTheme.accent).setStroke()
        path.lineWidth = 4
        path.stroke()

        guard let destination, converted.count > 1 else { return }
        let end = localPoint(fromScreen: destination)
        let previous = converted[max(0, converted.count - 6)]
        let angle = atan2(end.y - previous.y, end.x - previous.x)
        let headLength: CGFloat = 13
        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: CGPoint(
            x: end.x - headLength * cos(angle - .pi / 6),
            y: end.y - headLength * sin(angle - .pi / 6)
        ))
        head.move(to: end)
        head.line(to: CGPoint(
            x: end.x - headLength * cos(angle + .pi / 6),
            y: end.y - headLength * sin(angle + .pi / 6)
        ))
        head.lineWidth = 4
        head.lineCapStyle = .round
        head.stroke()
    }

    private func localPoint(fromScreen point: CGPoint) -> CGPoint {
        guard let window else { return convert(point, from: nil) }
        return convert(window.convertPoint(fromScreen: point), from: nil)
    }
}
