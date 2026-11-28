import CoreGraphics

enum BoardGeometry {
    static func transform(_ frame: CGRect, angle: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: frame.midX, y: frame.midY)
            .rotated(by: angle)
            .translatedBy(x: -frame.midX, y: -frame.midY)
    }

    static func imageRect(_ frame: CGRect, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return frame }
        let factor = min(frame.width / imageSize.width, frame.height / imageSize.height)
        let w = imageSize.width * factor, h = imageSize.height * factor
        return CGRect(x: frame.midX - w / 2, y: frame.midY - h / 2, width: w, height: h)
    }

    static func cornerRadiusHandle(_ frame: CGRect, radius: CGFloat) -> CGPoint {
        let corner = CGPoint(x: frame.maxX, y: frame.maxY)
        let diagonal = hypot(frame.width, frame.height) / 2
        let maximumRadius = min(frame.width, frame.height) / 2
        guard maximumRadius > 0 else { return corner }
        let inset = min(13, diagonal / 2)
        let fraction = (inset + (diagonal - inset) * radius / maximumRadius) / diagonal
        return CGPoint(x: corner.x - frame.width / 2 * fraction, y: corner.y - frame.height / 2 * fraction)
    }

    static func draggedCornerRadius(from start: CGPoint, to end: CGPoint, in frame: CGRect, radius: CGFloat) -> CGFloat {
        let diagonal = hypot(frame.width, frame.height) / 2
        guard diagonal > 0 else { return 0 }
        let travel = diagonal - min(13, diagonal / 2)
        let projected = ((start.x - end.x) * frame.width + (start.y - end.y) * frame.height) / (2 * diagonal)
        let maximumRadius = min(frame.width, frame.height) / 2
        return min(maximumRadius, max(0, radius + projected / travel * maximumRadius))
    }

    static func endpoints(_ item: BoardItem) -> [CGPoint] {
        guard let first = item.points.first, let last = item.points.last else { return [] }
        let t = transform(item.frame, angle: item.angle)
        return [first, last].map {
            CGPoint(x: item.frame.minX + $0.x * item.frame.width, y: item.frame.minY + $0.y * item.frame.height).applying(t)
        }
    }

    static func constrained(_ end: CGPoint, from start: CGPoint, shape: Bool, control: Bool, shift: Bool) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        if shape {
            guard control else { return end }
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        }
        guard control || shift else { return end }
        let step: CGFloat = shift ? .pi / 2 : .pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        let length = hypot(dx, dy)
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }

    static func setEndpoints(_ item: inout BoardItem, _ a: CGPoint, _ b: CGPoint) {
        let frame = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: max(1, abs(b.x - a.x)), height: max(1, abs(b.y - a.y)))
        item.frame = frame
        item.rotation = nil
        item.points = [a, b].map { CGPoint(x: ($0.x - frame.minX) / frame.width, y: ($0.y - frame.minY) / frame.height) }
    }
}
