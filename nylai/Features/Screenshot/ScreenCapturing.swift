import CoreGraphics

// 捕获与输出分离，调用方负责权限错误展示及保存交互。
@MainActor
protocol ScreenCapturing {
    func captureDisplay(_ displayID: CGDirectDisplayID) async throws -> CGImage
}
