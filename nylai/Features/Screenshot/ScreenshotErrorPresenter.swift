import AppKit

@MainActor
enum ScreenshotErrorPresenter {
    static func show(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.informativeText = error.localizedDescription
        alert.window.level = NSWindow.Level(
            rawValue: NSWindow.Level.screenSaver.rawValue + 1
        )
        if error as? ScreenshotError == .permissionRestartRequired {
            alert.messageText = "需要重新启动 nylai"
            alert.informativeText = "屏幕录制权限已经开启，但当前运行中的 nylai 尚未取得权限。重新启动后即可截图。"
            alert.addButton(withTitle: "重新启动 nylai")
            alert.addButton(withTitle: "稍后")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn,
               !ScreenRecordingPermission.relaunchApplication() {
                let failureAlert = NSAlert()
                failureAlert.messageText = "无法重新启动 nylai"
                failureAlert.informativeText = "请退出 nylai 后重新打开。"
                failureAlert.runModal()
            }
        } else if error as? ScreenshotError == .permissionRequired {
            alert.messageText = "需要屏幕录制权限"
            alert.informativeText = """
            请在系统设置中允许 nylai 录制屏幕。若列表中已没有 nylai，请点击列表下方的「+」，选择：
            \(Bundle.main.bundleURL.path)
            """
            alert.addButton(withTitle: "打开系统设置…")
            alert.addButton(withTitle: "在 Finder 中显示")
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if !ScreenRecordingPermission.openSystemSettings() {
                    let failureAlert = NSAlert()
                    failureAlert.messageText = "无法打开系统设置"
                    failureAlert.informativeText = "请前往系统设置 → 隐私与安全性 → 屏幕录制。"
                    failureAlert.runModal()
                }
            case .alertSecondButtonReturn:
                ScreenRecordingPermission.showApplicationInFinder()
            default:
                break
            }
        } else {
            alert.messageText = "截图未完成"
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
