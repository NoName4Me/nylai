import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = AppPreferences()
    private var statusBarController: StatusBarController?
    private let pinnedImageManager = PinnedImageManager()
    private let longScreenshotPinnedImageManager = PinnedImageManager()
    private let screenshotHistoryStore = ScreenshotHistoryStore()
    private var clipboardHistoryStore: ClipboardHistoryStore?
    private var clipboardLoadError: String?
    private var clipboardLoadAttempted = false
    private var clipboardMonitor: ClipboardMonitor?
    private var clipboardPanelController: ClipboardPanelController?
    private var screenshotOverlayController: ScreenshotOverlayController?
    private var screenshotTask: Task<Void, Never>?
    private let applicationShortcutHandler = ApplicationShortcutHandler()
    private lazy var shortcutRuntime = ShortcutBindingRuntime { [weak self] action in
        self?.perform(action)
    } isActionAvailable: { [weak self] action in
        self?.isActionAvailable(action) ?? false
    }
    private lazy var moduleStateController: ModuleStateController = {
        let controller = ModuleStateController(
            preferences: preferences,
            shortcutRuntime: shortcutRuntime
        )
        controller.onLifecycleChange = { [weak self] module, enabled in
            self?.applyLifecycleChange(module: module, enabled: enabled)
        }
        return controller
    }()
    private var mouseGestureController: MouseGestureController?
    private var windowSwitcherController: WindowSwitcherController?
    private var settingsWindowController: SettingsWindowController?
    private var screenshotHistoryWindowController: ScreenshotHistoryWindowController?
    private var collageWindowController: CollageWindowController?
    private var longScreenshotEditorController: LongScreenshotEditorWindowController?
    private var screenshotMenuItems: [NSMenuItem] = []
    private var settingsMenuItem: NSMenuItem?
    private var clipboardMenuItem: NSMenuItem?
    private var scrollCaptureController: ScrollCaptureController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        preferences.appearanceMode.apply()
        installMainMenu()
        statusBarController = StatusBarController(
            openSettings: { [weak self] in self?.showSettings() },
            captureScreenshot: { [weak self] in self?.captureScreenshot() },
            showScreenshotHistory: { [weak self] in self?.showScreenshotHistory() },
            showCollage: { [weak self] in self?.openCollageWindow() },
            showClipboardHistory: { [weak self] in self?.showClipboardHistory() },
            canUseScreenshot: { [weak self] in
                guard let self else { return false }
                return moduleStateController.isEnabled(.screenshot)
            },
            canUseClipboard: { [weak self] in
                self?.moduleStateController.isEnabled(.clipboard) ?? false
            },
            isInteractionLocked: { [weak self] in
                self?.isScreenshotInteractionActive ?? false
            }
        )
        shortcutRuntime.start()
        if moduleStateController.isEnabled(.mouseGestures) {
            ensureMouseGestureController().start(requestPermission: false)
        }
        if moduleStateController.isEnabled(.clipboard) {
            if let clipboardMonitor = ensureClipboardMonitor() {
                clipboardMonitor.start()
            } else {
                moduleStateController.setRuntimeStatus(
                    .failed(clipboardLoadError ?? "剪贴板历史不可用。"),
                    for: .clipboard
                )
            }
        }
        if moduleStateController.isEnabled(.windowSwitcher) {
            ensureWindowSwitcherController().start(requestPermission: false)
        }
        if preferences.showSettingsOnLaunch || shortcutRuntime.hasStartupIssue {
            showSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcutRuntime.stop()
        mouseGestureController?.stop()
        windowSwitcherController?.stop()
        clipboardMonitor?.stop()
        screenshotTask?.cancel()
        screenshotTask = nil
        closeScreenshotWorkflowWindows(releaseControllers: true)
        clipboardPanelController?.close()
        clipboardPanelController = nil
        settingsWindowController?.close()
        settingsWindowController = nil
        longScreenshotPinnedImageManager.closeAll()
        pinnedImageManager.closeAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard moduleStateController.isEnabled(.windowSwitcher),
              windowSwitcherController != nil else {
            return
        }
        // Returning from System Settings advances to the next missing TCC
        // permission. Requesting them together can hide the later prompt.
        windowSwitcherController?.start(requestPermission: true)
    }

    @objc private func captureScreenshot() {
        guard moduleStateController.isEnabled(.screenshot), screenshotTask == nil else { return }
        if isScreenshotInteractionActive,
           screenshotOverlayController?.session.isActive != true {
            return
        }
        windowSwitcherController?.cancel()
        mouseGestureController?.cancelCurrentSession()
        let controller = ensureScreenshotOverlayController()
        screenshotTask = Task { [weak self] in
            guard let self else { return }
            defer { screenshotTask = nil }
            await controller.begin()
        }
    }

    @objc private func showSettings() {
        guard !isScreenshotInteractionActive else { return }
        ensureSettingsWindowController().present()
    }

    @objc private func showScreenshotHistory() {
        guard moduleStateController.isEnabled(.screenshot),
              !isScreenshotInteractionActive else { return }
        ensureScreenshotHistoryWindowController().present()
    }

    @objc private func openCollageWindow() {
        guard moduleStateController.isEnabled(.screenshot),
              !isScreenshotInteractionActive else { return }
        ensureCollageWindowController().present()
    }

    @objc private func showClipboardHistory() {
        guard moduleStateController.isEnabled(.clipboard),
              !isScreenshotInteractionActive else {
            return
        }
        guard let panelController = ensureClipboardPanelController() else {
            moduleStateController.setRuntimeStatus(
                .failed(clipboardLoadError ?? "剪贴板历史不可用。"),
                for: .clipboard
            )
            return
        }
        panelController.toggle()
    }

    private func showLongScreenshotEditor(
        image: CGImage,
        pointPixelScale: CGFloat,
        preferredFrame: CGRect?
    ) {
        mouseGestureController?.cancelCurrentSession()
        longScreenshotEditorController?.close()
        do {
            let controller = try LongScreenshotEditorWindowController(
                image: image,
                pointPixelScale: pointPixelScale,
                preferredFrame: preferredFrame,
                pinnedImageManager: longScreenshotPinnedImageManager,
                historyStore: screenshotHistoryStore,
                isHistoryEnabled: { [weak self] in
                    self?.preferences.screenshotHistoryEnabled ?? false
                }
            )
            controller.onClose = { [weak self] in
                self?.longScreenshotEditorController = nil
            }
            longScreenshotEditorController = controller
            controller.present()
        } catch {
            ScreenshotErrorPresenter.show(error)
        }
    }

    private func showCollage(adding image: CGImage) {
        guard moduleStateController.isEnabled(.screenshot),
              !isScreenshotInteractionActive else {
            return
        }
        ensureCollageWindowController().present(adding: image)
    }

    private func perform(_ action: ShortcutAction) {
        guard isActionAvailable(action) else { return }
        if isScreenshotInteractionActive {
            switch action {
            case .captureMainDisplay, .captureInteractive:
                captureScreenshot()
            case .openSettings, .screenshotHistory, .openCollage, .scrollCapture,
                 .clipboardHistory, .application:
                break
            }
            return
        }
        switch action {
        case .openSettings:
            showSettings()
        case .captureMainDisplay, .captureInteractive:
            captureScreenshot()
        case .screenshotHistory:
            showScreenshotHistory()
        case .openCollage:
            openCollageWindow()
        case .scrollCapture:
            captureScreenshot()
        case .clipboardHistory:
            showClipboardHistory()
        case .application(let target):
            Task { [weak self] in
                await self?.applicationShortcutHandler.trigger(target)
            }
        }
    }

    private var isScreenshotInteractionActive: Bool {
        screenshotOverlayController?.session.isActive == true
            || scrollCaptureController?.isActive == true
            || longScreenshotEditorController?.window?.isVisible == true
    }

    private func isActionAvailable(_ action: ShortcutAction) -> Bool {
        switch action {
        case .openSettings, .application:
            true
        case .captureMainDisplay, .captureInteractive, .screenshotHistory,
             .openCollage, .scrollCapture:
            moduleStateController.isEnabled(.screenshot)
        case .clipboardHistory:
            moduleStateController.isEnabled(.clipboard)
        }
    }

    private func applyLifecycleChange(module: NylaiModuleID, enabled: Bool) {
        switch module {
        case .screenshot where !enabled:
            screenshotTask?.cancel()
            screenshotTask = nil
            closeScreenshotWorkflowWindows(releaseControllers: true)
        case .mouseGestures:
            if enabled {
                ensureMouseGestureController().start(requestPermission: true)
            } else {
                mouseGestureController?.stop()
            }
        case .clipboard:
            if enabled {
                if let clipboardMonitor = ensureClipboardMonitor() {
                    clipboardMonitor.start()
                } else {
                    moduleStateController.setRuntimeStatus(
                        .failed(clipboardLoadError ?? "剪贴板历史不可用。"),
                        for: .clipboard
                    )
                }
            } else {
                clipboardPanelController?.close()
                clipboardPanelController = nil
                clipboardMonitor?.stop()
            }
        case .windowSwitcher:
            if enabled {
                ensureWindowSwitcherController().start(requestPermission: true)
            } else {
                windowSwitcherController?.stop()
            }
        case .screenshot, .globalShortcuts:
            break
        }
        if (module == .screenshot || module == .clipboard),
           moduleStateController.isEnabled(.mouseGestures) {
            mouseGestureController?.refreshActionAvailability()
        }
    }

    private func closeScreenshotWorkflowWindows(releaseControllers: Bool) {
        screenshotOverlayController?.close()
        scrollCaptureController?.close()
        screenshotHistoryWindowController?.close()
        collageWindowController?.close()
        longScreenshotEditorController?.close()
        pinnedImageManager.closeAll()
        longScreenshotPinnedImageManager.closeAll()
        if releaseControllers {
            screenshotOverlayController = nil
            scrollCaptureController = nil
            screenshotHistoryWindowController = nil
            collageWindowController = nil
            longScreenshotEditorController = nil
        }
    }

    private func ensureScreenshotOverlayController() -> ScreenshotOverlayController {
        if let screenshotOverlayController { return screenshotOverlayController }
        let controller = ScreenshotOverlayController(
            pinnedImageManager: pinnedImageManager,
            historyStore: screenshotHistoryStore,
            isHistoryEnabled: { [weak self] in
                self?.preferences.screenshotHistoryEnabled ?? false
            },
            startScrollCapture: { [weak self] request in
                self?.ensureScrollCaptureController().begin(with: request)
            }
        )
        screenshotOverlayController = controller
        return controller
    }

    private func ensureScrollCaptureController() -> ScrollCaptureController {
        if let scrollCaptureController { return scrollCaptureController }
        let controller = ScrollCaptureController(
            openEditor: { [weak self] image, scale, preferredFrame in
                self?.showLongScreenshotEditor(
                    image: image,
                    pointPixelScale: scale,
                    preferredFrame: preferredFrame
                )
            }
        )
        scrollCaptureController = controller
        return controller
    }

    private func ensureScreenshotHistoryWindowController() -> ScreenshotHistoryWindowController {
        if let screenshotHistoryWindowController { return screenshotHistoryWindowController }
        let controller = ScreenshotHistoryWindowController(
            store: screenshotHistoryStore,
            preferences: preferences,
            pinnedImageManager: pinnedImageManager,
            onAddToCollage: { [weak self] image in
                self?.showCollage(adding: image)
            }
        )
        screenshotHistoryWindowController = controller
        return controller
    }

    private func ensureCollageWindowController() -> CollageWindowController {
        if let collageWindowController { return collageWindowController }
        let controller = CollageWindowController(
            historyStore: screenshotHistoryStore,
            isHistoryEnabled: { [weak self] in
                self?.preferences.screenshotHistoryEnabled ?? false
            }
        )
        collageWindowController = controller
        return controller
    }

    private func ensureMouseGestureController() -> MouseGestureController {
        if let mouseGestureController { return mouseGestureController }
        let controller = MouseGestureController(
            performNylaiAction: { [weak self] action in
                self?.perform(action)
            },
            isNylaiActionAvailable: { [weak self] action in
                self?.isActionAvailable(action) ?? false
            },
            isInputSuppressed: { [weak self] in
                guard let self else { return true }
                return self.isScreenshotInteractionActive
                    || self.shortcutRuntime.isRecording
                    || NSApp.keyWindow?.firstResponder is ShortcutRecorderView
            }
        )
        controller.onRuntimeStatusChange = { [weak self] status, _ in
            self?.moduleStateController.setRuntimeStatus(status, for: .mouseGestures)
        }
        mouseGestureController = controller
        return controller
    }

    private func ensureWindowSwitcherController() -> WindowSwitcherController {
        if let windowSwitcherController { return windowSwitcherController }
        let controller = WindowSwitcherController(
            isInteractionSuppressed: { [weak self] in
                guard let self else { return true }
                return self.isScreenshotInteractionActive
                    || self.shortcutRuntime.isRecording
                    || NSApp.keyWindow?.firstResponder is ShortcutRecorderView
            }
        )
        controller.onRuntimeStatusChange = { [weak self] status in
            self?.moduleStateController.setRuntimeStatus(
                status,
                for: .windowSwitcher
            )
        }
        controller.onError = { error in
            NSSound.beep()
            let alert = NSAlert()
            alert.messageText = "无法切换窗口"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
        windowSwitcherController = controller
        return controller
    }

    private func ensureClipboardHistoryStore() -> ClipboardHistoryStore? {
        if clipboardLoadAttempted { return clipboardHistoryStore }
        clipboardLoadAttempted = true
        do {
            let store = try ClipboardHistoryStore()
            clipboardHistoryStore = store
            clipboardLoadError = nil
            return store
        } catch {
            clipboardHistoryStore = nil
            clipboardLoadError = error.localizedDescription
            return nil
        }
    }

    private func ensureClipboardMonitor() -> ClipboardMonitor? {
        if let clipboardMonitor { return clipboardMonitor }
        guard let store = ensureClipboardHistoryStore() else { return nil }
        let monitor = ClipboardMonitor(store: store)
        monitor.onRuntimeStatusChange = { [weak self] status, _ in
            self?.moduleStateController.setRuntimeStatus(status, for: .clipboard)
        }
        clipboardMonitor = monitor
        return monitor
    }

    private func ensureClipboardPanelController() -> ClipboardPanelController? {
        if let clipboardPanelController { return clipboardPanelController }
        guard let store = ensureClipboardHistoryStore() else { return nil }
        let controller = ClipboardPanelController(store: store)
        clipboardPanelController = controller
        return controller
    }

    private func ensureSettingsWindowController() -> SettingsWindowController {
        if let settingsWindowController { return settingsWindowController }
        let controller = SettingsWindowController(
            preferences: preferences,
            shortcutRuntime: shortcutRuntime,
            moduleStateController: moduleStateController,
            mouseGestureController: ensureMouseGestureController(),
            clipboardHistoryStore: ensureClipboardHistoryStore(),
            clipboardMonitor: ensureClipboardMonitor(),
            clipboardLoadError: clipboardLoadError
        )
        settingsWindowController = controller
        return controller
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: AppName.current)
        applicationMenu.delegate = self
        applicationMenu.addItem(
            withTitle: "关于 \(AppName.current)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        let interactiveItem = applicationMenu.addItem(withTitle: "截图…", action: #selector(captureScreenshot), keyEquivalent: "")
        interactiveItem.target = self
        let historyItem = applicationMenu.addItem(
            withTitle: "最近截图…",
            action: #selector(showScreenshotHistory),
            keyEquivalent: ""
        )
        historyItem.target = self
        let collageItem = applicationMenu.addItem(
            withTitle: "自由拼图…",
            action: #selector(openCollageWindow),
            keyEquivalent: ""
        )
        collageItem.target = self
        let clipboardItem = applicationMenu.addItem(
            withTitle: "剪贴板历史…",
            action: #selector(showClipboardHistory),
            keyEquivalent: ""
        )
        clipboardItem.target = self
        let settingsItem = applicationMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsMenuItem = settingsItem
        screenshotMenuItems = [interactiveItem, historyItem, collageItem]
        clipboardMenuItem = clipboardItem
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            withTitle: "退出 \(AppName.current)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let undoItem = editMenu.addItem(
            withTitle: "撤销",
            action: #selector(ScreenshotOverlayView.undoAction(_:)),
            keyEquivalent: "z"
        )
        undoItem.keyEquivalentModifierMask = [.command]
        let redoItem = editMenu.addItem(
            withTitle: "重做",
            action: #selector(ScreenshotOverlayView.redoAction(_:)),
            keyEquivalent: "z"
        )
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        let screenshotAvailable = moduleStateController.isEnabled(.screenshot)
            && !isScreenshotInteractionActive
        screenshotMenuItems.forEach { $0.isEnabled = screenshotAvailable }
        clipboardMenuItem?.isEnabled = moduleStateController.isEnabled(.clipboard)
            && !isScreenshotInteractionActive
        settingsMenuItem?.isEnabled = !isScreenshotInteractionActive
    }
}
