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

    @MainActor
    var cursor: NSCursor {
        switch self {
        case .topLeft, .bottomRight:
            SelectionResizeCursor.downwardDiagonal
        case .topRight, .bottomLeft:
            SelectionResizeCursor.upwardDiagonal
        case .top, .bottom:
            .resizeUpDown
        case .left, .right:
            .resizeLeftRight
        }
    }
}

@MainActor
private enum SelectionResizeCursor {
    static let downwardDiagonal = makeDiagonalCursor(degrees: -45)
    static let upwardDiagonal = makeDiagonalCursor(degrees: 45)

    private static func makeDiagonalCursor(degrees: CGFloat) -> NSCursor {
        let canvasSize = NSSize(width: 30, height: 30)
        let image = NSImage(size: canvasSize, flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(
                by: canvasSize.width / 2,
                yBy: canvasSize.height / 2
            )
            transform.rotate(byDegrees: degrees)
            transform.translateX(by: -canvasSize.width / 2, yBy: -canvasSize.height / 2)
            transform.concat()

            let arrow = doubleArrowPath(in: canvasSize)
            arrow.lineJoinStyle = .miter
            arrow.miterLimit = 4
            NSColor.white.setStroke()
            arrow.lineWidth = 2.6
            arrow.stroke()
            NSColor.black.setFill()
            arrow.fill()
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        return NSCursor(
            image: image,
            hotSpot: NSPoint(
                x: canvasSize.width / 2,
                y: canvasSize.height / 2
            )
        )
    }

    private static func doubleArrowPath(in canvasSize: NSSize) -> NSBezierPath {
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let axisHalfLength: CGFloat = 9.5
        let headLength: CGFloat = 6.2
        let headHalfWidth: CGFloat = 3.6
        let shaftHalfWidth: CGFloat = 1.35
        let tipLeft = CGPoint(x: center.x - axisHalfLength, y: center.y)
        let tipRight = CGPoint(x: center.x + axisHalfLength, y: center.y)
        let leftBase = tipLeft.x + headLength
        let rightBase = tipRight.x - headLength

        let path = NSBezierPath()
        path.move(to: tipLeft)
        path.line(to: CGPoint(x: leftBase, y: center.y - headHalfWidth))
        path.line(to: CGPoint(x: leftBase, y: center.y - shaftHalfWidth))
        path.line(to: CGPoint(x: rightBase, y: center.y - shaftHalfWidth))
        path.line(to: CGPoint(x: rightBase, y: center.y - headHalfWidth))
        path.line(to: tipRight)
        path.line(to: CGPoint(x: rightBase, y: center.y + headHalfWidth))
        path.line(to: CGPoint(x: rightBase, y: center.y + shaftHalfWidth))
        path.line(to: CGPoint(x: leftBase, y: center.y + shaftHalfWidth))
        path.line(to: CGPoint(x: leftBase, y: center.y + headHalfWidth))
        path.close()
        return path
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

    static func rotatedHandlePoints(
        in rect: CGRect,
        degrees: Double
    ) -> SelectionHandlePoints {
        let points = handlePoints(in: rect)
        guard abs(degrees) > 0.001 else { return points }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        func rotated(_ point: CGPoint) -> CGPoint {
            let radians = CGFloat(degrees) * .pi / 180
            let dx = point.x - center.x
            let dy = point.y - center.y
            return CGPoint(
                x: center.x + dx * cos(radians) - dy * sin(radians),
                y: center.y + dx * sin(radians) + dy * cos(radians)
            )
        }
        return SelectionHandlePoints(
            topLeft: rotated(points.topLeft),
            top: rotated(points.top),
            topRight: rotated(points.topRight),
            left: rotated(points.left),
            right: rotated(points.right),
            bottomLeft: rotated(points.bottomLeft),
            bottom: rotated(points.bottom),
            bottomRight: rotated(points.bottomRight)
        )
    }
}

enum AnnotationSelectionGeometry {
    static func handle(
        at point: CGPoint,
        in rect: CGRect,
        hitSize: CGFloat = SelectionGeometry.handleHitSize,
        proportional: Bool = false,
        rotationDegrees: Double = 0
    ) -> SelectionResizeHandle? {
        let points = SelectionGeometry.rotatedHandlePoints(
            in: rect,
            degrees: rotationDegrees
        )
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
        forceInside: Bool = false,
        cornerRadius: Int? = 0
    ) -> ScreenshotToolbarLayout {
        let gap: CGFloat = 10
        let safe = bounds.insetBy(dx: 12, dy: 12)
        let inside = safe.intersection(selection)
        let handle = cornerRadius.map { radius in
            let center = SelectionCornerRadiusGeometry.handleCenter(in: selection, radius: radius)
            let size = SelectionCornerRadiusGeometry.hitSize
            return CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        } ?? .null

        func frame(_ size: CGSize, x: CGFloat, y: CGFloat, in region: CGRect) -> CGRect {
            CGRect(
                x: min(max(x, region.minX), max(region.minX, region.maxX - size.width)),
                y: min(max(y, region.minY), max(region.minY, region.maxY - size.height)),
                width: size.width, height: size.height
            )
        }

        let bottomY = selection.maxY - gap - editingSize.height
        let rightX = selection.maxX - gap - outputSize.width
        var editing: [CGRect] = []
        var output: [CGRect] = []
        if !forceInside, selection.maxY + gap + editingSize.height <= safe.maxY {
            editing.append(frame(editingSize, x: selection.maxX - editingSize.width,
                                 y: selection.maxY + gap, in: safe))
        }
        if !forceInside, selection.maxX + gap + outputSize.width <= safe.maxX {
            output.append(frame(outputSize, x: selection.maxX + gap,
                                y: selection.maxY - outputSize.height, in: safe))
        }

        for region in [inside, safe] where !region.isNull {
            editing += [
                frame(editingSize, x: selection.maxX - gap - editingSize.width, y: bottomY, in: region),
                frame(editingSize, x: handle.isNull ? rightX : handle.minX - gap - editingSize.width,
                      y: bottomY, in: region),
                frame(editingSize, x: selection.maxX - gap - editingSize.width,
                      y: handle.isNull ? bottomY : handle.minY - gap - editingSize.height, in: region),
                frame(editingSize, x: rightX - gap - editingSize.width, y: bottomY, in: region),
            ].filter { region.contains($0) }
            output += [
                frame(outputSize, x: rightX, y: selection.maxY - gap - outputSize.height, in: region),
                frame(outputSize, x: rightX,
                      y: handle.isNull ? selection.minY : handle.minY - gap - outputSize.height, in: region),
                frame(outputSize, x: handle.isNull ? rightX : handle.minX - gap - outputSize.width,
                      y: selection.maxY - gap - outputSize.height, in: region),
                frame(outputSize, x: rightX, y: region.minY, in: region),
            ].filter { region.contains($0) }
        }
        // Try the preferred side or an in-selection placement before using screen space.
        let preferredEditing = editing.filter {
            inside.contains($0) || $0.minY >= selection.maxY + gap
        }
        let preferredOutput = output.filter {
            inside.contains($0) || $0.minX >= selection.maxX + gap
        }
        for edit in preferredEditing where !edit.intersects(handle) {
            if let out = preferredOutput.first(where: { !$0.intersects(edit) && !$0.intersects(handle) }) {
                return .init(editingFrame: edit, outputFrame: out)
            }
        }

        // Small selections may need to borrow space from the surrounding screen.
        for edit in editing where !edit.intersects(handle) {
            let above = frame(outputSize, x: rightX, y: edit.minY - gap - outputSize.height, in: safe)
            let below = frame(outputSize, x: rightX, y: edit.maxY + gap, in: safe)
            if let out = (output + [above, below]).first(where: {
                !$0.intersects(edit) && !$0.intersects(handle)
            }) {
                return .init(editingFrame: edit, outputFrame: out)
            }
        }
        return .init(
            editingFrame: editing.first ?? frame(editingSize, x: safe.minX, y: bottomY, in: safe),
            outputFrame: output.first ?? frame(outputSize, x: rightX, y: safe.minY, in: safe)
        )
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
