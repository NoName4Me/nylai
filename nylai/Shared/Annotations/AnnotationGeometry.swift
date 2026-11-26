import CoreGraphics

enum AnnotationShape: String {
    case rectangle, ellipse, triangle, diamond, star
}

/// Geometry only: each editor owns coordinate transforms, styling and interaction.
enum AnnotationGeometry {
    static func shape(_ shape: AnnotationShape, in rect: CGRect, cornerRadius: CGFloat = 0) -> CGPath {
        let path = CGMutablePath()
        switch shape {
        case .rectangle:
            let radius = min(max(0, cornerRadius), min(rect.width, rect.height) / 2)
            if radius > 0 { path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius) }
            else { path.addRect(rect) }
        case .ellipse: path.addEllipse(in: rect)
        case .triangle, .diamond, .star:
            let vertices: [CGPoint]
            switch shape {
            case .triangle: vertices = [CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
            case .diamond: vertices = [CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 0.5), CGPoint(x: 0.5, y: 1), CGPoint(x: 0, y: 0.5)]
            case .star:
                vertices = (0..<10).map { index in
                    let angle = CGFloat(index) * .pi / 5 - .pi / 2
                    let radius: CGFloat = index.isMultiple(of: 2) ? 0.5 : 0.22
                    return CGPoint(x: 0.5 + radius * cos(angle), y: 0.5 + radius * sin(angle))
                }
            default: vertices = []
            }
            let points = vertices.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
            if cornerRadius > 0 { appendRoundedPolygon(points, radius: cornerRadius, to: path) }
            else { appendPolyline(points, to: path); path.closeSubpath() }
        }
        return path
    }

    private static func appendRoundedPolygon(_ points: [CGPoint], radius: CGFloat, to path: CGMutablePath) {
        guard points.count >= 3 else { return }
        for i in points.indices {
            let p = points[i]
            let previous = points[(i + points.count - 1) % points.count]
            let next = points[(i + 1) % points.count]
            let a = hypot(previous.x - p.x, previous.y - p.y)
            let b = hypot(next.x - p.x, next.y - p.y)
            let distance = min(radius, a * 0.45, b * 0.45)
            let entry = CGPoint(x: p.x + (previous.x - p.x) * distance / max(0.001, a),
                                y: p.y + (previous.y - p.y) * distance / max(0.001, a))
            let exit = CGPoint(x: p.x + (next.x - p.x) * distance / max(0.001, b),
                               y: p.y + (next.y - p.y) * distance / max(0.001, b))
            if i == 0 { path.move(to: entry) } else { path.addLine(to: entry) }
            path.addQuadCurve(to: exit, control: p)
        }
        path.closeSubpath()
    }

    static func appendPolyline(_ points: [CGPoint], to path: CGMutablePath) {
        guard let first = points.first else { return }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        if points.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y)) }
    }
}
