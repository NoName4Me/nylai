import CoreGraphics

enum AnnotationShape: String {
    case rectangle, ellipse, triangle, diamond, star
}

/// Geometry only: each editor owns coordinate transforms, styling and interaction.
enum AnnotationGeometry {
    static func shape(_ shape: AnnotationShape, in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        switch shape {
        case .rectangle: path.addRect(rect)
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
            appendPolyline(vertices.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }, to: path)
            path.closeSubpath()
        }
        return path
    }

    static func appendPolyline(_ points: [CGPoint], to path: CGMutablePath) {
        guard let first = points.first else { return }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        if points.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y)) }
    }
}
