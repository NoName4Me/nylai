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
    private var shortcutConflictCheckerController: ShortcutConflictCheckerWindowController?
    private var screenshotHistoryWindowController: ScreenshotHistoryWindowController?
    private var collageWindowController: CollageWindowController?
    private var longScreenshotEditorController: LongScreenshotEditorWindowController?
    private var screenshotMenuItems: [NSMenuItem] = []
    private var settingsMenuItem: NSMenuItem?
    private var clipboardMenuItem: NSMenuItem?
    private var boardMenuItems: [NSMenuItem] = []
    private var boardController: BoardWindowController?
    private var launcherController: LauncherWindowController?
    private var launcherMenuItem: NSMenuItem?
    private var scrollCaptureController: ScrollCaptureController?
    private var didStartWindowSwitcherAfterLaunch = false
    private var screenshotReopenGuardTask: Task<Void, Never>?
    private var suppressesNextReopen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        refreshFinderEnhancementRuntime()
        preferences.appearanceMode.apply()
        installMainMenu()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageDidChange),
            name: .nylaiLanguageDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(self, selector: #selector(openBoard), name: .nylaiOpenBoard, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(openLauncher), name: .nylaiOpenLauncher, object: nil)
        statusBarController = StatusBarController(
            preferences: preferences,
            openSettings: { [weak self] in self?.showSettings() },
            openBoard: { [weak self] in self?.openBoard() },
            quickCapture: { [weak self] in self?.quickCapture() },
            openLauncher: { [weak self] in self?.openLauncher() },
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
                _ = ensureClipboardPanelController()
            } else {
                moduleStateController.setRuntimeStatus(
                    .failed(clipboardLoadError ?? L10n.shared.string("剪贴板历史不可用。")),
                    for: .clipboard
                )
            }
        }
        if moduleStateController.isEnabled(.windowSwitcher) {
            ensureWindowSwitcherController().start(requestPermission: false)
        }
        let isDefaultLaunch = (notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? NSNumber)?.boolValue ?? true
        if isDefaultLaunch && (preferences.showSettingsOnLaunch || shortcutRuntime.hasStartupIssue) {
            showSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        FinderRightClickTarget.stopObserving()
        statusBarController?.shutdown()
        launcherController?.close()
        boardController?.close()
        shortcutRuntime.stop()
        mouseGestureController?.stop()
        windowSwitcherController?.stop()
        clipboardMonitor?.stop()
        screenshotTask?.cancel()
        screenshotTask = nil
        screenshotReopenGuardTask?.cancel()
        screenshotReopenGuardTask = nil
        closeScreenshotWorkflowWindows(releaseControllers: true)
        clipboardPanelController?.close()
        clipboardPanelController = nil
        settingsWindowController?.close()
        settingsWindowController = nil
        shortcutConflictCheckerController?.close()
        shortcutConflictCheckerController = nil
        longScreenshotPinnedImageManager.closeAll()
        pinnedImageManager.closeAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !isScreenshotInteractionActive,
              moduleStateController.isEnabled(.finderEnhancements) else { return }
        let disabledActions = FinderEnhancementAvailability.disabledActions()
        for url in urls {
            if let request = FinderEnhancementRequest(url: url),
               !disabledActions.contains(request.action.rawValue) {
                FinderEnhancementAction.perform(request)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !isScreenshotInteractionActive else { return false }
        if suppressesNextReopen {
            suppressesNextReopen = false
            return false
        }
        showSettings()
        return true
    }

    @objc private func languageDidChange() {
        installMainMenu()
        statusBarController?.refreshLocalization()
        screenshotHistoryWindowController?.refreshLocalization()
        collageWindowController?.refreshLocalization()
        boardController?.refreshLocalization()
        launcherController?.close()
        clipboardPanelController?.refreshLocalization()
        mouseGestureController?.refreshLocalization()
        windowSwitcherController?.refreshLocalization()
        clipboardMonitor?.refreshLocalization()
        shortcutConflictCheckerController?.refreshLocalization()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshFinderEnhancementRuntime()
        guard !didStartWindowSwitcherAfterLaunch,
              moduleStateController.isEnabled(.windowSwitcher),
              windowSwitcherController != nil else {
            return
        }
        didStartWindowSwitcherAfterLaunch = true
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
        statusBarController?.closeMonitor()
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

    private func showShortcutConflictChecker() {
        guard !isScreenshotInteractionActive else { return }
        ensureShortcutConflictCheckerController().present(
            relativeTo: settingsWindowController?.window
        )
    }

    @objc private func showScreenshotHistory() {
        guard moduleStateController.isEnabled(.screenshot),
              preferences.screenshotHistoryAvailable,
              !isScreenshotInteractionActive else { return }
        ensureScreenshotHistoryWindowController().present()
    }

    @objc private func openCollageWindow() {
        guard moduleStateController.isEnabled(.screenshot),
              preferences.screenshotCollageEnabled,
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
                .failed(clipboardLoadError ?? L10n.shared.string("剪贴板历史不可用。")),
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
                    self.map { $0.preferences.screenshotHistoryAvailable && $0.preferences.screenshotHistoryEnabled } ?? false
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
              preferences.screenshotCollageEnabled,
              !isScreenshotInteractionActive else {
            return
        }
        ensureCollageWindowController().present(adding: image)
    }

    private func ensureBoardController() -> BoardWindowController {
        if let boardController { return boardController }
        let controller = BoardWindowController()
        boardController = controller
        if let error = controller.store.loadError {
            moduleStateController.setRuntimeStatus(.failed(error), for: .board)
        }
        return controller
    }

    @objc private func openBoard() {
        guard moduleStateController.isEnabled(.board), !isScreenshotInteractionActive else { return }
        ensureBoardController().present()
    }

    @objc private func quickCapture() {
        guard moduleStateController.isEnabled(.board), !isScreenshotInteractionActive else { return }
        ensureBoardController().quickCapture()
    }

    private func ensureLauncherController() -> LauncherWindowController {
        if let launcherController { return launcherController }
        let config = LauncherPreferences()
        let sources = LauncherSources(preferences: config,
            isEnabled: { [weak self] module in self?.moduleStateController.isEnabled(module) ?? false },
            isActionAvailable: { [weak self] action in self?.isActionAvailable(action) ?? false },
            perform: { [weak self] action in self?.perform(action) },
            clipboard: { [weak self] in
                guard let self, self.preferences.clipboardEnabled else { return nil }
                return self.ensureClipboardHistoryStore()
            },
            board: { [weak self] in
                guard let self, self.preferences.boardEnabled else { return nil }
                return self.ensureBoardController()
            },
            screenshots: screenshotHistoryStore,
            pinImage: { [weak self] image in self?.pinnedImageManager.pin(image) }
        )
        let controller = LauncherWindowController(preferences: config, sources: sources)
        launcherController = controller
        if let error = config.loadError { moduleStateController.setRuntimeStatus(.failed(error), for: .launcher) }
        return controller
    }

    @objc private func openLauncher() {
        guard moduleStateController.isEnabled(.launcher), !isScreenshotInteractionActive else { return }
        ensureLauncherController().toggle()
    }

    private func perform(_ action: ShortcutAction) {
        guard isActionAvailable(action) else { return }
        if isScreenshotInteractionActive {
            switch action {
            case .captureMainDisplay, .captureInteractive:
                captureScreenshot()
            case .openSettings, .screenshotHistory, .openCollage, .scrollCapture,
                 .clipboardHistory, .openBoard, .quickCapture, .openLauncher, .application:
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
        case .openBoard:
            openBoard()
        case .quickCapture:
            quickCapture()
        case .openLauncher:
            openLauncher()
        case .application(let target):
            Task { [weak self] in
                await self?.applicationShortcutHandler.trigger(target)
            }
        }
    }

    private var isScreenshotInteractionActive: Bool {
        screenshotOverlayController?.isCapturing == true
            || screenshotOverlayController?.session.isActive == true
            || scrollCaptureController?.isActive == true
            || longScreenshotEditorController?.window?.isVisible == true
    }

    private func isActionAvailable(_ action: ShortcutAction) -> Bool {
        switch action {
        case .openSettings, .application:
            true
        case .screenshotHistory:
            moduleStateController.isEnabled(.screenshot) && preferences.screenshotHistoryAvailable
        case .openCollage:
            moduleStateController.isEnabled(.screenshot) && preferences.screenshotCollageEnabled
        case .captureMainDisplay, .captureInteractive, .scrollCapture:
            moduleStateController.isEnabled(.screenshot)
        case .clipboardHistory:
            moduleStateController.isEnabled(.clipboard)
        case .openBoard, .quickCapture:
            moduleStateController.isEnabled(.board)
        case .openLauncher:
            moduleStateController.isEnabled(.launcher)
        }
    }

    private func applyLifecycleChange(module: NylaiModuleID, enabled: Bool) {
        launcherController?.close()
        switch module {
        case .screenshot where !enabled:
            screenshotTask?.cancel()
            screenshotTask = nil
            closeScreenshotWorkflowWindows(releaseControllers: true)
        case .finderEnhancements:
            refreshFinderEnhancementRuntime()
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
                    _ = ensureClipboardPanelController()
                } else {
                    moduleStateController.setRuntimeStatus(
                        .failed(clipboardLoadError ?? L10n.shared.string("剪贴板历史不可用。")),
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
        case .launcher:
            if !enabled { launcherController = nil }
        case .board:
            if !enabled { boardController?.close(); boardController = nil }
            configureClipboardBoardAction()
        case .systemMonitor:
            statusBarController?.closeMonitor()
        case .screenshot, .globalShortcuts:
            break
        }
        if (module == .screenshot || module == .clipboard || module == .board || module == .launcher),
           moduleStateController.isEnabled(.mouseGestures) {
            mouseGestureController?.refreshActionAvailability()
        }
    }

    private func refreshFinderEnhancementRuntime() {
        let enabled = moduleStateController.isEnabled(.finderEnhancements)
        FinderEnhancementAvailability.setEnabled(enabled)
        if enabled {
            FinderRightClickTarget.startObserving()
        } else {
            FinderRightClickTarget.stopObserving()
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
                self.map { $0.preferences.screenshotHistoryAvailable && $0.preferences.screenshotHistoryEnabled } ?? false
            },
            startScrollCapture: { [weak self] request in
                self?.ensureScrollCaptureController().begin(with: request)
            }
        )
        controller.canSendToBoard = { [weak self] in self?.preferences.boardEnabled == true }
        controller.sendToBoard = { [weak self] image in
            guard let self, self.preferences.boardEnabled else { return false }
            return self.ensureBoardController().add(.image(image))
        }
        controller.onOutputSucceeded = { [weak self] in
            self?.guardAgainstReopenAfterScreenshot()
        }
        screenshotOverlayController = controller
        return controller
    }

    private func guardAgainstReopenAfterScreenshot() {
        suppressesNextReopen = true
        screenshotReopenGuardTask?.cancel()
        screenshotReopenGuardTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.suppressesNextReopen = false
            self?.screenshotReopenGuardTask = nil
        }
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
            },
            onAddToBoard: { [weak self] image in
                guard let self, self.preferences.boardEnabled else { return }
                self.ensureBoardController().chooseDestination(for: [.image(image)])
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
                self.map { $0.preferences.screenshotHistoryAvailable && $0.preferences.screenshotHistoryEnabled } ?? false
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
            alert.messageText = L10n.shared.string("无法切换窗口")
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
        configureClipboardBoardAction()
        return controller
    }

    private func configureClipboardBoardAction() {
        clipboardPanelController?.boardAction = preferences.boardEnabled ? { [weak self] contents in
            guard let self, self.preferences.boardEnabled else { return }
            self.clipboardPanelController?.close()
            self.ensureBoardController().chooseDestination(for: contents)
        } : nil
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
            clipboardLoadError: clipboardLoadError,
            openShortcutConflictChecker: { [weak self] in
                self?.showShortcutConflictChecker()
            }
        )
        settingsWindowController = controller
        return controller
    }

    private func ensureShortcutConflictCheckerController()
        -> ShortcutConflictCheckerWindowController {
        if let shortcutConflictCheckerController {
            return shortcutConflictCheckerController
        }
        let controller = ShortcutConflictCheckerWindowController(
            beginInterception: { [weak self] in
                guard let self else {
                    throw ShortcutOperationError.configurationUnavailable
                }
                try self.shortcutRuntime.beginTransientRecording()
            },
            endInterception: { [weak self] in
                self?.shortcutRuntime.endTransientRecording()
            },
            ownShortcuts: { [weak self] in
                self?.ownShortcutMatches() ?? []
            }
        )
        shortcutConflictCheckerController = controller
        return controller
    }

    private func ownShortcutMatches() -> [ShortcutConflictMatch] {
        guard let configuration = shortcutRuntime.configuration,
              configuration.isEnabled else {
            return []
        }
        let applicationIdentifier = Bundle.main.bundleIdentifier
            ?? "com.noname4me.nylai"
        return configuration.bindings.compactMap { binding in
            guard binding.isEnabled,
                  let shortcut = binding.shortcut,
                  shortcutRuntime.status(for: binding.id) == .registered else {
                return nil
            }
            let title = ShortcutBindingRuntime.title(for: binding.action)
            return ShortcutConflictMatch(
                id: "\(applicationIdentifier)|\(binding.id.rawValue)|\(shortcut.keyCode)|\(shortcut.modifiers.rawValue)",
                applicationIdentifier: applicationIdentifier,
                applicationName: AppName.current,
                bundleIdentifier: Bundle.main.bundleIdentifier,
                applicationURL: Bundle.main.bundleURL,
                menuPath: [title],
                shortcut: shortcut
            )
        }
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem(
            title: AppName.current,
            action: nil,
            keyEquivalent: ""
        )
        let applicationMenu = NSMenu(title: AppName.current)
        applicationMenu.delegate = self
        applicationMenu.addItem(
            withTitle: L10n.shared.string("关于 %@", AppName.current),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        let interactiveItem = applicationMenu.addItem(
            withTitle: L10n.shared.string("截图…"),
            action: #selector(captureScreenshot),
            keyEquivalent: ""
        )
        interactiveItem.target = self
        let historyItem = applicationMenu.addItem(
            withTitle: L10n.shared.string("最近截图…"),
            action: #selector(showScreenshotHistory),
            keyEquivalent: ""
        )
        historyItem.target = self
        let collageItem = applicationMenu.addItem(
            withTitle: L10n.shared.string("自由拼图…"),
            action: #selector(openCollageWindow),
            keyEquivalent: ""
        )
        collageItem.target = self
        let clipboardItem = applicationMenu.addItem(
            withTitle: L10n.shared.string("剪贴板历史…"),
            action: #selector(showClipboardHistory),
            keyEquivalent: ""
        )
        clipboardItem.target = self
        let boardItem = applicationMenu.addItem(withTitle: L10n.shared.string("无限画布…"), action: #selector(openBoard), keyEquivalent: "")
        boardItem.target = self
        let captureItem = applicationMenu.addItem(withTitle: L10n.shared.string("快速记录…"), action: #selector(quickCapture), keyEquivalent: "")
        captureItem.target = self
        boardMenuItems = [boardItem, captureItem]
        let launcher = applicationMenu.addItem(withTitle: L10n.shared.string("Launcher…"), action: #selector(openLauncher), keyEquivalent: "")
        launcher.target = self
        launcherMenuItem = launcher
        let settingsItem = applicationMenu.addItem(
            withTitle: L10n.shared.string("设置…"),
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        settingsMenuItem = settingsItem
        screenshotMenuItems = [interactiveItem, historyItem, collageItem]
        clipboardMenuItem = clipboardItem
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            withTitle: L10n.shared.string("退出 %@", AppName.current),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L10n.shared.string("编辑"))
        editMenu.addItem(
            withTitle: L10n.shared.string("剪切"),
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        editMenu.addItem(
            withTitle: L10n.shared.string("复制"),
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        editMenu.addItem(
            withTitle: L10n.shared.string("粘贴"),
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        editMenu.addItem(
            withTitle: L10n.shared.string("全选"),
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        editMenu.addItem(.separator())
        let undoItem = editMenu.addItem(
            withTitle: L10n.shared.string("撤销"),
            action: #selector(ScreenshotOverlayView.undoAction(_:)),
            keyEquivalent: "z"
        )
        undoItem.keyEquivalentModifierMask = [.command]
        let redoItem = editMenu.addItem(
            withTitle: L10n.shared.string("重做"),
            action: #selector(ScreenshotOverlayView.redoAction(_:)),
            keyEquivalent: "z"
        )
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
        NSApp.mainMenu?.items.first?.title = AppName.current
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        let screenshotAvailable = moduleStateController.isEnabled(.screenshot)
            && !isScreenshotInteractionActive
        for item in screenshotMenuItems {
            if item.action == #selector(showScreenshotHistory) {
                item.isHidden = !preferences.screenshotHistoryAvailable
            } else if item.action == #selector(openCollageWindow) {
                item.isHidden = !preferences.screenshotCollageEnabled
            }
            item.isEnabled = screenshotAvailable
        }
        clipboardMenuItem?.isEnabled = moduleStateController.isEnabled(.clipboard)
            && !isScreenshotInteractionActive
        for item in boardMenuItems {
            item.isHidden = !moduleStateController.isEnabled(.board)
            item.isEnabled = !isScreenshotInteractionActive
        }
        launcherMenuItem?.isHidden = !moduleStateController.isEnabled(.launcher)
        launcherMenuItem?.isEnabled = !isScreenshotInteractionActive
        settingsMenuItem?.isEnabled = !isScreenshotInteractionActive
    }
}


extension Notification.Name {
    static let nylaiOpenBoard = Notification.Name("nylaiOpenBoard")
    static let nylaiOpenLauncher = Notification.Name("nylaiOpenLauncher")
}
