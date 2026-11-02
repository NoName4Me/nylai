import CoreGraphics

// 后续用 ScreenCaptureKit 实现；本轮不读取或保存屏幕内容。
@MainActor
protocol ScreenCapturing {
    func captureDisplay(_ displayID: CGDirectDisplayID) async throws -> CGImage
}
