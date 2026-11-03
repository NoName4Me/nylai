import AppKit

@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let openSettings: () -> Void
    private let captureScreenshot: () -> Void
    private let showScreenshotHistory: () -> Void
    private let showCollage: () -> Void
    private let showClipboardHistory: () -> Void
    private let canUseScreenshot: () -> Bool
    private let canUseClipboard: () -> Bool
    private let isInteractionLocked: () -> Bool
    private var screenshotItems: [NSMenuItem] = []
    private var settingsItem: NSMenuItem?

    init(
        openSettings: @escaping () -> Void,
        captureScreenshot: @escaping () -> Void,
        showScreenshotHistory: @escaping () -> Void,
        showCollage: @escaping () -> Void,
        showClipboardHistory: @escaping () -> Void,
        canUseScreenshot: @escaping () -> Bool,
        canUseClipboard: @escaping () -> Bool,
        isInteractionLocked: @escaping () -> Bool
    ) {
        self.openSettings = openSettings
        self.captureScreenshot = captureScreenshot
        self.showScreenshotHistory = showScreenshotHistory
        self.showCollage = showCollage
        self.showClipboardHistory = showClipboardHistory
        self.canUseScreenshot = canUseScreenshot
        self.canUseClipboard = canUseClipboard
        self.isInteractionLocked = isInteractionLocked
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
        menu.delegate = self
        let interactiveItem = menu.addItem(withTitle: "截图…", action: #selector(capture), keyEquivalent: "")
        interactiveItem.target = self
        let historyItem = menu.addItem(
            withTitle: "最近截图…",
            action: #selector(showHistory),
            keyEquivalent: ""
        )
        historyItem.target = self
        let collageItem = menu.addItem(
            withTitle: "自由拼图…",
            action: #selector(openCollage),
            keyEquivalent: ""
        )
        collageItem.target = self
        let clipboardItem = menu.addItem(
            withTitle: "剪贴板历史…",
            action: #selector(showClipboard),
            keyEquivalent: ""
        )
        clipboardItem.target = self
        menu.addItem(.separator())
        let settingsItem = menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        self.settingsItem = settingsItem
        screenshotItems = [interactiveItem, historyItem, collageItem]
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 nylai", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func capture() {
        statusItem.menu?.cancelTracking()
        captureScreenshot()
    }

    @objc private func showSettings() {
        openSettings()
    }

    @objc private func showHistory() {
        statusItem.menu?.cancelTracking()
        showScreenshotHistory()
    }

    @objc private func openCollage() {
        statusItem.menu?.cancelTracking()
        showCollage()
    }

    @objc private func showClipboard() {
        statusItem.menu?.cancelTracking()
        showClipboardHistory()
    }
}

extension StatusBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        let screenshotAvailable = canUseScreenshot() && !isInteractionLocked()
        screenshotItems.forEach { $0.isEnabled = screenshotAvailable }
        findClipboardItem(in: menu)?.isEnabled = canUseClipboard() && !isInteractionLocked()
        settingsItem?.isEnabled = !isInteractionLocked()
    }

    private func findClipboardItem(in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.action == #selector(showClipboard) }
    }
}
