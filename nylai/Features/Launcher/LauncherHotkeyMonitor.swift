import AppKit
import CoreGraphics
import Carbon

/// A fixed system shortcut, intentionally independent of configurable Carbon hotkeys.
@MainActor
final class LauncherHotkeyMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var claimedSpace = false
    var canClaim: () -> Bool = { true }
    var onTrigger: () -> Void = {}
    var isRunning: Bool { tap != nil }

    func start() throws {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<LauncherHotkeyMonitor>.fromOpaque(context).takeUnretainedValue().handle(type, event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            throw WindowSwitcherError.inputTapUnavailable
        }
        let loopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), loopSource, .commonModes)
        tap = port; source = loopSource
        CGEvent.tapEnable(tap: port, enable: true)
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        source = nil; tap = nil; claimedSpace = false
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            claimedSpace = false
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Space) else {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyUp, claimedSpace { claimedSpace = false; return nil }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        if claimedSpace { return nil }
        let modifiers = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        guard modifiers == .maskCommand, canClaim() else { return Unmanaged.passUnretained(event) }
        claimedSpace = true
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            DispatchQueue.main.async { [weak self] in self?.onTrigger() }
        }
        return nil
    }
}
