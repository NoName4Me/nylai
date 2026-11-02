import AppKit

@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let openSettings: () -> Void
    private let captureMainDisplay: () -> Void

    init(openSettings: @escaping () -> Void, captureMainDisplay: @escaping () -> Void) {
        self.openSettings = openSettings
        self.captureMainDisplay = captureMainDisplay
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "nylai")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "nylai"
            button.setAccessibilityLabel("nylai")
        }

        let menu = NSMenu()
        let captureItem = menu.addItem(withTitle: "截取主显示器…", action: #selector(capture), keyEquivalent: "")
        captureItem.target = self
        menu.addItem(.separator())
        let settingsItem = menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 nylai", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func capture() {
        statusItem.menu?.cancelTracking()
        captureMainDisplay()
    }

    @objc private func showSettings() {
        openSettings()
    }
}
