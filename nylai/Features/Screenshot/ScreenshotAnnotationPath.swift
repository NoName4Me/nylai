import AppKit
import CoreGraphics

struct ScreenshotArrowAnchors: Equatable {
    static let defaultCurve: CGFloat = 0.16

    var first = CGPoint(x: 1.0 / 3, y: 0)
    var second = CGPoint(x: 2.0 / 3, y: 0)

    static func resolved(for annotation: ScreenshotAnnotation) -> Self {
        guard annotation.style.arrowOptions?.pathStyle == .curved else { return Self() }
        if let anchors = annotation.arrowAnchors { return anchors }
        return Self(
            first: CGPoint(x: 1.0 / 3, y: defaultCurve),
            second: CGPoint(x: 2.0 / 3, y: defaultCurve)
        )
    }

    static func position(_ anchor: CGPoint, start: CGPoint, end: CGPoint, flipped: Bool = true) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let side = anchor.y * (flipped ? 1 : -1)
        return CGPoint(
            x: start.x + dx * anchor.x - dy * side,
            y: start.y + dy * anchor.x + dx * side
        )
    }

    static func relative(_ point: CGPoint, start: CGPoint, end: CGPoint) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = max(1, dx * dx + dy * dy)
        let px = point.x - start.x
        let py = point.y - start.y
        return CGPoint(
            x: (px * dx + py * dy) / lengthSquared,
            y: (py * dx - px * dy) / lengthSquared
        )
    }
}

enum ScreenshotAnnotationDirectionConstraint {
    static func constrained(
        from start: PixelPoint,
        to end: PixelPoint,
        modifiers: NSEvent.ModifierFlags
    ) -> PixelPoint {
        let control = modifiers.contains(.control)
        let shift = modifiers.contains(.shift)
        guard control || shift else { return end }
        let dx = end.x - start.x
        let dy = end.y - start.y
        if control && shift {
            let distance = max(abs(dx), abs(dy))
            return PixelPoint(
                x: start.x + (dx < 0 ? -distance : distance),
                y: start.y + (dy < 0 ? -distance : distance)
            )
        }
        if shift {
            return abs(dx) >= abs(dy)
                ? PixelPoint(x: end.x, y: start.y)
                : PixelPoint(x: start.x, y: end.y)
        }
        return abs(dx) >= abs(dy)
            ? PixelPoint(x: start.x, y: end.y)
            : PixelPoint(x: end.x, y: start.y)
    }
}

enum ScreenshotAnnotationPath {
    static func cgPath(
        for annotation: ScreenshotAnnotation,
        in boundingRect: CGRect,
        flipped: Bool = true,
        strokeScale: CGFloat = 1
    ) -> CGPath {
        let path = CGMutablePath()
        switch annotation.kind {
        case .rectangle:
            if annotation.style.resolvedCornerStyle == .sharp {
                path.addRect(boundingRect)
            } else {
                let radius = rectangleCornerRadius(
                    for: annotation,
                    in: boundingRect,
                    strokeScale: strokeScale
                )
                path.addPath(CGPath(
                    roundedRect: boundingRect,
                    cornerWidth: radius,
                    cornerHeight: radius,
                    transform: nil
                ))
            }
        case .ellipse:
            path.addEllipse(in: boundingRect)
        case .line:
            if annotation.points.count >= 2 {
                appendPolyline(
                    annotation.points,
                    to: path,
                    annotation: annotation,
                    in: boundingRect
                )
            } else {
                path.move(to: endpoint(annotation.start, annotation: annotation, in: boundingRect))
                path.addLine(to: endpoint(annotation.end, annotation: annotation, in: boundingRect))
            }
        case .arrow:
            path.addPath(arrowGeometry(
                for: annotation,
                in: boundingRect,
                options: resolvedOptions(for: annotation),
                flipped: flipped,
                strokeScale: strokeScale
            ).outline)
        case .brush, .marker, .mosaicStroke, .mosaicBlur:
            appendPolyline(
                annotation.points,
                to: path,
                annotation: annotation,
                in: boundingRect
            )
        case .text:
            break
        case .step:
            path.addEllipse(in: boundingRect)
        case .mosaic, .blur:
            path.addRect(boundingRect)
        }
        guard annotation.kind.supportsRotation,
              abs(annotation.rotationDegrees) > 0.001 else {
            return path
        }
        let center = CGPoint(x: boundingRect.midX, y: boundingRect.midY)
        let radians = CGFloat(annotation.rotationDegrees) * .pi / 180 * (flipped ? 1 : -1)
        let transform = CGAffineTransform(
            translationX: center.x,
            y: center.y
        ).rotated(by: radians).translatedBy(x: -center.x, y: -center.y)
        let rotated = CGMutablePath()
        rotated.addPath(path, transform: transform)
        return rotated
    }

    private static func appendPolyline(
        _ points: [PixelPoint],
        to path: CGMutablePath,
        annotation: ScreenshotAnnotation,
        in boundingRect: CGRect
    ) {
        let mapped = points.map {
            endpoint($0, annotation: annotation, in: boundingRect)
        }
        guard let first = mapped.first else { return }
        path.move(to: first)
        for point in mapped.dropFirst() {
            path.addLine(to: point)
        }
        if mapped.count == 1 {
            path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y))
        }
    }

    private static func rectangleCornerRadius(
        for annotation: ScreenshotAnnotation,
        in rect: CGRect,
        strokeScale: CGFloat
    ) -> CGFloat {
        let proportional = min(rect.width, rect.height) * 0.06
        let strokeBased = CGFloat(annotation.style.lineWidth) * strokeScale * 1.2
        return min(
            min(proportional, rect.width / 2, rect.height / 2),
            max(strokeBased, 6 * strokeScale)
        )
    }

    static func fillPath(
        for annotation: ScreenshotAnnotation,
        in rect: CGRect,
        flipped: Bool = true,
        strokeScale: CGFloat = 1
    ) -> CGPath? {
        if annotation.kind == .arrow {
            let options = resolvedOptions(for: annotation)
            guard options.isTapered else { return nil }
            return arrowGeometry(
                for: annotation,
                in: rect,
                options: options,
                flipped: flipped,
                strokeScale: strokeScale
            ).fill
        }
        guard annotation.kind.supportsFill, annotation.style.fillsShape == true else {
            return nil
        }
        return cgPath(for: annotation, in: rect, flipped: flipped, strokeScale: strokeScale)
    }

    private static func resolvedOptions(
        for annotation: ScreenshotAnnotation
    ) -> ScreenshotArrowOptions {
        annotation.style.arrowOptions ?? .default
    }

    static func arrowHandles(
        for annotation: ScreenshotAnnotation,
        in rect: CGRect
    ) -> [CGPoint] {
        let start = endpoint(annotation.start, annotation: annotation, in: rect)
        let end = endpoint(annotation.end, annotation: annotation, in: rect)
        guard annotation.style.arrowOptions?.pathStyle == .curved else {
            return [start, end]
        }
        let anchors = ScreenshotArrowAnchors.resolved(for: annotation)
        return [
            start,
            ScreenshotArrowAnchors.position(anchors.first, start: start, end: end),
            ScreenshotArrowAnchors.position(anchors.second, start: start, end: end),
            end,
        ]
    }

    static func polylineHandles(
        for annotation: ScreenshotAnnotation,
        in rect: CGRect
    ) -> [CGPoint] {
        let points = annotation.points.isEmpty
            ? [annotation.start, annotation.end]
            : annotation.points
        return points.map { endpoint($0, annotation: annotation, in: rect) }
    }

    private static func arrowGeometry(
        for annotation: ScreenshotAnnotation,
        in rect: CGRect,
        options: ScreenshotArrowOptions,
        flipped: Bool,
        strokeScale: CGFloat
    ) -> (outline: CGPath, fill: CGPath?) {
        let start = endpoint(annotation.start, annotation: annotation, in: rect)
        let tip = endpoint(annotation.end, annotation: annotation, in: rect)
        let delta = CGPoint(x: tip.x - start.x, y: tip.y - start.y)
        let distance = hypot(delta.x, delta.y)
        let outline = CGMutablePath()
        let fill = CGMutablePath()
        guard distance > 0.1 else { return (outline, nil) }

        let weight = CGFloat(annotation.style.lineWidth) * strokeScale
        let isCurved = options.pathStyle == .curved
        let anchors = ScreenshotArrowAnchors.resolved(for: annotation)
        let first = ScreenshotArrowAnchors.position(
            anchors.first,
            start: start,
            end: tip,
            flipped: flipped
        )
        let second = ScreenshotArrowAnchors.position(
            anchors.second,
            start: start,
            end: tip,
            flipped: flipped
        )
        // Solve the cubic so its points at 1/3 and 2/3 pass through the draggable anchors.
        let controlOne = CGPoint(
            x: 3 * first.x - 1.5 * second.x - (5 * start.x - 2 * tip.x) / 6,
            y: 3 * first.y - 1.5 * second.y - (5 * start.y - 2 * tip.y) / 6
        )
        let controlTwo = CGPoint(
            x: 3 * second.x - 1.5 * first.x - (5 * tip.x - 2 * start.x) / 6,
            y: 3 * second.y - 1.5 * first.y - (5 * tip.y - 2 * start.y) / 6
        )

        func sample(_ fraction: CGFloat) -> (point: CGPoint, direction: CGPoint) {
            if !isCurved {
                let point = CGPoint(
                    x: start.x + delta.x * fraction,
                    y: start.y + delta.y * fraction
                )
                return (point, CGPoint(x: delta.x / distance, y: delta.y / distance))
            }
            let inverse = 1 - fraction
            let firstWeight = inverse * inverse * inverse
            let secondWeight = 3 * inverse * inverse * fraction
            let thirdWeight = 3 * inverse * fraction * fraction
            let fourthWeight = fraction * fraction * fraction
            let point = CGPoint(
                x: firstWeight * start.x + secondWeight * controlOne.x
                    + thirdWeight * controlTwo.x + fourthWeight * tip.x,
                y: firstWeight * start.y + secondWeight * controlOne.y
                    + thirdWeight * controlTwo.y + fourthWeight * tip.y
            )
            let horizontal = inverse * inverse * (controlOne.x - start.x)
                + 2 * inverse * fraction * (controlTwo.x - controlOne.x)
                + fraction * fraction * (tip.x - controlTwo.x)
            let vertical = inverse * inverse * (controlOne.y - start.y)
                + 2 * inverse * fraction * (controlTwo.y - controlOne.y)
                + fraction * fraction * (tip.y - controlTwo.y)
            let length = max(0.01, hypot(horizontal, vertical))
            return (point, CGPoint(x: horizontal / length, y: vertical / length))
        }

        func offset(
            _ point: CGPoint,
            _ direction: CGPoint,
            along: CGFloat = 0,
            across: CGFloat = 0
        ) -> CGPoint {
            CGPoint(
                x: point.x + direction.x * along - direction.y * across,
                y: point.y + direction.y * along + direction.x * across
            )
        }

        let headLength = min(distance * 0.42, max(9 * strokeScale, weight * 2.8))
        let headBaseProgress = max(0, 1 - headLength / distance)
        let headAxis = sample(1).direction
        let headBase = sample(headBaseProgress).point
        let headHalfWidth = max(weight * 0.5, headLength * 0.68)
        let headLeft = offset(headBase, headAxis, across: headHalfWidth)
        let headRight = offset(headBase, headAxis, across: -headHalfWidth)

        if options.isTapered {
            let bodyEnd = headBaseProgress
            let startHalfWidth = max(0.35 * strokeScale, 0.35)
            let bodyHalfWidth = max(startHalfWidth, headHalfWidth * 0.46)
            let steps = 24

            func bodyEdge(_ index: Int, sign: CGFloat) -> CGPoint {
                let progress = CGFloat(index) / CGFloat(steps)
                let sample = sample(progress * bodyEnd)
                let width = startHalfWidth + (bodyHalfWidth - startHalfWidth)
                    * pow(progress, 0.82)
                return offset(sample.point, sample.direction, across: width * sign)
            }

            let positiveEdge = (0...steps).map { bodyEdge($0, sign: 1) }
            let negativeEdge = (0...steps).reversed().map { bodyEdge($0, sign: -1) }
            let connectedShape = CGMutablePath()
            guard let tailLeft = positiveEdge.first,
                  let shoulderLeft = positiveEdge.last,
                  let shoulderRight = negativeEdge.first,
                  let tailRight = negativeEdge.last else {
                return (outline, nil)
            }
            connectedShape.move(to: tailLeft)
            for point in positiveEdge.dropFirst() {
                connectedShape.addLine(to: point)
            }
            connectedShape.addQuadCurve(
                to: headLeft,
                control: CGPoint(
                    x: shoulderLeft.x + (headLeft.x - shoulderLeft.x) * 0.55,
                    y: shoulderLeft.y + (headLeft.y - shoulderLeft.y) * 0.55
                )
            )
            connectedShape.addLine(to: tip)
            connectedShape.addQuadCurve(
                to: headRight,
                control: CGPoint(
                    x: tip.x + (headRight.x - tip.x) * 0.72,
                    y: tip.y + (headRight.y - tip.y) * 0.72
                )
            )
            connectedShape.addQuadCurve(
                to: shoulderRight,
                control: CGPoint(
                    x: headRight.x + (shoulderRight.x - headRight.x) * 0.45,
                    y: headRight.y + (shoulderRight.y - headRight.y) * 0.45
                )
            )
            for point in negativeEdge.dropFirst() {
                connectedShape.addLine(to: point)
            }
            connectedShape.addLine(to: tailRight)
            connectedShape.closeSubpath()

            outline.addPath(connectedShape)
            fill.addPath(connectedShape)
        } else {
            outline.move(to: start)
            if isCurved {
                outline.addCurve(to: tip, control1: controlOne, control2: controlTwo)
            } else {
                outline.addLine(to: tip)
            }
            outline.move(to: headLeft)
            outline.addLine(to: tip)
            outline.addLine(to: headRight)
        }
        return (outline, options.isTapered ? fill : nil)
    }

    static func hitTest(
        _ point: CGPoint,
        annotation: ScreenshotAnnotation,
        in boundingRect: CGRect,
        minimumSlop: CGFloat = 6,
        strokeScale: CGFloat = 1
    ) -> Bool {
        switch annotation.kind {
        case .text, .step, .mosaic, .blur:
            return boundingRect.contains(point)
        case .rectangle, .ellipse, .line, .arrow, .brush, .marker, .mosaicStroke,
             .mosaicBlur:
            break
        }
        let path = cgPath(for: annotation, in: boundingRect, strokeScale: strokeScale)
        if let fill = fillPath(for: annotation, in: boundingRect, strokeScale: strokeScale),
           fill.contains(point) {
            return true
        }
        let strokeWidth = max(CGFloat(annotation.style.lineWidth) * strokeScale, minimumSlop * 2)
        let rounded = annotation.style.resolvedCornerStyle == .rounded
        let hitArea = path.copy(
            strokingWithWidth: strokeWidth,
            lineCap: rounded ? .round : .square,
            lineJoin: rounded ? .round : .miter,
            miterLimit: 10
        )
        return hitArea.contains(point)
    }

    private static func endpoint(
        _ point: PixelPoint,
        annotation: ScreenshotAnnotation,
        in boundingRect: CGRect
    ) -> CGPoint {
        let rect = annotation.rect
        func fraction(_ value: Int, start: Int, length: Int) -> CGFloat {
            guard length > 1 else { return 0.5 }
            return CGFloat(value - start) / CGFloat(length)
        }
        return CGPoint(
            x: boundingRect.minX
                + fraction(point.x, start: rect.minX, length: rect.width) * boundingRect.width,
            y: boundingRect.minY
                + fraction(point.y, start: rect.minY, length: rect.height) * boundingRect.height
        )
    }
}
