import CoreGraphics
import Foundation

enum GestureDirection: String, Codable, CaseIterable, Equatable, Sendable {
    case up = "up"
    case down = "down"
    case left = "left"
    case right = "right"

    case upRight, upLeft, downRight, downLeft

    var offset: CGPoint {
        switch self {
        case .up: CGPoint(x: 0, y: 1)
        case .down: CGPoint(x: 0, y: -1)
        case .left: CGPoint(x: -1, y: 0)
        case .right: CGPoint(x: 1, y: 0)
        case .upRight: CGPoint(x: 1, y: 1)
        case .upLeft: CGPoint(x: -1, y: 1)
        case .downRight: CGPoint(x: 1, y: -1)
        case .downLeft: CGPoint(x: -1, y: -1)
        }
    }

    var arrow: String {
        switch self {
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        case .upRight: "↗"
        case .upLeft: "↖"
        case .downRight: "↘"
        case .downLeft: "↙"
        }
    }
}

enum GestureCircle: String, Codable, Hashable, Sendable {
    case clockwise, counterclockwise
}

struct GesturePath: Codable, Equatable, Hashable, Sendable {
    let directions: [GestureDirection]
    let circle: GestureCircle?

    init(_ directions: [GestureDirection] = []) {
        self.directions = directions
        self.circle = nil
    }

    init(circle: GestureCircle) {
        directions = []
        self.circle = circle
    }

    var display: String {
        if let circle {
            return circle == .clockwise
                ? L10n.shared.string("顺时针圆圈")
                : L10n.shared.string("逆时针圆圈")
        }
        return directions.map(\.arrow).joined()
    }

    var isEmpty: Bool { directions.isEmpty && circle == nil }
}

struct GestureRecognitionThresholds: Equatable, Sendable {
    var startDistance: CGFloat = 12
    var turnDistance: CGFloat = 12
    var maximumSegments: Int = 4

    static let standard = GestureRecognitionThresholds()
}

struct GesturePathRecognizer: Equatable, Sendable {
    let thresholds: GestureRecognitionThresholds
    private(set) var isTracking = false
    private(set) var hasEnteredGesture = false
    private(set) var sampledPoints: [CGPoint] = []

    var hasExceededSegmentLimit: Bool {
        circleDirection() == nil && lineDirections().count > thresholds.maximumSegments
    }

    init(thresholds: GestureRecognitionThresholds = .standard) {
        self.thresholds = thresholds
    }

    mutating func begin(at point: CGPoint) {
        isTracking = true
        hasEnteredGesture = false
        sampledPoints = [point]
    }

    @discardableResult
    mutating func move(to point: CGPoint) -> Bool {
        guard isTracking, let start = sampledPoints.first, let last = sampledPoints.last else {
            return false
        }
        if distance(last, point) >= 2 { sampledPoints.append(point) }
        if distance(start, point) >= thresholds.startDistance { hasEnteredGesture = true }
        return hasEnteredGesture
    }

    func recognizedPath() -> GesturePath? {
        guard hasEnteredGesture else { return nil }
        if let circle = circleDirection() { return GesturePath(circle: circle) }
        let directions = lineDirections()
        guard !directions.isEmpty, directions.count <= thresholds.maximumSegments else { return nil }
        return GesturePath(directions)
    }

    mutating func reset() {
        self = GesturePathRecognizer(thresholds: thresholds)
    }

    private func lineDirections() -> [GestureDirection] {
        guard sampledPoints.count > 1 else { return [] }
        // Split at the point furthest from the chord, keeping corners and
        // ignoring small deviations along otherwise straight strokes.
        var spans = [(0, sampledPoints.count - 1)]
        var segments: [GestureDirection] = []
        while let (firstIndex, lastIndex) = spans.popLast() {
            let first = sampledPoints[firstIndex]
            let last = sampledPoints[lastIndex]
            let delta = CGPoint(x: last.x - first.x, y: last.y - first.y)
            let length = distance(first, last)
            var deviation = thresholds.turnDistance * 0.55
            var split: Int?
            for index in (firstIndex + 1)..<lastIndex {
                let point = sampledPoints[index]
                let fraction = length == 0 ? 0 : min(1, max(0,
                    ((point.x - first.x) * delta.x + (point.y - first.y) * delta.y) / (length * length)
                ))
                let projected = CGPoint(x: first.x + delta.x * fraction, y: first.y + delta.y * fraction)
                let gap = distance(point, projected)
                if gap > deviation {
                    deviation = gap
                    split = index
                }
            }
            if let split {
                spans.append((split, lastIndex))
                spans.append((firstIndex, split))
            } else if length >= thresholds.turnDistance {
                let octants: [GestureDirection] = [
                    .right, .upRight, .up, .upLeft, .left, .downLeft, .down, .downRight,
                ]
                let index = Int((atan2(delta.y, delta.x) / (.pi / 4)).rounded())
                let direction = octants[(index + 8) % 8]
                if segments.last != direction { segments.append(direction) }
                if segments.count > thresholds.maximumSegments { break }
            }
        }
        return segments
    }

    private func circleDirection() -> GestureCircle? {
        guard sampledPoints.count >= 12,
              let first = sampledPoints.first, let last = sampledPoints.last else { return nil }
        let bounds = sampledPoints.reduce(CGRect.null) {
            $0.union(CGRect(origin: $1, size: .zero))
        }
        let diameter = min(bounds.width, bounds.height)
        guard diameter >= thresholds.startDistance * 2,
              distance(first, last) <= max(9, diameter * 0.28) else { return nil }

        var previousAngle: CGFloat?
        var rotation: CGFloat = 0
        var totalRotation: CGFloat = 0
        var minimumRadius: CGFloat = .infinity
        var maximumRadius: CGFloat = 0
        for point in sampledPoints {
            let horizontal = (point.x - bounds.midX) / (bounds.width / 2)
            let vertical = (point.y - bounds.midY) / (bounds.height / 2)
            let radius = hypot(horizontal, vertical)
            minimumRadius = min(minimumRadius, radius)
            maximumRadius = max(maximumRadius, radius)
            let angle = atan2(vertical, horizontal)
            if let previousAngle {
                let change = atan2(sin(angle - previousAngle), cos(angle - previousAngle))
                guard abs(change) <= .pi / 3 else { return nil }
                rotation += change
                totalRotation += abs(change)
            }
            previousAngle = angle
        }
        guard minimumRadius >= 0.66, maximumRadius <= 1.32,
              abs(rotation) >= .pi * 1.7, abs(rotation) <= .pi * 2.25,
              totalRotation - abs(rotation) <= .pi / 4 else { return nil }
        return rotation < 0 ? .clockwise : .counterclockwise
    }

    private func distance(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
        hypot(second.x - first.x, second.y - first.y)
    }
}
