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
            alert.messageText = L10n.shared.string("需要重新启动 %@", AppName.current)
            alert.informativeText = L10n.shared.string(
                "屏幕录制权限已经开启，但当前运行中的 %@ 尚未取得权限。重新启动后即可截图。",
                AppName.current
            )
            alert.addButton(withTitle: L10n.shared.string("重新启动 %@", AppName.current))
            alert.addButton(withTitle: L10n.shared.string("稍后"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn,
               !ScreenRecordingPermission.relaunchApplication() {
                let failureAlert = NSAlert()
                failureAlert.messageText = L10n.shared.string(
                    "无法重新启动 %@",
                    AppName.current
                )
                failureAlert.informativeText = L10n.shared.string(
                    "请退出 %@ 后重新打开。",
                    AppName.current
                )
                failureAlert.runModal()
            }
        } else if error as? ScreenshotError == .permissionRequired {
            alert.messageText = L10n.shared.string("需要屏幕录制权限")
            alert.informativeText = """
            \(L10n.shared.string("请在系统设置中允许当前应用录制屏幕；若列表中已没有该应用，请点击“+”，然后选择："))
            \(Bundle.main.bundleURL.path)
            """
            alert.addButton(withTitle: L10n.shared.string("打开系统设置…"))
            alert.addButton(withTitle: L10n.shared.string("在 Finder 中显示"))
            alert.addButton(withTitle: L10n.shared.string("取消"))
            NSApp.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if !ScreenRecordingPermission.openSystemSettings() {
                    let failureAlert = NSAlert()
                    failureAlert.messageText = L10n.shared.string("无法打开系统设置")
                    failureAlert.informativeText = L10n.shared.string(
                        "请前往系统设置 → 隐私与安全性 → 屏幕录制。"
                    )
                    failureAlert.runModal()
                }
            case .alertSecondButtonReturn:
                ScreenRecordingPermission.showApplicationInFinder()
            default:
                break
            }
        } else {
            alert.messageText = L10n.shared.string("截图未完成")
            alert.addButton(withTitle: L10n.shared.string("好"))
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
