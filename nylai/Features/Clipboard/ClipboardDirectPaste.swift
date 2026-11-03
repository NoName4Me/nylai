import AppKit
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

@MainActor
protocol ClipboardDirectPasting {
    func pasteAfterActivating(
        target: any ClipboardPasteTarget,
        expectedBundleIdentifier: String,
        expectedChangeCount: Int,
        pasteboard: any ClipboardPasteboardAccessing
    ) async -> Result<Void, Error>
}

@MainActor
final class SystemClipboardDirectPaster: ClipboardDirectPasting {
    private let shortcutSender: any GestureShortcutSending
    private let frontmostApplication: @MainActor () -> ClipboardFrontmostApplication?
    private let activationDelay: Duration
    private let requestEventAccess: @MainActor () -> Void

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
        activationDelay: Duration = .milliseconds(120),
        requestEventAccess: @escaping @MainActor () -> Void = {
            _ = CGRequestPostEventAccess()
        }
    ) {
        self.shortcutSender = shortcutSender
        self.frontmostApplication = frontmostApplication
        self.activationDelay = activationDelay
        self.requestEventAccess = requestEventAccess
    }

    func pasteAfterActivating(
        target: any ClipboardPasteTarget,
        expectedBundleIdentifier: String,
        expectedChangeCount: Int,
        pasteboard: any ClipboardPasteboardAccessing
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
        _ = target.activate(options: [.activateAllWindows])
        try? await Task.sleep(for: activationDelay)
        let frontmost = frontmostApplication()
        guard !target.isTerminated,
              target.isActive,
              target.bundleIdentifier == expectedBundleIdentifier,
              frontmost?.processIdentifier == target.processIdentifier,
              frontmost?.bundleIdentifier == expectedBundleIdentifier else {
            return .failure(ClipboardDirectPasteError.targetChanged)
        }
        guard pasteboard.changeCount == expectedChangeCount else {
            return .failure(ClipboardDirectPasteError.clipboardChanged)
        }
        guard shortcutSender.send(ShortcutKey(
            keyCode: 9,
            modifiers: [.command]
        )) else {
            return .failure(ClipboardDirectPasteError.eventPermissionRequired)
        }
        return .success(())
    }
}

enum ClipboardDirectPasteError: LocalizedError, Equatable {
    case targetUnavailable
    case targetChanged
    case clipboardChanged
    case eventPermissionRequired

    var errorDescription: String? {
        switch self {
        case .targetUnavailable:
            "原应用已退出，无法直接粘贴。所选内容仍在系统剪贴板中。"
        case .targetChanged:
            "前台应用已改变，为避免误粘贴，本次操作已停止。所选内容仍在系统剪贴板中。"
        case .clipboardChanged:
            "系统剪贴板已被其他进程改写，本次操作已停止。所选内容未被发送。"
        case .eventPermissionRequired:
            "需要系统输入事件权限才能直接粘贴。请授权后重试，或手动按 Command-V。"
        }
    }
}
