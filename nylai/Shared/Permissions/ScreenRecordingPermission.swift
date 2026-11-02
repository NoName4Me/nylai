import AppKit
import CoreGraphics

@MainActor
enum ScreenRecordingPermission {
    // 只检查当前授权，不在启动或打开设置时触发授权请求。
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func openSystemSettings() -> Bool {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }
}
