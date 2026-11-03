import CoreGraphics

enum ScreenshotAnnotationPath {
    static func cgPath(
        for annotation: ScreenshotAnnotation,
        in boundingRect: CGRect
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
            let start = endpoint(annotation.start, annotation: annotation, in: boundingRect)
            let end = endpoint(annotation.end, annotation: annotation, in: boundingRect)
            path.move(to: start)
            path.addLine(to: end)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let distance = hypot(end.x - start.x, end.y - start.y)
            let headLength = min(distance * 0.35, max(8, CGFloat(annotation.style.lineWidth) * 4))
            guard headLength > 0 else { return path }
            let spread = CGFloat.pi / 7
            path.move(to: end)
            path.addLine(to: CGPoint(
                x: end.x - cos(angle - spread) * headLength,
                y: end.y - sin(angle - spread) * headLength
            ))
            path.move(to: end)
            path.addLine(to: CGPoint(
                x: end.x - cos(angle + spread) * headLength,
                y: end.y - sin(angle + spread) * headLength
            ))
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

    static func hitTest(
        _ point: CGPoint,
        annotation: ScreenshotAnnotation,
        in boundingRect: CGRect,
        minimumSlop: CGFloat = 6
    ) -> Bool {
        switch annotation.kind {
        case .text, .step, .mosaic:
            return boundingRect.contains(point)
        case .rectangle, .ellipse, .line, .arrow, .brush:
            break
        }
        let path = cgPath(for: annotation, in: boundingRect)
        let strokeWidth = max(CGFloat(annotation.style.lineWidth), minimumSlop * 2)
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
