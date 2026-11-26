import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    init(
        preferences: AppPreferences,
        shortcutRuntime: ShortcutBindingRuntime,
        moduleStateController: ModuleStateController,
        mouseGestureController: MouseGestureController,
        clipboardHistoryStore: ClipboardHistoryStore?,
        clipboardMonitor: ClipboardMonitor?,
        clipboardLoadError: String?,
        openShortcutConflictChecker: @escaping () -> Void
    ) {
        let hostingController = NSHostingController(
            rootView: SettingsView(
                preferences: preferences,
                shortcutRuntime: shortcutRuntime,
                moduleStateController: moduleStateController,
                mouseGestureController: mouseGestureController,
                clipboardHistoryStore: clipboardHistoryStore,
                clipboardMonitor: clipboardMonitor,
                clipboardLoadError: clipboardLoadError,
                openShortcutConflictChecker: openShortcutConflictChecker
            )
        )
        hostingController.sizingOptions = []
        let window = NSWindow(contentViewController: hostingController)
        window.title = ""
        window.identifier = NSUserInterfaceItemIdentifier("nylai.settings")
        window.styleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable,
            .fullSizeContentView
        ]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = NylaiTheme.panelBackground()
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentMinSize = NSSize(width: 760, height: 540)
        window.setContentSize(NSSize(width: 760, height: 580))
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从归档创建设置窗口")
    }

    func present() {
        guard let window else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
