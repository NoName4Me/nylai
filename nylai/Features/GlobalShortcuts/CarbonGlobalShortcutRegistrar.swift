import AppKit
import Carbon

// Carbon 的注册与事件分发均在应用主事件循环中执行，不监听原始键盘输入。
@MainActor
final class CarbonGlobalShortcutRegistrar: GlobalShortcutRegistering {
    private let state = RegistrationState()

    func register(
        _ shortcut: ShortcutKey,
        action: @escaping @MainActor () -> Void
    ) throws -> GlobalShortcutRegistrationToken {
        try state.register(shortcut, action: action)
    }

    func unregister(_ token: GlobalShortcutRegistrationToken) throws {
        try state.unregister(token)
    }

    func unregisterAll() throws {
        try state.unregisterAll()
    }

    deinit {
        // 保持 C 回调上下文存活，直到在主线程移除 handler 和所有注册。
        let state = state
        Task { @MainActor in
            do {
                try state.unregisterAll()
            } catch {
                // 析构期间没有 UI 可报告，下一次注册会由系统返回实际状态。
            }
        }
    }

    @MainActor
    private final class RegistrationState {
        private struct Registration {
            let shortcut: ShortcutKey
            let reference: EventHotKeyRef
            let action: @MainActor () -> Void
        }

        private static let signature: OSType = 0x4E594C41 // NYLA
        private static var nextID: UInt32 = 1
        private var handler: EventHandlerRef?
        private var registrations: [UInt32: Registration] = [:]
        private var tokensByID: [UInt32: GlobalShortcutRegistrationToken] = [:]
        private var idsByToken: [GlobalShortcutRegistrationToken: UInt32] = [:]

        func register(
            _ shortcut: ShortcutKey,
            action: @escaping @MainActor () -> Void
        ) throws -> GlobalShortcutRegistrationToken {
            guard shortcut.keyCode <= 127,
                  !shortcut.modifiers.isEmpty,
                  shortcut.modifiers.subtracting(.supported).isEmpty else {
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
                if registrations.isEmpty { try? removeHandler() }
                if result == OSStatus(eventHotKeyExistsErr) {
                    throw GlobalShortcutError.occupied
                }
                throw GlobalShortcutError.systemFailure(result)
            }
            let token = GlobalShortcutRegistrationToken()
            registrations[id] = Registration(shortcut: shortcut, reference: reference, action: action)
            tokensByID[id] = token
            idsByToken[token] = id
            return token
        }

        func unregister(_ token: GlobalShortcutRegistrationToken) throws {
            guard let id = idsByToken[token], let registration = registrations[id] else {
                throw GlobalShortcutError.registrationNotFound
            }
            let result = UnregisterEventHotKey(registration.reference)
            guard result == noErr else {
                throw GlobalShortcutError.systemFailure(result)
            }
            registrations[id] = nil
            idsByToken[token] = nil
            tokensByID[id] = nil
            if registrations.isEmpty {
                try removeHandler()
            }
        }

        func unregisterAll() throws {
            var firstFailure: GlobalShortcutError?
            for token in Array(idsByToken.keys) {
                do {
                    try unregister(token)
                } catch let error as GlobalShortcutError {
                    if firstFailure == nil { firstFailure = error }
                } catch {
                    if firstFailure == nil {
                        firstFailure = .systemFailure(OSStatus(eventNotHandledErr))
                    }
                }
            }
            if registrations.isEmpty {
                try removeHandler()
            }
            if let firstFailure {
                throw firstFailure
            }
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

        private func removeHandler() throws {
            guard let currentHandler = handler else { return }
            let result = RemoveEventHandler(currentHandler)
            guard result == noErr else {
                throw GlobalShortcutError.systemFailure(result)
            }
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

        private func carbonModifiers(_ modifiers: ShortcutModifiers) -> UInt32 {
            var result: UInt32 = 0
            if modifiers.contains(.command) { result |= UInt32(cmdKey) }
            if modifiers.contains(.option) { result |= UInt32(optionKey) }
            if modifiers.contains(.control) { result |= UInt32(controlKey) }
            if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
            return result
        }
    }
}

enum GlobalShortcutError: LocalizedError, Equatable {
    case occupied
    case invalidShortcut
    case registrationNotFound
    case systemFailure(OSStatus)

    var errorDescription: String? {
        switch self {
        case .occupied:
            L10n.shared.string("此快捷键已被占用，macOS 未提供占用方。请换一个组合键。")
        case .invalidShortcut:
            L10n.shared.string("快捷键无效，请使用 Command、Option、Control 或 Shift 修饰键及有效按键。")
        case .registrationNotFound:
            L10n.shared.string("快捷键注册已不存在，无法注销。")
        case .systemFailure(let status):
            L10n.shared.string("快捷键注册失败（%@），请重试。", String(status))
        }
    }
}
