import AppKit
import CoreGraphics

@MainActor
final class WindowSwitcherEventMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isSessionActive = false
    var onEvent: (WindowSwitcherEvent) -> Void = { _ in }

    func start() throws {
        guard eventTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<WindowSwitcherEventMonitor>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw WindowSwitcherError.inputTapUnavailable
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        self.eventTap = eventTap
        runLoopSource = source
    }

    func stop() {
        isSessionActive = false
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
    }

    func setSessionActive(_ active: Bool) {
        isSessionActive = active
    }

    private func handle(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(
            event.getIntegerValueField(.keyboardEventKeycode)
        )
        let unicode = type == .keyDown ? unicodeString(from: event) : nil
        let sessionIsActive = isSessionActive
        if type == .keyUp,
           WindowSwitcherKeyClassifier.shouldClaim(
               keyCode: keyCode,
               flags: event.flags,
               unicode: unicode,
               sessionIsActive: sessionIsActive
           ) {
            return nil
        }
        guard let switchEvent = WindowSwitcherKeyClassifier.event(
            keyCode: keyCode,
            flags: event.flags,
            unicode: unicode,
            sessionIsActive: sessionIsActive
        ) else {
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown,
           WindowSwitcherKeyClassifier.shouldClaim(
               keyCode: keyCode,
               flags: event.flags,
               unicode: unicode,
               sessionIsActive: sessionIsActive
           ) {
            if case .begin = switchEvent {
                setSessionActive(true)
            }
            DispatchQueue.main.async { [weak self] in
                self?.onEvent(switchEvent)
            }
            return nil
        }
        if sessionIsActive, type == .flagsChanged, switchEvent == .command(.confirm) {
            DispatchQueue.main.async { [weak self] in
                self?.onEvent(switchEvent)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    private func unicodeString(from event: CGEvent) -> String? {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(
            maxStringLength: buffer.count,
            actualStringLength: &length,
            unicodeString: &buffer
        )
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: buffer, count: length)
    }
}
