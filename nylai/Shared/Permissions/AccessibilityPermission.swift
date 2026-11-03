import AppKit
import ApplicationServices

@MainActor
enum AccessibilityPermission {
    private static var hasPromptedInThisLaunch = false

    static var isGranted: Bool {
        AXIsProcessTrusted()
    }

    // A denied app can trigger the same system prompt on every check unless
    // repeated requests within one launch are suppressed.
    @discardableResult
    static func requestIfNeeded() -> Bool {
        requestIfNeeded(isGranted: { isGranted }, prompt: performSystemPrompt)
    }

    static func requestIfNeeded(
        isGranted: () -> Bool,
        prompt: () -> Bool
    ) -> Bool {
        if isGranted() {
            return true
        }
        guard !hasPromptedInThisLaunch else {
            return false
        }
        hasPromptedInThisLaunch = true
        return prompt()
    }

    static func resetPromptStateForTesting() {
        hasPromptedInThisLaunch = false
    }

    private static func performSystemPrompt() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    static func openSystemSettings() -> Bool {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }
}
