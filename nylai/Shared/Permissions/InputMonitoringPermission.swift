import AppKit
import CoreGraphics

@MainActor
enum InputMonitoringPermission {
    private static var hasPromptedInThisLaunch = false

    static var isGranted: Bool {
        CGPreflightListenEventAccess()
    }

    @discardableResult
    static func requestIfNeeded() -> Bool {
        if isGranted {
            return true
        }
        guard !hasPromptedInThisLaunch else {
            return false
        }
        hasPromptedInThisLaunch = true
        return CGRequestListenEventAccess()
    }

    static func resetPromptStateForTesting() {
        hasPromptedInThisLaunch = false
    }

    @discardableResult
    static func openSystemSettings() -> Bool {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        ) else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }
}
