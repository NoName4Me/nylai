import ApplicationServices
import CoreGraphics

// 捕获与输出分离，调用方负责权限错误展示及保存交互。
@MainActor
protocol ScreenCapturing {
    func captureDisplay(_ displayID: CGDirectDisplayID) async throws -> CGImage
    func captureDisplayExcludingOwnApplication(
        _ displayID: CGDirectDisplayID
    ) async throws -> CGImage
}

@MainActor
protocol WindowCapturing {
    func windowCandidates() async throws -> [WindowCaptureCandidate]
    func switchableWindowCandidates() async throws -> [WindowCaptureCandidate]
    func captureWindow(_ windowID: CGWindowID) async throws -> CGImage
}

extension WindowCapturing {
    func switchableWindowCandidates() async throws -> [WindowCaptureCandidate] {
        try await windowCandidates()
    }
}

extension ScreenCapturing {
    func captureDisplayExcludingOwnApplication(
        _ displayID: CGDirectDisplayID
    ) async throws -> CGImage {
        try await captureDisplay(displayID)
    }
}

// 候选顺序与 CGWindowList 的前后关系一致，下标越小越靠前。
struct WindowCaptureCandidate: Equatable, Sendable {
    let windowID: CGWindowID
    let processIdentifier: pid_t
    let frame: CGRect
    let title: String?
    let applicationName: String?
    let bundleIdentifier: String?
}

struct WindowCaptureAccessibilityWindow: Equatable, Sendable {
    var windowID: CGWindowID? = nil
    let title: String?
    let frame: CGRect
}

enum WindowCaptureAccessibilityMatcher {
    static func contains(
        candidateID: CGWindowID? = nil,
        candidateTitle: String?,
        candidateFrame: CGRect,
        in windows: [WindowCaptureAccessibilityWindow]
    ) -> Bool {
        if let candidateID, windows.contains(where: { $0.windowID == candidateID }) {
            return true
        }
        guard let candidateTitle = normalizedTitle(candidateTitle) else { return false }
        return windows.filter { window in
            guard window.windowID == nil else { return false }
            guard frameMatches(window.frame, candidateFrame) else {
                return false
            }
            return candidateTitle == normalizedTitle(window.title)
        }.count == 1
    }

    static func normalizedTitle(_ title: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        return title
    }

    static func windowID(of window: AXUIElement) -> CGWindowID? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXWindowNumber" as CFString, &value) == .success,
              let number = value as? NSNumber, number.uint32Value != 0 else { return nil }
        return number.uint32Value
    }

    private static func frameMatches(_ actual: CGRect, _ expected: CGRect) -> Bool {
        let tolerance: CGFloat = 3
        return abs(actual.minX - expected.minX) <= tolerance
            && abs(actual.minY - expected.minY) <= tolerance
            && abs(actual.width - expected.width) <= tolerance
            && abs(actual.height - expected.height) <= tolerance
    }
}

enum ScreenshotCaptureTarget: Equatable, Sendable {
    case display(displayID: CGDirectDisplayID, frame: CGRect)
    case window(WindowCaptureCandidate)

    var frame: CGRect {
        switch self {
        case .display(_, let frame):
            frame
        case .window(let candidate):
            candidate.frame
        }
    }
}
