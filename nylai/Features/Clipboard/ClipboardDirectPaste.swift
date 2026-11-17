import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
protocol ClipboardPasteTarget: AnyObject {
    var isTerminated: Bool { get }
    var isActive: Bool { get }
    var bundleIdentifier: String? { get }
    var processIdentifier: pid_t { get }

    @discardableResult
    func activate(options: NSApplication.ActivationOptions) -> Bool
}

extension NSRunningApplication: ClipboardPasteTarget {}

struct ClipboardFrontmostApplication: Equatable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
}

struct ClipboardFocusSnapshot {
    let focusedElement: AXUIElement
    let owningWindow: AXUIElement
}

@MainActor
enum ClipboardFocusedElementCapture {
    static func capture(processIdentifier: pid_t?) -> ClipboardFocusSnapshot? {
        guard AccessibilityPermission.isGranted,
              let processIdentifier,
              processIdentifier > 0 else {
            return nil
        }
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var rawElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &rawElement
        ) == .success,
        let element = rawElement,
        let focused = axElement(from: element) else {
            return nil
        }
        var elementPID: pid_t = 0
        guard AXUIElementGetPid(focused, &elementPID) == .success,
              elementPID == processIdentifier else {
            return nil
        }
        guard let owningWindow = owningWindow(of: focused),
              Self.processIdentifier(of: owningWindow) == processIdentifier else {
            return nil
        }
        return ClipboardFocusSnapshot(
            focusedElement: focused,
            owningWindow: owningWindow
        )
    }

    static func restore(
        _ snapshot: ClipboardFocusSnapshot,
        processIdentifier targetProcessIdentifier: pid_t
    ) -> Bool {
        guard AccessibilityPermission.isGranted,
              Self.processIdentifier(of: snapshot.focusedElement) == targetProcessIdentifier,
              Self.processIdentifier(of: snapshot.owningWindow) == targetProcessIdentifier,
              role(of: snapshot.owningWindow) == kAXWindowRole,
              belongsToWindow(snapshot.focusedElement, window: snapshot.owningWindow) else {
            return false
        }
        let application = AXUIElementCreateApplication(targetProcessIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.5)
        if applicationFocusedElement(application) == snapshot.focusedElement,
           applicationWindowIsCurrent(application, window: snapshot.owningWindow) {
            return true
        }
        if !applicationWindowIsCurrent(application, window: snapshot.owningWindow) {
            _ = AXUIElementPerformAction(
                snapshot.owningWindow,
                kAXRaiseAction as CFString
            )
            _ = AXUIElementSetAttributeValue(
                snapshot.owningWindow,
                kAXMainAttribute as CFString,
                kCFBooleanTrue
            )
            _ = AXUIElementSetAttributeValue(
                snapshot.owningWindow,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
        }
        _ = AXUIElementSetAttributeValue(
            snapshot.focusedElement,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        return applicationFocusedElement(application) == snapshot.focusedElement
    }

    private static func applicationFocusedElement(
        _ application: AXUIElement
    ) -> AXUIElement? {
        var rawFocused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &rawFocused
        ) == .success,
        let rawFocused else {
            return nil
        }
        return axElement(from: rawFocused)
    }

    private static func applicationWindowIsCurrent(
        _ application: AXUIElement,
        window: AXUIElement
    ) -> Bool {
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var rawWindow: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                application,
                attribute as CFString,
                &rawWindow
            ) == .success,
            let rawWindow,
            let candidate = axElement(from: rawWindow) else {
                continue
            }
            if CFEqual(candidate, window) {
                return true
            }
        }
        return false
    }

    private static func owningWindow(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<64 {
            guard let candidate = current else { return nil }
            if role(of: candidate) == kAXWindowRole {
                return candidate
            }
            var rawParent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                candidate,
                kAXParentAttribute as CFString,
                &rawParent
            ) == .success,
            let rawParent,
            let parent = axElement(from: rawParent) else {
                return nil
            }
            current = parent
        }
        return nil
    }

    private static func belongsToWindow(
        _ element: AXUIElement,
        window: AXUIElement
    ) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<64 {
            guard let candidate = current else { return false }
            if CFEqual(candidate, window) {
                return true
            }
            var rawParent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                candidate,
                kAXParentAttribute as CFString,
                &rawParent
            ) == .success,
            let rawParent,
            let parent = axElement(from: rawParent) else {
                return false
            }
            current = parent
        }
        return false
    }

    private static func processIdentifier(of element: AXUIElement) -> pid_t? {
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success else {
            return nil
        }
        return processIdentifier
    }

    private static func role(of element: AXUIElement) -> String? {
        var rawRole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &rawRole
        ) == .success else {
            return nil
        }
        return rawRole as? String
    }

    private static func axElement(from value: CFTypeRef) -> AXUIElement? {
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

}

@MainActor
protocol ClipboardDirectPasting {
    func pasteAfterActivating(
        target: any ClipboardPasteTarget,
        expectedBundleIdentifier: String,
        expectedChangeCount: Int,
        pasteboard: any ClipboardPasteboardAccessing,
        focusSnapshot: ClipboardFocusSnapshot?
    ) async -> Result<Void, Error>
}

@MainActor
final class SystemClipboardDirectPaster: ClipboardDirectPasting {
    private let shortcutSender: any GestureShortcutSending
    private let frontmostApplication: @MainActor () -> ClipboardFrontmostApplication?
    private let activationDelay: Duration
    private let requestEventAccess: @MainActor () -> Void
    private let restoreFocusedElement: @MainActor (ClipboardFocusSnapshot, pid_t) -> Bool
    private let now: @MainActor () -> ContinuousClock.Instant
    private let sleepForActivation: @MainActor (Duration) async -> Void

    init(
        shortcutSender: any GestureShortcutSending = CGEventGestureShortcutSender(),
        frontmostApplication: @escaping @MainActor () -> ClipboardFrontmostApplication? = {
            NSWorkspace.shared.frontmostApplication.map {
                ClipboardFrontmostApplication(
                    processIdentifier: $0.processIdentifier,
                    bundleIdentifier: $0.bundleIdentifier
                )
            }
        },
        activationDelay: Duration = .milliseconds(600),
        requestEventAccess: @escaping @MainActor () -> Void = {
            _ = CGRequestPostEventAccess()
        },
        restoreFocusedElement: @escaping @MainActor (ClipboardFocusSnapshot, pid_t) -> Bool = {
            ClipboardFocusedElementCapture.restore(
                $0,
                processIdentifier: $1
            )
        },
        now: @escaping @MainActor () -> ContinuousClock.Instant = {
            .now
        },
        sleepForActivation: @escaping @MainActor (Duration) async -> Void = {
            try? await Task.sleep(for: $0)
        }
    ) {
        self.shortcutSender = shortcutSender
        self.frontmostApplication = frontmostApplication
        self.activationDelay = activationDelay
        self.requestEventAccess = requestEventAccess
        self.restoreFocusedElement = restoreFocusedElement
        self.now = now
        self.sleepForActivation = sleepForActivation
    }

    func pasteAfterActivating(
        target: any ClipboardPasteTarget,
        expectedBundleIdentifier: String,
        expectedChangeCount: Int,
        pasteboard: any ClipboardPasteboardAccessing,
        focusSnapshot: ClipboardFocusSnapshot?
    ) async -> Result<Void, Error> {
        guard !target.isTerminated else {
            return .failure(ClipboardDirectPasteError.targetUnavailable)
        }
        if !shortcutSender.canSend {
            requestEventAccess()
        }
        guard shortcutSender.canSend else {
            return .failure(ClipboardDirectPasteError.eventPermissionRequired)
        }
        _ = target.activate(options: [])
        let deadline = now() + activationDelay
        var activated = false
        repeat {
            if target.isTerminated {
                return .failure(ClipboardDirectPasteError.targetUnavailable)
            }
            if isInForeground(
                target,
                expectedBundleIdentifier: expectedBundleIdentifier
            ) {
                activated = true
                break
            }
            guard now() < deadline else { break }
            await sleepForActivation(.milliseconds(12))
        } while true
        guard activated else {
            return .failure(
                target.isTerminated
                    ? ClipboardDirectPasteError.targetUnavailable
                    : ClipboardDirectPasteError.targetChanged
            )
        }
        guard pasteboard.changeCount == expectedChangeCount else {
            return .failure(ClipboardDirectPasteError.clipboardChanged)
        }
        if let focusSnapshot {
            guard restoreFocusedElement(focusSnapshot, target.processIdentifier) else {
                return .failure(ClipboardDirectPasteError.focusRestoreFailed)
            }
            await sleepForActivation(.milliseconds(16))
            if target.isTerminated {
                return .failure(ClipboardDirectPasteError.targetUnavailable)
            }
            guard isInForeground(
                target,
                expectedBundleIdentifier: expectedBundleIdentifier
            ) else {
                return .failure(ClipboardDirectPasteError.targetChanged)
            }
            guard pasteboard.changeCount == expectedChangeCount else {
                return .failure(ClipboardDirectPasteError.clipboardChanged)
            }
        }
        guard shortcutSender.send(ShortcutKey(
            keyCode: 9,
            modifiers: [.command]
        )) else {
            return .failure(ClipboardDirectPasteError.eventPermissionRequired)
        }
        return .success(())
    }

    private func isInForeground(
        _ target: any ClipboardPasteTarget,
        expectedBundleIdentifier: String
    ) -> Bool {
        let frontmost = frontmostApplication()
        return target.isActive
            && target.bundleIdentifier == expectedBundleIdentifier
            && frontmost?.processIdentifier == target.processIdentifier
            && frontmost?.bundleIdentifier == expectedBundleIdentifier
    }
}

enum ClipboardDirectPasteError: LocalizedError, Equatable {
    case targetUnavailable
    case targetChanged
    case clipboardChanged
    case focusRestoreFailed
    case eventPermissionRequired

    var errorDescription: String? {
        switch self {
        case .targetUnavailable:
            L10n.shared.string("原应用已退出，无法直接粘贴。所选内容仍在系统剪贴板中。")
        case .targetChanged:
            L10n.shared.string("前台应用已改变，为避免误粘贴，本次操作已停止。所选内容仍在系统剪贴板中。")
        case .clipboardChanged:
            L10n.shared.string("系统剪贴板已被其他进程改写，本次操作已停止。所选内容未被发送。")
        case .focusRestoreFailed:
            L10n.shared.string("无法恢复原输入框焦点，为避免误粘贴，本次操作已停止。所选内容仍在系统剪贴板中。")
        case .eventPermissionRequired:
            L10n.shared.string("需要系统输入事件权限才能直接粘贴。请授权后重试，或手动按 Command-V。")
        }
    }
}
