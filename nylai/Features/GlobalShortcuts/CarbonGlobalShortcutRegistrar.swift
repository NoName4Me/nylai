import AppKit
import Carbon

// Carbon 的注册与事件分发均在应用主事件循环中执行，不监听原始键盘输入。
@MainActor
final class CarbonGlobalShortcutRegistrar: GlobalShortcutRegistering {
    private let state = RegistrationState()

    func register(_ shortcut: GlobalShortcut, action: @escaping @MainActor () -> Void) throws {
        try state.register(shortcut, action: action)
    }

    func unregisterAll() {
        state.unregisterAll()
    }

    deinit {
        // 保持 C 回调上下文存活，直到在主线程移除 handler 和所有注册。
        let state = state
        Task { @MainActor in state.unregisterAll() }
    }

    @MainActor
    private final class RegistrationState {
        private struct Registration {
            let shortcut: GlobalShortcut
            let reference: EventHotKeyRef
            let action: @MainActor () -> Void
        }

        private static let signature: OSType = 0x4E594C41 // NYLA
        private static var nextID: UInt32 = 1
        private var handler: EventHandlerRef?
        private var registrations: [UInt32: Registration] = [:]

        func register(_ shortcut: GlobalShortcut, action: @escaping @MainActor () -> Void) throws {
            let supported: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
            guard shortcut.keyCode <= 127,
                  !shortcut.modifiers.isEmpty,
                  shortcut.modifiers.subtracting(supported).isEmpty else {
                throw GlobalShortcutError.invalidShortcut
            }
            guard !registrations.values.contains(where: { $0.shortcut == shortcut }) else {
                throw GlobalShortcutError.occupied
            }
            try installHandlerIfNeeded()

            let id = Self.nextID
            Self.nextID += 1
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(
                shortcut.keyCode,
                carbonModifiers(shortcut.modifiers),
                EventHotKeyID(signature: Self.signature, id: id),
                GetApplicationEventTarget(),
                OptionBits(kEventHotKeyExclusive),
                &reference
            )
            guard result == noErr, let reference else {
                if registrations.isEmpty { removeHandler() }
                if result == OSStatus(eventHotKeyExistsErr) {
                    throw GlobalShortcutError.occupied
                }
                throw GlobalShortcutError.systemFailure(result)
            }
            registrations[id] = Registration(shortcut: shortcut, reference: reference, action: action)
        }

        func unregisterAll() {
            for registration in registrations.values {
                UnregisterEventHotKey(registration.reference)
            }
            registrations.removeAll()
            removeHandler()
        }

        private func installHandlerIfNeeded() throws {
            guard handler == nil else { return }
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let result = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, context in
                    guard let event, let context else { return OSStatus(eventNotHandledErr) }
                    // GetApplicationEventTarget 的回调由主事件循环同步分发。
                    return MainActor.assumeIsolated {
                        let state = Unmanaged<RegistrationState>.fromOpaque(context).takeUnretainedValue()
                        return state.handle(event)
                    }
                },
                1,
                &eventType,
                Unmanaged.passUnretained(self).toOpaque(),
                &handler
            )
            guard result == noErr else { throw GlobalShortcutError.systemFailure(result) }
        }

        private func removeHandler() {
            if let handler { RemoveEventHandler(handler) }
            handler = nil
        }

        private func handle(_ event: EventRef) -> OSStatus {
            var hotKeyID = EventHotKeyID()
            let result = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard result == noErr,
                  hotKeyID.signature == Self.signature,
                  let action = registrations[hotKeyID.id]?.action else {
                return OSStatus(eventNotHandledErr)
            }
            action()
            return noErr
        }

        private func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
            var result: UInt32 = 0
            if flags.contains(.command) { result |= UInt32(cmdKey) }
            if flags.contains(.option) { result |= UInt32(optionKey) }
            if flags.contains(.control) { result |= UInt32(controlKey) }
            if flags.contains(.shift) { result |= UInt32(shiftKey) }
            return result
        }
    }
}

enum GlobalShortcutError: LocalizedError, Equatable {
    case occupied
    case invalidShortcut
    case systemFailure(OSStatus)

    var errorDescription: String? {
        switch self {
        case .occupied:
            "快捷键已被占用，请关闭其他应用中的相同快捷键后重试。"
        case .invalidShortcut:
            "快捷键无效，请使用 Command、Option、Control 或 Shift 修饰键。"
        case .systemFailure(let status):
            "快捷键注册失败（\(status)），请重试。"
        }
    }
}
