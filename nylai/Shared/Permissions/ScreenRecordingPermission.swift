import AppKit
import CoreGraphics

@MainActor
enum ScreenRecordingPermission {
    private static var hasPromptedInThisLaunch = false

    // 只检查当前授权，不在启动或打开设置时触发授权请求。
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    // 仅由用户主动触发截图的路径调用。
    static func requestAccessIfNeeded() -> Bool {
        if isGranted {
            return true
        }
        guard !hasPromptedInThisLaunch else {
            return false
        }
        hasPromptedInThisLaunch = true
        return CGRequestScreenCaptureAccess()
    }

    static func resetPromptStateForTesting() {
        hasPromptedInThisLaunch = false
    }

    @discardableResult
    static func openSystemSettings() -> Bool {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    static func showApplicationInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    // ScreenCaptureKit can keep a declined state for the lifetime of a process.
    // Launch a fresh instance before terminating this one so a newly granted
    // permission takes effect without asking the user to find the app manually.
    @discardableResult
    static func relaunchApplication() -> Bool {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", bundleURL.path]
        do {
            try process.run()
        } catch {
            return false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
        return true
    }
}
