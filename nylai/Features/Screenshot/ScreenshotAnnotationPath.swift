import CoreGraphics

struct ScreenshotArrowAnchors: Equatable {
    var first = CGPoint(x: 1.0 / 3, y: 0)
    var second = CGPoint(x: 2.0 / 3, y: 0)

    static func resolved(for annotation: ScreenshotAnnotation) -> Self {
        if let anchors = annotation.arrowAnchors { return anchors }
        let bend: CGFloat = switch annotation.style.arrowOptions?.curve {
        case .left: -0.15
        case .right: 0.15
        default: 0
        }
        return Self(first: CGPoint(x: 1.0 / 3, y: bend), second: CGPoint(x: 2.0 / 3, y: bend))
    }

    static func position(_ anchor: CGPoint, start: CGPoint, end: CGPoint, flipped: Bool = true) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let side = anchor.y * (flipped ? 1 : -1)
        return CGPoint(x: start.x + dx * anchor.x - dy * side,
                       y: start.y + dy * anchor.x + dx * side)
    }

    static func relative(_ point: CGPoint, start: CGPoint, end: CGPoint) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = max(1, dx * dx + dy * dy)
        let px = point.x - start.x
        let py = point.y - start.y
        return CGPoint(x: (px * dx + py * dy) / lengthSquared,
                       y: (py * dx - px * dy) / lengthSquared)
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
            path.addRect(boundingRect)
        case .ellipse:
            path.addEllipse(in: boundingRect)
        case .line:
            path.move(to: endpoint(annotation.start, annotation: annotation, in: boundingRect))
            path.addLine(to: endpoint(annotation.end, annotation: annotation, in: boundingRect))
        case .arrow:
            if let options = resolvedOptions(for: annotation) {
                return arrowGeometry(for: annotation, in: boundingRect, options: options,
                                     flipped: flipped, strokeScale: strokeScale).outline
            }
            let start = endpoint(annotation.start, annotation: annotation, in: boundingRect)
            let end = endpoint(annotation.end, annotation: annotation, in: boundingRect)
            path.move(to: start)
            path.addLine(to: end)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let distance = hypot(end.x - start.x, end.y - start.y)
            let headLength = min(distance * 0.35, max(8, CGFloat(annotation.style.lineWidth) * 4))
            guard headLength > 0 else { return path }
            let spread = CGFloat.pi / 7
            func addHead(at tip: CGPoint, angle: CGFloat, closed: Bool) {
                func wing(_ offset: CGFloat) -> CGPoint {
                    CGPoint(x: tip.x - cos(angle + offset) * headLength,
                            y: tip.y - sin(angle + offset) * headLength)
                }
                path.move(to: wing(-spread))
                path.addLine(to: tip)
                path.addLine(to: wing(spread))
                if closed { path.closeSubpath() }
            }
            addHead(at: end, angle: angle, closed: annotation.style.arrowStyle == .solid)
            if annotation.style.arrowStyle == .double {
                addHead(at: start, angle: angle + .pi, closed: false)
            }
        case .brush:
            let mapped = annotation.points.map {
                endpoint($0, annotation: annotation, in: boundingRect)
            }
            guard let first = mapped.first else { break }
            path.move(to: first)
            for point in mapped.dropFirst() {
                path.addLine(to: point)
            }
            if mapped.count == 1 {
                path.addLine(to: CGPoint(x: first.x + 0.5, y: first.y))
            }
        case .text:
            break
        case .step:
            path.addEllipse(in: boundingRect)
        case .mosaic:
            path.addRect(boundingRect)
        }
        return path
    }

    static func fillPath(for annotation: ScreenshotAnnotation, in rect: CGRect,
                         flipped: Bool = true, strokeScale: CGFloat = 1) -> CGPath? {
        if annotation.kind == .arrow, let options = resolvedOptions(for: annotation) {
            return arrowGeometry(for: annotation, in: rect, options: options,
                                 flipped: flipped, strokeScale: strokeScale).fill
        }
        guard (annotation.kind.supportsFill && annotation.style.fillsShape == true)
            || (annotation.kind == .arrow && annotation.style.arrowStyle == .solid) else { return nil }
        return cgPath(for: annotation, in: rect, flipped: flipped, strokeScale: strokeScale)
    }

    private static func resolvedOptions(for annotation: ScreenshotAnnotation) -> ScreenshotArrowOptions? {
        if let options = annotation.style.arrowOptions { return options }
        guard annotation.arrowAnchors != nil else { return nil }
        return ScreenshotArrowOptions(tip: annotation.style.arrowStyle == .solid ? .triangle : .open)
    }

    static func arrowHandles(for annotation: ScreenshotAnnotation, in rect: CGRect) -> [CGPoint] {
        let start = endpoint(annotation.start, annotation: annotation, in: rect)
        let end = endpoint(annotation.end, annotation: annotation, in: rect)
        let anchors = ScreenshotArrowAnchors.resolved(for: annotation)
        return [start, ScreenshotArrowAnchors.position(anchors.first, start: start, end: end),
                ScreenshotArrowAnchors.position(anchors.second, start: start, end: end), end]
    }

    private static func arrowGeometry(
        for annotation: ScreenshotAnnotation, in rect: CGRect, options raw: ScreenshotArrowOptions,
        flipped: Bool, strokeScale: CGFloat
    ) -> (outline: CGPath, fill: CGPath?) {
        let options = raw.normalized()
        let start = endpoint(annotation.start, annotation: annotation, in: rect)
        let tip = endpoint(annotation.end, annotation: annotation, in: rect)
        let delta = CGPoint(x: tip.x - start.x, y: tip.y - start.y)
        let distance = hypot(delta.x, delta.y)
        let outline = CGMutablePath()
        let fill = CGMutablePath()
        guard distance > 0.1 else { return (outline, nil) }
        let weight = CGFloat(annotation.style.lineWidth) * strokeScale
        let anchors = ScreenshotArrowAnchors.resolved(for: annotation)
        let first = ScreenshotArrowAnchors.position(anchors.first, start: start, end: tip, flipped: flipped)
        let second = ScreenshotArrowAnchors.position(anchors.second, start: start, end: tip, flipped: flipped)
        // Solve the cubic so its points at 1/3 and 2/3 pass through the draggable anchors.
        let controlOne = CGPoint(x: 3 * first.x - 1.5 * second.x - (5 * start.x - 2 * tip.x) / 6,
                                 y: 3 * first.y - 1.5 * second.y - (5 * start.y - 2 * tip.y) / 6)
        let controlTwo = CGPoint(x: 3 * second.x - 1.5 * first.x - (5 * tip.x - 2 * start.x) / 6,
                                 y: 3 * second.y - 1.5 * first.y - (5 * tip.y - 2 * start.y) / 6)

        func sample(_ fraction: CGFloat) -> (point: CGPoint, direction: CGPoint) {
            let inverse = 1 - fraction
            let firstWeight = inverse * inverse * inverse
            let secondWeight = 3 * inverse * inverse * fraction
            let thirdWeight = 3 * inverse * fraction * fraction
            let fourthWeight = fraction * fraction * fraction
            let point = CGPoint(
                x: firstWeight * start.x + secondWeight * controlOne.x + thirdWeight * controlTwo.x + fourthWeight * tip.x,
                y: firstWeight * start.y + secondWeight * controlOne.y + thirdWeight * controlTwo.y + fourthWeight * tip.y
            )
            let horizontal = inverse * inverse * (controlOne.x - start.x)
                + 2 * inverse * fraction * (controlTwo.x - controlOne.x) + fraction * fraction * (tip.x - controlTwo.x)
            let vertical = inverse * inverse * (controlOne.y - start.y)
                + 2 * inverse * fraction * (controlTwo.y - controlOne.y) + fraction * fraction * (tip.y - controlTwo.y)
            let length = max(0.01, hypot(horizontal, vertical))
            return (point, CGPoint(x: horizontal / length, y: vertical / length))
        }
        func offset(_ point: CGPoint, _ direction: CGPoint, along: CGFloat = 0, across: CGFloat = 0) -> CGPoint {
            CGPoint(x: point.x + direction.x * along - direction.y * across,
                    y: point.y + direction.y * along + direction.x * across)
        }
        func polygon(_ points: [CGPoint], filled: Bool) {
            outline.addLines(between: points)
            outline.closeSubpath()
            if filled {
                fill.addLines(between: points)
                fill.closeSubpath()
            }
        }

        let headLength = min(distance * 0.45, options.tapered ? distance * 0.23 : max(10 * strokeScale, weight * 4))
        let headWidth = headLength * 0.48
        let endDirection = sample(1).direction
        let headLeft = offset(tip, endDirection, along: -headLength, across: headWidth)
        let headRight = offset(tip, endDirection, along: -headLength, across: -headWidth)
        let notch = offset(tip, endDirection, along: -headLength * 0.68)
        let base = options.tip == .dart ? notch : offset(tip, endDirection, along: -headLength)
        if options.form == .line {
            outline.move(to: start)
            outline.addCurve(to: tip, control1: controlOne, control2: controlTwo)
            if options.tip == .open {
                outline.addLines(between: [headLeft, tip, headRight])
            } else {
                polygon(options.tip == .dart ? [headLeft, tip, headRight, notch] : [headLeft, tip, headRight],
                        filled: true)
            }
            let radius = max(3 * strokeScale, weight * 0.95)
            let direction = sample(0).direction
            if options.start == .dot {
                let dot = CGRect(x: start.x - radius, y: start.y - radius, width: radius * 2, height: radius * 2)
                outline.addEllipse(in: dot)
                fill.addEllipse(in: dot)
            } else if options.start == .diamond {
                polygon([offset(start, direction, along: -radius), offset(start, direction, across: radius),
                         offset(start, direction, along: radius), offset(start, direction, across: -radius)],
                        filled: true)
            }
        } else {
            let bodyEnd = max(0.20, 1 - headLength / distance * (options.tip == .dart ? 0.68 : 1))
            let halfWidth = min(headWidth * 0.72, options.tapered ? distance * 0.036 : max(2 * strokeScale, weight * 0.85))
            let steps = 24
            func edge(_ index: Int, sign: CGFloat) -> CGPoint {
                let progress = CGFloat(index) / CGFloat(steps)
                let sample = sample(progress * bodyEnd)
                let width = halfWidth * (options.tapered ? 0.10 + 0.90 * progress : 1)
                let point = index == steps ? base : sample.point
                return offset(point, sample.direction, across: width * sign)
            }
            var points = (0...steps).map { edge($0, sign: 1) }
            points += [headLeft, tip, headRight]
            points += (0...steps).reversed().map { edge($0, sign: -1) }
            if options.start == .fork {
                points.append(offset(start, sample(0).direction, along: min(headLength * 0.52, distance * 0.2)))
            }
            polygon(points, filled: options.filled)
        }
        return (outline, fill.isEmpty ? nil : fill)
    }

    static func hitTest(
        _ point: CGPoint,
        annotation: ScreenshotAnnotation,
        in boundingRect: CGRect,
        minimumSlop: CGFloat = 6,
        strokeScale: CGFloat = 1
    ) -> Bool {
        switch annotation.kind {
        case .text, .step, .mosaic:
            return boundingRect.contains(point)
        case .rectangle, .ellipse, .line, .arrow, .brush:
            break
        }
        let path = cgPath(for: annotation, in: boundingRect, strokeScale: strokeScale)
        if let fill = fillPath(for: annotation, in: boundingRect, strokeScale: strokeScale),
           fill.contains(point) { return true }
        let strokeWidth = max(CGFloat(annotation.style.lineWidth) * strokeScale, minimumSlop * 2)
        let hitArea = path.copy(
            strokingWithWidth: strokeWidth,
            lineCap: .round,
            lineJoin: .round,
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
            x: boundingRect.minX + fraction(point.x, start: rect.minX, length: rect.width) * boundingRect.width,
            y: boundingRect.minY + fraction(point.y, start: rect.minY, length: rect.height) * boundingRect.height
        )
    }
}
