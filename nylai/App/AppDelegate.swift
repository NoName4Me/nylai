import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = AppPreferences()
    private var statusBarController: StatusBarController?
    private let screenshotController = ScreenshotController()
    private var screenshotTask: Task<Void, Never>?
    private lazy var screenshotShortcut = GlobalShortcutController(shortcut: .captureMainDisplay) { [weak self] in
        self?.captureMainDisplay()
    }
    private lazy var settingsShortcut = GlobalShortcutController(shortcut: .openSettings) { [weak self] in
        self?.showSettings()
    }
    private lazy var settingsWindowController = SettingsWindowController(
        preferences: preferences, settingsShortcut: settingsShortcut, screenshotShortcut: screenshotShortcut
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        statusBarController = StatusBarController(
            openSettings: { [weak self] in self?.showSettings() },
            captureMainDisplay: { [weak self] in self?.captureMainDisplay() }
        )
        settingsShortcut.start()
        screenshotShortcut.start()
        if preferences.showSettingsOnLaunch || shortcutRegistrationFailed {
            showSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        settingsShortcut.stop()
        screenshotShortcut.stop()
        screenshotTask?.cancel()
    }

    private var shortcutRegistrationFailed: Bool {
        if case .failed = settingsShortcut.status { return true }
        if case .failed = screenshotShortcut.status { return true }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    @objc private func captureMainDisplay() {
        guard screenshotTask == nil else { return }
        screenshotTask = Task { [weak self] in
            guard let self else { return }
            defer { screenshotTask = nil }
            await screenshotController.captureMainDisplay()
        }
    }

    @objc private func showSettings() {
        settingsWindowController.present()
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "nylai")
        applicationMenu.addItem(withTitle: "关于 nylai", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let captureItem = applicationMenu.addItem(withTitle: "截取主显示器…", action: #selector(captureMainDisplay), keyEquivalent: "")
        captureItem.target = self
        let settingsItem = applicationMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "退出 nylai", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }
}
