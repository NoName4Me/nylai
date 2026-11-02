import AppKit
import Observation

@MainActor
@Observable
final class ScreenshotController {
    private let capturer: any ScreenCapturing
    private let saver: any ScreenshotSaving
    private let presentError: @MainActor (Error) -> Void
    private(set) var isBusy = false

    init(
        capturer: any ScreenCapturing = ScreenCaptureService(),
        saver: any ScreenshotSaving = PNGScreenshotSaver(),
        presentError: @escaping @MainActor (Error) -> Void = ScreenshotController.showError
    ) {
        self.capturer = capturer
        self.saver = saver
        self.presentError = presentError
    }

    func captureMainDisplay() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let image = try await capturer.captureDisplay(CGMainDisplayID())
            try Task.checkCancellation()
            _ = try await saver.save(image)
        } catch is CancellationError {
            // 任务取消不弹出失败提示。
        } catch {
            presentError(error)
        }
    }

    private static func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.informativeText = error.localizedDescription
        if error as? ScreenshotError == .permissionRequired {
            alert.messageText = "需要屏幕录制权限"
            alert.addButton(withTitle: "打开系统设置…")
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn,
               !ScreenRecordingPermission.openSystemSettings() {
                let failureAlert = NSAlert()
                failureAlert.messageText = "无法打开系统设置"
                failureAlert.informativeText = "请前往系统设置 → 隐私与安全性 → 屏幕录制。"
                failureAlert.runModal()
            }
        } else {
            alert.messageText = "截图未完成"
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
