import AppKit
import CoreGraphics

enum SelectionResizeHandle: CaseIterable, Equatable, Sendable {
    case topLeft
    case top
    case topRight
    case left
    case right
    case bottomLeft
    case bottom
    case bottomRight

    var resizeCursorStyle: SelectionResizeCursorStyle {
        switch self {
        case .top, .bottom:
            .vertical
        case .left, .right:
            .horizontal
        case .topLeft, .bottomRight:
            .diagonalTopLeftBottomRight
        case .topRight, .bottomLeft:
            .diagonalTopRightBottomLeft
        }
    }

    @MainActor
    var cursor: NSCursor {
        switch resizeCursorStyle {
        case .vertical:
            .resizeUpDown
        case .horizontal:
            .resizeLeftRight
        case .diagonalTopLeftBottomRight:
            SelectionResizeCursorCache.diagonalTopLeftBottomRight
        case .diagonalTopRightBottomLeft:
            SelectionResizeCursorCache.diagonalTopRightBottomLeft
        }
    }
}

enum SelectionResizeCursorStyle: Equatable, Sendable {
    case vertical
    case horizontal
    case diagonalTopLeftBottomRight
    case diagonalTopRightBottomLeft
}

@MainActor
private enum SelectionResizeCursorCache {
    static let diagonalTopLeftBottomRight = makeCursor(
        from: CGPoint(x: 6, y: 18),
        to: CGPoint(x: 18, y: 6)
    )
    static let diagonalTopRightBottomLeft = makeCursor(
        from: CGPoint(x: 18, y: 18),
        to: CGPoint(x: 6, y: 6)
    )

    private static func makeCursor(from start: CGPoint, to end: CGPoint) -> NSCursor {
        let image = NSImage(size: NSSize(width: 24, height: 24))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 24, height: 24).fill()

        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        path.move(to: start)
        path.line(to: CGPoint(
            x: start.x + (end.x > start.x ? 5 : -5),
            y: start.y
        ))
        path.move(to: start)
        path.line(to: CGPoint(
            x: start.x,
            y: start.y + (end.y > start.y ? 5 : -5)
        ))
        path.move(to: end)
        path.line(to: CGPoint(
            x: end.x + (start.x > end.x ? 5 : -5),
            y: end.y
        ))
        path.move(to: end)
        path.line(to: CGPoint(
            x: end.x,
            y: end.y + (start.y > end.y ? 5 : -5)
        ))
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        NSColor.black.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 4
        path.stroke()
        NSColor.white.setStroke()
        path.lineWidth = 2
        path.stroke()
        image.unlockFocus()

        return NSCursor(
            image: image,
            hotSpot: NSPoint(x: 12, y: 12)
        )
    }
}

enum SelectionGeometry {
    static let handleSize: CGFloat = 9
    static let handleHitSize: CGFloat = 22

    static func handle(at point: CGPoint, in rect: CGRect, hitSize: CGFloat = handleHitSize) -> SelectionResizeHandle? {
        let edgeHitInset = hitSize / 2
        let nearVerticalEdge = point.x - rect.minX <= edgeHitInset
            || rect.maxX - point.x <= edgeHitInset
        let nearHorizontalEdge = point.y - rect.minY <= edgeHitInset
            || rect.maxY - point.y <= edgeHitInset
        guard nearVerticalEdge || nearHorizontalEdge else { return nil }

        let points = handlePoints(in: rect)
        let ordered: [(SelectionResizeHandle, CGPoint)] = [
            (.topLeft, points.topLeft),
            (.top, points.top),
            (.topRight, points.topRight),
            (.left, points.left),
            (.right, points.right),
            (.bottomLeft, points.bottomLeft),
            (.bottom, points.bottom),
            (.bottomRight, points.bottomRight),
        ]
        return ordered
            .filter { _, center in
                abs(point.x - center.x) <= hitSize / 2
                    && abs(point.y - center.y) <= hitSize / 2
            }
            .min { lhs, rhs in
                let leftDistance = hypot(point.x - lhs.1.x, point.y - lhs.1.y)
                let rightDistance = hypot(point.x - rhs.1.x, point.y - rhs.1.y)
                return leftDistance < rightDistance
            }?.0
    }

    static func resized(
        _ rect: CGRect,
        handle: SelectionResizeHandle,
        by delta: CGPoint,
        constrainedTo bounds: CGRect,
        minimumSize: CGSize
    ) -> CGRect {
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        switch handle {
        case .topLeft:
            minX += delta.x
            minY += delta.y
        case .top:
            minY += delta.y
        case .topRight:
            maxX += delta.x
            minY += delta.y
        case .left:
            minX += delta.x
        case .right:
            maxX += delta.x
        case .bottomLeft:
            minX += delta.x
            maxY += delta.y
        case .bottom:
            maxY += delta.y
        case .bottomRight:
            maxX += delta.x
            maxY += delta.y
        }

        minX = max(minX, bounds.minX)
        minY = max(minY, bounds.minY)
        maxX = min(maxX, bounds.maxX)
        maxY = min(maxY, bounds.maxY)

        if maxX - minX < minimumSize.width {
            switch handle {
            case .topLeft, .left, .bottomLeft:
                minX = maxX - minimumSize.width
            case .topRight, .right, .bottomRight:
                maxX = minX + minimumSize.width
            case .top, .bottom:
                break
            }
        }
        if maxY - minY < minimumSize.height {
            switch handle {
            case .topLeft, .top, .topRight:
                minY = maxY - minimumSize.height
            case .bottomLeft, .bottom, .bottomRight:
                maxY = minY + minimumSize.height
            case .left, .right:
                break
            }
        }

        let clampedMinX = min(max(minX, bounds.minX), bounds.maxX - minimumSize.width)
        let clampedMinY = min(max(minY, bounds.minY), bounds.maxY - minimumSize.height)
        let clampedMaxX = max(min(maxX, bounds.maxX), bounds.minX + minimumSize.width)
        let clampedMaxY = max(min(maxY, bounds.maxY), bounds.minY + minimumSize.height)
        return CGRect(
            x: clampedMinX,
            y: clampedMinY,
            width: clampedMaxX - clampedMinX,
            height: clampedMaxY - clampedMinY
        )
    }

    static func moved(
        _ rect: CGRect,
        by delta: CGPoint,
        constrainedTo bounds: CGRect
    ) -> CGRect {
        let x = min(max(rect.minX + delta.x, bounds.minX), bounds.maxX - rect.width)
        let y = min(max(rect.minY + delta.y, bounds.minY), bounds.maxY - rect.height)
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    static func normalizedSelection(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    static func handlePoints(in rect: CGRect) -> SelectionHandlePoints {
        return SelectionHandlePoints(
            topLeft: CGPoint(x: rect.minX, y: rect.minY),
            top: CGPoint(x: rect.midX, y: rect.minY),
            topRight: CGPoint(x: rect.maxX, y: rect.minY),
            left: CGPoint(x: rect.minX, y: rect.midY),
            right: CGPoint(x: rect.maxX, y: rect.midY),
            bottomLeft: CGPoint(x: rect.minX, y: rect.maxY),
            bottom: CGPoint(x: rect.midX, y: rect.maxY),
            bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        )
    }
}

enum AnnotationSelectionGeometry {
    static func handle(
        at point: CGPoint,
        in rect: CGRect,
        hitSize: CGFloat = SelectionGeometry.handleHitSize,
        proportional: Bool = false
    ) -> SelectionResizeHandle? {
        let points = SelectionGeometry.handlePoints(in: rect)
        let cornerHandles: [(SelectionResizeHandle, CGPoint)] = [
            (SelectionResizeHandle.topLeft, points.topLeft),
            (.topRight, points.topRight),
            (.bottomLeft, points.bottomLeft),
            (.bottomRight, points.bottomRight),
        ]
        let handles = proportional ? cornerHandles : cornerHandles + [
            (.top, points.top),
            (.left, points.left),
            (.right, points.right),
            (.bottom, points.bottom),
        ]
        return handles
        .filter { _, center in
            abs(point.x - center.x) <= hitSize / 2
                && abs(point.y - center.y) <= hitSize / 2
        }
        .min { lhs, rhs in
            hypot(point.x - lhs.1.x, point.y - lhs.1.y)
                < hypot(point.x - rhs.1.x, point.y - rhs.1.y)
        }?.0
    }

    static func resized(
        _ rect: CGRect,
        handle: SelectionResizeHandle,
        by delta: CGPoint,
        constrainedTo bounds: CGRect,
        minimumSize: CGSize,
        proportional: Bool = false
    ) -> CGRect {
        let free = SelectionGeometry.resized(
            rect,
            handle: handle,
            by: delta,
            constrainedTo: bounds,
            minimumSize: minimumSize
        )
        guard proportional else { return free }
        guard rect.width > 0, rect.height > 0 else { return free }
        let aspectRatio = rect.width / rect.height
        let widthChange = abs(free.width - rect.width) / rect.width
        let heightChange = abs(free.height - rect.height) / rect.height
        var size = widthChange >= heightChange
            ? CGSize(width: free.width, height: free.width / aspectRatio)
            : CGSize(width: free.height * aspectRatio, height: free.height)
        let minimumWidth = max(minimumSize.width, minimumSize.height * aspectRatio)
        let minimumHeight = max(minimumSize.height, minimumSize.width / aspectRatio)
        size.width = max(size.width, minimumWidth)
        size.height = max(size.height, minimumHeight)

        let rightAnchored = handle == .topLeft || handle == .bottomLeft
        let bottomAnchored = handle == .topLeft || handle == .topRight
        var origin = CGPoint(
            x: rightAnchored ? rect.maxX - size.width : rect.minX,
            y: bottomAnchored ? rect.maxY - size.height : rect.minY
        )
        if origin.x < bounds.minX {
            origin.x = bounds.minX
            size.width = min(size.width, rightAnchored ? rect.maxX - bounds.minX : bounds.maxX - origin.x)
            size.height = size.width / aspectRatio
        }
        if origin.y < bounds.minY {
            origin.y = bounds.minY
            size.height = min(size.height, bottomAnchored ? rect.maxY - bounds.minY : bounds.maxY - origin.y)
            size.width = size.height * aspectRatio
        }
        if origin.x + size.width > bounds.maxX {
            size.width = bounds.maxX - origin.x
            size.height = size.width / aspectRatio
        }
        if origin.y + size.height > bounds.maxY {
            size.height = bounds.maxY - origin.y
            size.width = size.height * aspectRatio
        }
        return CGRect(origin: origin, size: size)
    }
}

enum SelectionCornerRadiusGeometry {
    // Leave the centered resize handles reachable at zero radius.
    static let minimumInset: CGFloat = 20
    static let hitSize: CGFloat = 24

    static func handleCenter(in selection: CGRect, radius: Int) -> CGPoint {
        let inset = min(
            max(minimumInset, CGFloat(radius)),
            min(selection.width, selection.height) / 2
        )
        return CGPoint(x: selection.maxX - inset, y: selection.maxY - inset)
    }

    static func hitTest(_ point: CGPoint, selection: CGRect, radius: Int) -> Bool {
        let center = handleCenter(in: selection, radius: radius)
        return abs(point.x - center.x) <= hitSize / 2
            && abs(point.y - center.y) <= hitSize / 2
    }

    static func radius(startRadius: Int, dragDelta: CGPoint) -> Int {
        let proposed = CGFloat(startRadius) - (dragDelta.x + dragDelta.y) / 2
        return min(
            max(Int(proposed.rounded()), 0),
            ScreenshotOutputAppearance.maximumCornerRadius
        )
    }
}

struct SelectionHandlePoints: Equatable, Sendable {
    let topLeft: CGPoint
    let top: CGPoint
    let topRight: CGPoint
    let left: CGPoint
    let right: CGPoint
    let bottomLeft: CGPoint
    let bottom: CGPoint
    let bottomRight: CGPoint
}

struct ScreenshotToolbarLayout: Equatable, Sendable {
    let editingFrame: CGRect
    let outputFrame: CGRect

    static func layout(
        selection: CGRect,
        bounds: CGRect,
        editingSize: CGSize,
        outputSize: CGSize,
        forceInside: Bool = false
    ) -> ScreenshotToolbarLayout {
        let margin: CGFloat = 12
        let gap: CGFloat = 10
        let safeBounds = bounds.insetBy(dx: margin, dy: margin)
        let editingX = clampedCenter(
            selection.maxX - editingSize.width / 2,
            length: editingSize.width,
            lower: safeBounds.minX,
            upper: safeBounds.maxX
        )
        let editingCandidates = forceInside ? [] : [
            selection.maxY + gap,
            selection.minY - gap - editingSize.height,
        ]
        let editingY = editingCandidates.first(where: {
            $0 >= safeBounds.minY && $0 + editingSize.height <= safeBounds.maxY
        }) ?? min(
            max(selection.maxY - gap - editingSize.height, safeBounds.minY),
            max(safeBounds.minY, safeBounds.maxY - editingSize.height)
        )
        let editingFrame = CGRect(
            x: editingX,
            y: editingY,
            width: editingSize.width,
            height: editingSize.height
        )

        let outputCandidates = forceInside ? [] : [
            selection.maxX + gap,
            selection.minX - gap - outputSize.width,
        ]
        let outputFrame = outputCandidates.lazy.map {
            CGRect(
                x: $0,
                y: selection.maxY - outputSize.height,
                width: outputSize.width,
                height: outputSize.height
            )
        }.map { frame in
            CGRect(
                x: frame.minX,
                y: min(
                    max(frame.minY, safeBounds.minY),
                    max(safeBounds.minY, safeBounds.maxY - frame.height)
                ),
                width: frame.width,
                height: frame.height
            )
        }.first {
            safeBounds.contains($0) && !$0.intersects(editingFrame)
        } ?? fallbackOutputFrame(
            selection: selection,
            safeBounds: safeBounds,
            outputSize: outputSize,
            editingFrame: editingFrame,
            gap: gap
        )
        return ScreenshotToolbarLayout(
            editingFrame: editingFrame,
            outputFrame: outputFrame
        )
    }

    private static func fallbackOutputFrame(
        selection: CGRect,
        safeBounds: CGRect,
        outputSize: CGSize,
        editingFrame: CGRect,
        gap: CGFloat
    ) -> CGRect {
        let candidates = [
            CGRect(
                x: selection.maxX - gap - outputSize.width,
                y: selection.maxY - gap - outputSize.height,
                width: outputSize.width,
                height: outputSize.height
            ),
            CGRect(
                x: safeBounds.maxX - outputSize.width,
                y: editingFrame.minY - gap - outputSize.height,
                width: outputSize.width,
                height: outputSize.height
            ),
            CGRect(
                x: safeBounds.maxX - outputSize.width,
                y: editingFrame.maxY + gap,
                width: outputSize.width,
                height: outputSize.height
            ),
            CGRect(
                x: safeBounds.maxX - outputSize.width,
                y: safeBounds.maxY - outputSize.height,
                width: outputSize.width,
                height: outputSize.height
            ),
        ]
        return candidates.map { frame in
            CGRect(
                x: min(max(frame.minX, safeBounds.minX), safeBounds.maxX - frame.width),
                y: min(max(frame.minY, safeBounds.minY), safeBounds.maxY - frame.height),
                width: frame.width,
                height: frame.height
            )
        }.first { safeBounds.contains($0) && !$0.intersects(editingFrame) }
            ?? candidates[3]
    }

    private static func clampedCenter(
        _ center: CGFloat,
        length: CGFloat,
        lower: CGFloat,
        upper: CGFloat
    ) -> CGFloat {
        min(max(center - length / 2, lower), max(lower, upper - length))
    }
}

enum SelectionToolbarPlacement {
    static func origin(
        toolbarSize: CGSize,
        selection: CGRect?,
        in bounds: CGRect,
        margin: CGFloat = 12
    ) -> CGPoint {
        let safeBounds = bounds.insetBy(dx: margin, dy: margin)
        guard let selection, !selection.isEmpty else {
            return CGPoint(
                x: safeBounds.midX - toolbarSize.width / 2,
                y: safeBounds.maxY - toolbarSize.height
            )
        }

        let below = CGPoint(x: selection.midX - toolbarSize.width / 2, y: selection.maxY + margin)
        let above = CGPoint(x: selection.midX - toolbarSize.width / 2, y: selection.minY - toolbarSize.height - margin)
        let preferred = below.y + toolbarSize.height <= safeBounds.maxY ? below : above
        let fallback = CGPoint(
            x: selection.midX - toolbarSize.width / 2,
            y: safeBounds.maxY - toolbarSize.height
        )
        let candidate = preferred.y >= safeBounds.minY ? preferred : fallback
        return CGPoint(
            x: min(max(candidate.x, safeBounds.minX), safeBounds.maxX - toolbarSize.width),
            y: min(max(candidate.y, safeBounds.minY), safeBounds.maxY - toolbarSize.height)
        )
    }
}
