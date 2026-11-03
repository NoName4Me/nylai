import AppKit
@preconcurrency import CoreGraphics

enum MouseGestureInput: Equatable {
    case rightMouseDown(CGPoint)
    case rightMouseDragged(CGPoint)
    case rightMouseUp(CGPoint)
    case escape
    case tapTimedOut
}

@MainActor
protocol MouseGestureEventMonitoring: AnyObject {
    var isRunning: Bool { get }
    func start(
        handler: @escaping @MainActor (MouseGestureInput) -> Bool,
        onFailure: @escaping @MainActor (String) -> Void
    ) throws
    func stop()
    func restoreRightClick(at point: CGPoint)
}

@MainActor
enum MouseGestureInputAccess {
    static var isTrusted: Bool {
        AccessibilityPermission.isGranted
    }

    @discardableResult
    static func requestIfNeeded() -> Bool {
        AccessibilityPermission.requestIfNeeded()
    }
}

enum MouseGestureEventMonitorError: LocalizedError, Equatable {
    case accessibilityPermissionRequired
    case eventTapCreationFailed
    case runLoopSourceCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            "需要“辅助功能”权限才能识别并接管右键手势。请在系统设置中允许 nylai.app，然后重试。"
        case .eventTapCreationFailed:
            "无法创建鼠标事件监听。请检查系统设置中的辅助功能权限后重试。"
        case .runLoopSourceCreationFailed:
            "无法启动鼠标事件监听。"
        }
    }
}

private enum GestureEventMarker {
    static let userData: Int64 = 0x4E594C41
}

@MainActor
final class CGEventTapMouseGestureMonitor: MouseGestureEventMonitoring {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var handler: (@MainActor (MouseGestureInput) -> Bool)?
    private var onFailure: (@MainActor (String) -> Void)?

    var isRunning: Bool { eventTap != nil }

    func start(
        handler: @escaping @MainActor (MouseGestureInput) -> Bool,
        onFailure: @escaping @MainActor (String) -> Void
    ) throws {
        stop()
        guard MouseGestureInputAccess.isTrusted else {
            throw MouseGestureEventMonitorError.accessibilityPermissionRequired
        }
        self.handler = handler
        self.onFailure = onFailure
        let mask = (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.tapDisabledByTimeout.rawValue)
            | (1 << CGEventType.tapDisabledByUserInput.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: Self.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            self.handler = nil
            self.onFailure = nil
            throw MouseGestureEventMonitorError.eventTapCreationFailed
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            self.handler = nil
            self.onFailure = nil
            throw MouseGestureEventMonitorError.runLoopSourceCreationFailed
        }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
        handler = nil
        onFailure = nil
    }

    func restoreRightClick(at point: CGPoint) {
        guard let coreGraphicsPoint = ScreenCaptureService.coreGraphicsPoint(
            fromAppKitPoint: point,
            displaySpaces: ScreenCaptureService.displayCoordinateSpaces()
        ) else {
            return
        }
        postRightMouse(type: .rightMouseDown, at: coreGraphicsPoint)
        postRightMouse(type: .rightMouseUp, at: coreGraphicsPoint)
    }

    private func postRightMouse(type: CGEventType, at point: CGPoint) {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .right
        ) else {
            return
        }
        event.setIntegerValueField(.eventSourceUserData, value: GestureEventMarker.userData)
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.post(tap: .cghidEventTap)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData) == GestureEventMarker.userData {
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            if type == .tapDisabledByUserInput {
                let failure = onFailure
                Task { @MainActor in
                    failure?("鼠标事件监听被系统停用。请检查权限后点击重试。")
                }
            } else {
                _ = handler?(.tapTimedOut)
            }
            return Unmanaged.passUnretained(event)
        }

        let input: MouseGestureInput?
        switch type {
        case .rightMouseDown:
            input = .rightMouseDown(NSEvent.mouseLocation)
        case .rightMouseDragged:
            input = .rightMouseDragged(NSEvent.mouseLocation)
        case .rightMouseUp:
            input = .rightMouseUp(NSEvent.mouseLocation)
        case .keyDown where event.getIntegerValueField(.keyboardEventKeycode) == 53:
            input = .escape
        default:
            input = nil
        }
        guard let input else {
            return Unmanaged.passUnretained(event)
        }
        return handler?(input) == true
            ? nil
            : Unmanaged.passUnretained(event)
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let monitor = Unmanaged<CGEventTapMouseGestureMonitor>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        let wrappedEvent = UncheckedCGEvent(value: event)
        return MainActor.assumeIsolated {
            monitor.handle(type: type, event: wrappedEvent.value)
        }
    }
}

private struct UncheckedCGEvent: @unchecked Sendable {
    nonisolated(unsafe) let value: CGEvent
}

@MainActor
protocol GestureShortcutSending {
    var canSend: Bool { get }
    @discardableResult
    func requestAccess() -> Bool
    func send(_ shortcut: ShortcutKey) -> Bool
}

@MainActor
final class CGEventGestureShortcutSender: GestureShortcutSending {
    var canSend: Bool { CGPreflightPostEventAccess() }

    @discardableResult
    func requestAccess() -> Bool {
        guard !canSend else { return true }
        _ = CGRequestPostEventAccess()
        return canSend
    }

    func send(_ shortcut: ShortcutKey) -> Bool {
        guard canSend,
              let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(shortcut.keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(shortcut.keyCode), keyDown: false) else {
            return false
        }
        let flags = Self.flags(for: shortcut.modifiers)
        down.flags = flags
        up.flags = flags
        down.setIntegerValueField(
            .eventSourceUserData,
            value: GestureEventMarker.userData
        )
        up.setIntegerValueField(
            .eventSourceUserData,
            value: GestureEventMarker.userData
        )
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func flags(for modifiers: ShortcutModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        return flags
    }
}
