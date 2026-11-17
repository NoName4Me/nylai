import AppKit
import ApplicationServices

struct ApplicationActivationTarget {
    let processIdentifier: pid_t
    let bundleURL: URL?
    let activate: @MainActor (NSApplication.ActivationOptions) -> Bool

    init(
        processIdentifier: pid_t,
        bundleURL: URL?,
        activate: @escaping @MainActor (NSApplication.ActivationOptions) -> Bool
    ) {
        self.processIdentifier = processIdentifier
        self.bundleURL = bundleURL
        self.activate = activate
    }

    init(_ application: NSRunningApplication) {
        self.init(
            processIdentifier: application.processIdentifier,
            bundleURL: application.bundleURL,
            activate: { application.activate(options: $0) }
        )
    }
}

struct ApplicationWindowHandle {
    let unminimize: @MainActor () -> Bool
    let focusAndRaise: @MainActor () -> Bool
}

enum ApplicationWindowState {
    case none
    case visible
    case minimized(ApplicationWindowHandle)
}

enum ApplicationActivationOutcome: Equatable {
    case broughtToFront
    case restoredWindow
    case openedWindow
}

/// 统一“激活应用”行为，使快捷键、窗口切换和截图恢复在无窗口、
/// 最小化或未运行时都表现得像点击程序坞图标。
@MainActor
final class ApplicationActivationService {
    private let openApplication: @MainActor (URL) async throws -> Void
    private let windowState: @MainActor (pid_t) -> ApplicationWindowState

    init(
        openApplication: @escaping @MainActor (URL) async throws -> Void = { url in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        },
        windowState: @escaping @MainActor (pid_t) -> ApplicationWindowState = {
            ApplicationActivationService.preferredWindowState(for: $0)
        }
    ) {
        self.openApplication = openApplication
        self.windowState = windowState
    }

    /// 激活一个已经运行的应用。若它没有可见窗口或只有最小化窗口，
    /// 重新打开应用包，让系统执行与点击程序坞图标相同的开窗／恢复动作。
    @discardableResult
    func activate(_ target: ApplicationActivationTarget) async throws -> ApplicationActivationOutcome {
        guard target.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return .broughtToFront
        }

        switch state(for: target.processIdentifier) {
        case .visible:
            try activate(target: target)
            return .broughtToFront
        case .minimized(let window):
            guard window.unminimize(), target.activate([.activateAllWindows]) else {
                try await openApplicationOrActivate(target)
                return .openedWindow
            }
            guard window.focusAndRaise() else {
                throw ApplicationActivationError.activationFailed
            }
            return .restoredWindow
        case .none:
            try await openApplicationOrActivate(target)
            return .openedWindow
        }
    }

    /// 仅将应用带到前台，不额外创建窗口；用于截图、滚动采集等临时交互结束。
    func bringToFront(_ target: ApplicationActivationTarget) throws {
        guard target.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }
        guard target.activate([.activateAllWindows]) else {
            throw ApplicationActivationError.activationFailed
        }
    }

    func hasVisibleWindow(processIdentifier: pid_t) -> Bool {
        if case .visible = state(for: processIdentifier) {
            return true
        }
        return false
    }

    /// 激活指定窗口。窗口切换拿到明确窗口 ID 时使用，避免误选同应用的其他窗口。
    func activate(
        window: AXUIElement,
        target: ApplicationActivationTarget,
        restoresMinimizedWindow: Bool
    ) throws {
        if restoresMinimizedWindow {
            guard Self.unminimize(window) else {
                throw ApplicationActivationError.activationFailed
            }
        }
        try activate(target: target)
        guard restoresMinimizedWindow else { return }
        guard Self.focusAndRaise(window) else {
            throw ApplicationActivationError.activationFailed
        }
    }

    private func activate(target: ApplicationActivationTarget) throws {
        guard target.activate([.activateAllWindows]) else {
            throw ApplicationActivationError.activationFailed
        }
    }

    private func openApplicationOrActivate(
        _ target: ApplicationActivationTarget
    ) async throws {
        if let url = target.bundleURL {
            try await openApplication(url)
        } else {
            try activate(target: target)
        }
    }

    private static func preferredWindowState(
        for processIdentifier: pid_t
    ) -> ApplicationWindowState {
        if AXIsProcessTrusted() {
            let element = AXUIElementCreateApplication(processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.5)
            let windows = accessibilityWindows(of: element)
            if windows.contains(where: { !isMinimized($0) }) {
                return .visible
            }
            if let minimized = windows.first {
                return .minimized(ApplicationWindowHandle(
                    unminimize: { unminimize(minimized) },
                    focusAndRaise: { focusAndRaise(minimized) }
                ))
            }
        }
        // 未获辅助功能权限时仍可通过 CGWindowList 判断是否存在可见窗口，
        // 避免把“有窗口”误判成无窗口并额外新建一个。
        if hasOnScreenWindow(processIdentifier: processIdentifier) {
            return .visible
        }
        return .none
    }

    private func state(for processIdentifier: pid_t) -> ApplicationWindowState {
        windowState(processIdentifier)
    }

    private static func unminimize(_ window: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(
            window,
            kAXMinimizedAttribute as CFString,
            kCFBooleanFalse
        ) == .success
    }

    private static func focusAndRaise(_ window: AXUIElement) -> Bool {
        guard AXUIElementSetAttributeValue(
            window,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        ) == .success else {
            return false
        }
        guard AXUIElementSetAttributeValue(
            window,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
        ) == .success else {
            return false
        }
        return AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
    }

    private static func accessibilityWindows(of element: AXUIElement) -> [AXUIElement] {
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXWindowsAttribute as CFString,
            &rawWindows
        ) == .success,
        let windows = rawWindows as? [AXUIElement] else {
            return []
        }
        return windows.filter { window in
            var rawRole: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                window,
                kAXRoleAttribute as CFString,
                &rawRole
            ) == .success,
            let role = rawRole as? String else {
                return false
            }
            return role == kAXWindowRole as String
        }
    }

    private static func hasOnScreenWindow(processIdentifier: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }
        return windows.contains { info in
            guard let owner = info[kCGWindowOwnerPID as String] as? NSNumber,
                  owner.int32Value == processIdentifier,
                  let layer = info[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 0,
                  let alpha = info[kCGWindowAlpha as String] as? NSNumber,
                  alpha.doubleValue > 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue else {
                return false
            }
            return width > 1 && height > 1
        }
    }

    private static func isMinimized(_ window: AXUIElement) -> Bool {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXMinimizedAttribute as CFString,
            &rawValue
        ) == .success,
        let value = rawValue as? NSNumber else {
            return false
        }
        return value.boolValue
    }
}

enum ApplicationActivationError: LocalizedError, Equatable {
    case activationFailed

    var errorDescription: String? {
        switch self {
        case .activationFailed:
            L10n.shared.string("无法激活目标应用，请重试。")
        }
    }
}
