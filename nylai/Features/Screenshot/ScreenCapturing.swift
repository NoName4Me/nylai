import CoreGraphics

// 捕获与输出分离，调用方负责权限错误展示及保存交互。
@MainActor
protocol ScreenCapturing {
    func captureDisplay(_ displayID: CGDirectDisplayID) async throws -> CGImage
}

@MainActor
protocol WindowCapturing {
    func windowCandidates() async throws -> [WindowCaptureCandidate]
    func captureWindow(_ windowID: CGWindowID) async throws -> CGImage
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
