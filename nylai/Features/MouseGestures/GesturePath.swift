import CoreGraphics
import Foundation

enum GestureDirection: String, Codable, CaseIterable, Equatable, Sendable {
    case up = "up"
    case down = "down"
    case left = "left"
    case right = "right"

    var arrow: String {
        switch self {
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        }
    }
}

struct GesturePath: Codable, Equatable, Hashable, Sendable {
    var directions: [GestureDirection]

    init(_ directions: [GestureDirection] = []) {
        self.directions = directions
    }

    var display: String {
        directions.map(\.arrow).joined()
    }

    var isEmpty: Bool { directions.isEmpty }
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
    private(set) var hasExceededSegmentLimit = false
    private(set) var sampledPoints: [CGPoint] = []
    private var startPoint: CGPoint?
    private var segmentAnchor: CGPoint?
    private var directions: [GestureDirection] = []

    init(thresholds: GestureRecognitionThresholds = .standard) {
        self.thresholds = thresholds
    }

    mutating func begin(at point: CGPoint) {
        isTracking = true
        hasEnteredGesture = false
        hasExceededSegmentLimit = false
        sampledPoints = [point]
        startPoint = point
        segmentAnchor = point
        directions = []
    }

    @discardableResult
    mutating func move(to point: CGPoint) -> Bool {
        guard isTracking, let startPoint, let segmentAnchor else { return false }
        if sampledPoints.last != point {
            sampledPoints.append(point)
        }

        if !hasEnteredGesture {
            guard distance(from: startPoint, to: point) >= thresholds.startDistance else {
                return false
            }
            let initialDirection = direction(from: startPoint, to: point)
            directions = [initialDirection]
            self.segmentAnchor = point
            hasEnteredGesture = true
            return true
        }

        guard !hasExceededSegmentLimit,
              distance(from: segmentAnchor, to: point) >= thresholds.turnDistance else {
            return true
        }
        guard let current = directions.last else { return true }
        let next = direction(from: segmentAnchor, to: point)
        guard next != current else { return true }
        guard directions.count < thresholds.maximumSegments else {
            hasExceededSegmentLimit = true
            return true
        }
        directions.append(next)
        self.segmentAnchor = point
        return true
    }

    func recognizedPath() -> GesturePath? {
        guard hasEnteredGesture, !hasExceededSegmentLimit else { return nil }
        return GesturePath(directions)
    }

    mutating func reset() {
        self = GesturePathRecognizer(thresholds: thresholds)
    }

    private func direction(from start: CGPoint, to end: CGPoint) -> GestureDirection {
        let dx = end.x - start.x
        let dy = end.y - start.y
        if abs(dx) >= abs(dy) {
            return dx >= 0 ? .right : .left
        }
        // CGEvent 与 AppKit 的全局坐标都使用向上为正的 Y 轴。
        return dy >= 0 ? .up : .down
    }

    private func distance(from first: CGPoint, to second: CGPoint) -> CGFloat {
        hypot(second.x - first.x, second.y - first.y)
    }
}
