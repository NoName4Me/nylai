import Carbon
import Foundation
import Observation

enum ShortcutBindingStatus: Equatable {
    case unbound
    case disabled
    case globallyDisabled
    case targetModuleDisabled
    case recording
    case paused
    case registered
    case failed(String)

    var title: String {
        switch self {
        case .unbound:
            "未绑定"
        case .disabled:
            "已停用"
        case .globallyDisabled:
            "总开关已关闭"
        case .targetModuleDisabled:
            "目标模块已关闭"
        case .recording:
            "录入中"
        case .paused:
            "已暂停"
        case .registered:
            "已生效"
        case .failed:
            "注册失败"
        }
    }
}

enum ShortcutValidationError: LocalizedError, Equatable {
    case invalidKey
    case missingPrimaryModifier
    case reserved
    case duplicate(String)

    var errorDescription: String? {
        switch self {
        case .invalidKey:
            "该按键不能用于全局快捷键。"
        case .missingPrimaryModifier:
            "至少需要 Command、Option 或 Control，Shift 不能单独使用。"
        case .reserved:
            "该组合由 macOS 保留，请换一个快捷键。"
        case .duplicate(let title):
            "该组合已绑定到「\(title)」。"
        }
    }
}

@MainActor
@Observable
final class ShortcutBindingRuntime {
    let store: ShortcutBindingStore
    private let registrar: any GlobalShortcutRegistering
    private let performAction: (ShortcutAction) -> Void
    private let isActionAvailable: (ShortcutAction) -> Bool

    private(set) var configuration: ShortcutBindingConfiguration?
    private(set) var loadError: String?
    private(set) var operationError: String?
    private(set) var recordingBindingID: ShortcutBindingID?
    private var transientRecording = false
    private var statuses: [ShortcutBindingID: ShortcutBindingStatus] = [:]
    private var activeRegistrations: [ShortcutBindingID: ActiveRegistration] = [:]

    var isRecording: Bool { recordingBindingID != nil || transientRecording }

    var hasStartupIssue: Bool {
        loadError != nil || configuration?.bindings.contains {
            if case .failed = status(for: $0.id) { return true }
            return false
        } == true
    }

    private struct ActiveRegistration {
        let token: GlobalShortcutRegistrationToken
        let invocationID: UUID
    }

    init(
        store: ShortcutBindingStore = ShortcutBindingStore(fileURL: ShortcutBindingStore.standardFileURL()),
        registrar: any GlobalShortcutRegistering = CarbonGlobalShortcutRegistrar(),
        performAction: @escaping (ShortcutAction) -> Void,
        isActionAvailable: @escaping (ShortcutAction) -> Bool = { _ in true }
    ) {
        self.store = store
        self.registrar = registrar
        self.performAction = performAction
        self.isActionAvailable = isActionAvailable
    }

    func start() {
        guard configuration == nil else {
            registerEligibleBindings()
            return
        }

        do {
            configuration = try store.loadOrCreateDefaults()
            loadError = nil
            registerEligibleBindings()
        } catch {
            configuration = nil
            loadError = error.localizedDescription
        }
    }

    func stop() {
        transientRecording = false
        recordingBindingID = nil
        activeRegistrations.removeAll()
        do {
            try registrar.unregisterAll()
        } catch {
            operationError = error.localizedDescription
        }
        updateAllStatuses()
    }

    func status(for id: ShortcutBindingID) -> ShortcutBindingStatus {
        if isRecording {
            return recordingBindingID == id ? .recording : .paused
        }
        guard let configuration, let binding = binding(for: id) else { return .unbound }
        if !configuration.isEnabled { return .globallyDisabled }
        if !binding.isEnabled { return .disabled }
        if binding.shortcut == nil { return .unbound }
        return statuses[id] ?? .failed("尚未注册。")
    }

    func binding(for id: ShortcutBindingID) -> ShortcutBinding? {
        configuration?.bindings.first { $0.id == id }
    }

    func updateShortcut(_ shortcut: ShortcutKey?, for id: ShortcutBindingID) throws {
        guard var configuration, let index = configuration.bindings.firstIndex(where: { $0.id == id }) else {
            throw ShortcutOperationError.bindingNotFound
        }
        let oldBinding = configuration.bindings[index]
        if oldBinding.shortcut == shortcut {
            return
        }
        if let shortcut {
            try validate(shortcut, excluding: id)
        }

        configuration.bindings[index].shortcut = shortcut
        let isLive = configuration.isEnabled
            && oldBinding.isEnabled
            && shortcut != nil
            && isActionAvailable(oldBinding.action)
        if isLive, let shortcut {
            try replaceRegistration(for: id, with: shortcut, oldBinding: oldBinding)
        } else {
            if oldBinding.shortcut != nil {
                do {
                    try releaseRegistration(for: id)
                } catch {
                    updateAllStatuses()
                    throw error
                }
            }
            do {
                try persist(configuration)
                self.configuration = configuration
            } catch {
                if oldBinding.shortcut != nil {
                    register(bindingID: id)
                }
                updateAllStatuses()
                throw error
            }
        }
        updateAllStatuses()
    }

    func setBindingEnabled(_ isEnabled: Bool, for id: ShortcutBindingID) throws {
        guard var configuration, let index = configuration.bindings.firstIndex(where: { $0.id == id }) else {
            throw ShortcutOperationError.bindingNotFound
        }
        let oldBinding = configuration.bindings[index]
        let shouldRegister = configuration.isEnabled
            && isEnabled
            && oldBinding.shortcut != nil
            && isActionAvailable(oldBinding.action)

        if !isEnabled {
            do {
                try releaseRegistration(for: id)
            } catch {
                updateAllStatuses()
                throw error
            }
        }

        statuses[id] = nil
        configuration.bindings[index].isEnabled = isEnabled
        do {
            try persist(configuration)
            self.configuration = configuration
        } catch {
            if !isEnabled {
                // 配置未写入时恢复旧注册，避免 UI 与系统状态分离。
                register(bindingID: id)
            }
            updateAllStatuses()
            throw error
        }

        if shouldRegister {
            register(bindingID: id)
        }
        updateAllStatuses()
    }

    func setGlobalEnabled(_ isEnabled: Bool) throws {
        guard var configuration else {
            throw ShortcutOperationError.configurationUnavailable
        }
        if isEnabled {
            statuses.removeAll()
            configuration.isEnabled = true
            try persist(configuration)
            self.configuration = configuration
            registerEligibleBindings()
        } else {
            do {
                try registrar.unregisterAll()
            } catch {
                operationError = error.localizedDescription
                statuses.removeAll()
                updateAllStatuses()
                throw error
            }
            activeRegistrations.removeAll()
            statuses.removeAll()
            configuration.isEnabled = false
            do {
                try persist(configuration)
                self.configuration = configuration
            } catch {
                registerEligibleBindings()
                updateAllStatuses()
                throw error
            }
            updateAllStatuses()
        }
    }

    func retry(_ id: ShortcutBindingID) {
        guard let configuration, configuration.isEnabled, let binding = binding(for: id),
              binding.isEnabled, binding.shortcut != nil,
              isActionAvailable(binding.action) else {
            updateAllStatuses()
            return
        }
        do {
            try releaseRegistration(for: id)
        } catch {
            updateAllStatuses()
            return
        }
        register(bindingID: id)
        updateAllStatuses()
    }

    func retryAll() {
        registerEligibleBindings()
    }

    func refreshActionAvailability() {
        guard !isRecording else {
            updateAllStatuses()
            return
        }
        registerEligibleBindings()
    }

    func beginRecording(_ id: ShortcutBindingID) throws {
        guard !isRecording else { return }
        guard binding(for: id) != nil else {
            throw ShortcutOperationError.bindingNotFound
        }
        do {
            try registrar.unregisterAll()
        } catch {
            operationError = error.localizedDescription
            updateAllStatuses()
            throw error
        }
        activeRegistrations.removeAll()
        statuses.removeAll()
        recordingBindingID = id
        operationError = nil
        updateAllStatuses()
    }

    func beginTransientRecording() throws {
        guard !isRecording else { return }
        do {
            try registrar.unregisterAll()
        } catch {
            operationError = error.localizedDescription
            updateAllStatuses()
            throw error
        }
        activeRegistrations.removeAll()
        statuses.removeAll()
        recordingBindingID = nil
        transientRecording = true
        operationError = nil
        updateAllStatuses()
    }

    func endTransientRecording() {
        guard transientRecording else { return }
        transientRecording = false
        registerEligibleBindings()
    }

    func endRecording() {
        if transientRecording {
            endTransientRecording()
            return
        }
        guard recordingBindingID != nil else { return }
        recordingBindingID = nil
        registerEligibleBindings()
    }

    func clearOperationError() {
        operationError = nil
    }

    func showError(_ error: Error) {
        operationError = error.localizedDescription
    }

    @discardableResult
    func addApplicationBinding(
        bundleIdentifier: String,
        path: String,
        hidesOnRepeatTrigger: Bool = true
    ) throws -> ShortcutBindingID {
        guard var configuration else {
            throw ShortcutOperationError.configurationUnavailable
        }
        guard !bundleIdentifier.isEmpty else {
            throw ShortcutOperationError.invalidApplication
        }
        guard !configuration.bindings.contains(where: {
            if case .application(let target) = $0.action {
                return target.bundleIdentifier == bundleIdentifier
            }
            return false
        }) else {
            throw ShortcutOperationError.applicationAlreadyBound
        }

        let id = ShortcutBindingID(rawValue: "application.\(UUID().uuidString)")
        configuration.bindings.append(ShortcutBinding(
            id: id,
            action: .application(ApplicationShortcutTarget(
                bundleIdentifier: bundleIdentifier,
                path: path,
                hidesOnRepeatTrigger: hidesOnRepeatTrigger
            )),
            shortcut: nil,
            isEnabled: true
        ))
        try persist(configuration)
        self.configuration = configuration
        updateAllStatuses()
        return id
    }

    func removeApplicationBinding(_ id: ShortcutBindingID) throws {
        guard var configuration, let index = configuration.bindings.firstIndex(where: { $0.id == id }) else {
            throw ShortcutOperationError.bindingNotFound
        }
        guard case .application = configuration.bindings[index].action else {
            throw ShortcutOperationError.internalBindingCannotBeRemoved
        }
        do {
            try releaseRegistration(for: id)
        } catch {
            updateAllStatuses()
            throw error
        }
        configuration.bindings.remove(at: index)
        do {
            try persist(configuration)
            self.configuration = configuration
        } catch {
            register(bindingID: id)
            updateAllStatuses()
            throw error
        }
        statuses[id] = nil
        updateAllStatuses()
    }

    func setHidesOnRepeatTrigger(_ value: Bool, for id: ShortcutBindingID) throws {
        guard var configuration, let index = configuration.bindings.firstIndex(where: { $0.id == id }),
              case .application(var target) = configuration.bindings[index].action else {
            throw ShortcutOperationError.bindingNotFound
        }
        target.hidesOnRepeatTrigger = value
        configuration.bindings[index] = ShortcutBinding(
            id: configuration.bindings[index].id,
            action: .application(target),
            shortcut: configuration.bindings[index].shortcut,
            isEnabled: configuration.bindings[index].isEnabled
        )
        try persist(configuration)
        self.configuration = configuration
        updateAllStatuses()
    }

    func relocateApplication(_ id: ShortcutBindingID, path: String, bundleIdentifier: String) throws {
        guard var configuration, let index = configuration.bindings.firstIndex(where: { $0.id == id }),
              case .application(var target) = configuration.bindings[index].action else {
            throw ShortcutOperationError.bindingNotFound
        }
        guard target.bundleIdentifier == bundleIdentifier else {
            throw ShortcutOperationError.applicationIdentityMismatch
        }
        target.path = path
        configuration.bindings[index] = ShortcutBinding(
            id: configuration.bindings[index].id,
            action: .application(target),
            shortcut: configuration.bindings[index].shortcut,
            isEnabled: configuration.bindings[index].isEnabled
        )
        try persist(configuration)
        self.configuration = configuration
        updateAllStatuses()
    }

    func validate(_ shortcut: ShortcutKey, excluding excludedID: ShortcutBindingID? = nil) throws {
        guard shortcut.keyCode <= 127 else {
            throw ShortcutValidationError.invalidKey
        }
        guard shortcut.modifiers.subtracting(.supported).isEmpty else {
            throw ShortcutValidationError.invalidKey
        }
        guard !shortcut.modifiers.intersection([.command, .option, .control]).isEmpty else {
            throw ShortcutValidationError.missingPrimaryModifier
        }
        guard !ReservedShortcut.isReserved(shortcut) else {
            throw ShortcutValidationError.reserved
        }

        if let conflict = configuration?.bindings.first(where: {
            $0.id != excludedID && $0.shortcut == shortcut
        }) {
            throw ShortcutValidationError.duplicate(Self.title(for: conflict.action))
        }
    }

    nonisolated static func title(for action: ShortcutAction) -> String {
        switch action {
        case .openSettings:
            "打开设置"
        case .captureMainDisplay, .captureInteractive:
            "截图"
        case .screenshotHistory:
            "最近截图"
        case .openCollage:
            "自由拼图"
        case .scrollCapture:
            "滚动截图"
        case .clipboardHistory:
            "剪贴板历史"
        case .application(let target):
            target.bundleIdentifier
        }
    }

    private func replaceRegistration(
        for id: ShortcutBindingID,
        with shortcut: ShortcutKey,
        oldBinding: ShortcutBinding
    ) throws {
        statuses[id] = nil
        let oldActive = activeRegistrations[id]
        let invocationID = UUID()
        let token: GlobalShortcutRegistrationToken
        do {
            token = try registrar.register(shortcut) { [weak self] in
                self?.dispatch(bindingID: id, invocationID: invocationID)
            }
        } catch {
            activeRegistrations[id] = oldActive
            updateAllStatuses()
            throw error
        }

        activeRegistrations[id] = ActiveRegistration(token: token, invocationID: invocationID)
        var updatedConfiguration = configuration ?? .defaults
        guard let index = updatedConfiguration.bindings.firstIndex(where: { $0.id == id }) else {
            throw ShortcutOperationError.bindingNotFound
        }
        updatedConfiguration.bindings[index].shortcut = shortcut

        do {
            try persist(updatedConfiguration)
            configuration = updatedConfiguration
        } catch {
            do {
                try registrar.unregister(token)
                activeRegistrations[id] = oldActive
            } catch {
                // 旧回调仍保留，但新注册调用被 invocation ID 拦截。
                activeRegistrations[id] = oldActive
                updateAllStatuses()
                throw ShortcutOperationError.rollbackUnregisterFailed(
                    persistence: error.localizedDescription,
                    registration: error.localizedDescription
                )
            }
            updateAllStatuses()
            throw error
        }

        guard let oldActive else { return }
        do {
            try registrar.unregister(oldActive.token)
        } catch {
            operationError = "新快捷键已保存并生效，但旧注册未能释放：\(error.localizedDescription)"
        }
    }

    private func persist(_ configuration: ShortcutBindingConfiguration) throws {
        do {
            try store.save(configuration)
            operationError = nil
        } catch {
            operationError = error.localizedDescription
            throw error
        }
    }

    private func registerEligibleBindings() {
        do {
            try registrar.unregisterAll()
        } catch {
            operationError = error.localizedDescription
            updateAllStatuses()
            return
        }
        activeRegistrations.removeAll()
        statuses.removeAll()

        guard let configuration, configuration.isEnabled else {
            updateAllStatuses()
            return
        }
        for binding in configuration.bindings where binding.isEnabled
            && binding.shortcut != nil
            && isActionAvailable(binding.action) {
            register(bindingID: binding.id)
        }
        updateAllStatuses()
    }

    private func register(bindingID id: ShortcutBindingID) {
        guard let binding = binding(for: id), let shortcut = binding.shortcut else { return }
        statuses[id] = nil
        let invocationID = UUID()
        do {
            let token = try registrar.register(shortcut) { [weak self] in
                self?.dispatch(bindingID: id, invocationID: invocationID)
            }
            activeRegistrations[id] = ActiveRegistration(token: token, invocationID: invocationID)
        } catch {
            statuses[id] = .failed(error.localizedDescription)
        }
    }

    private func releaseRegistration(for id: ShortcutBindingID) throws {
        guard let active = activeRegistrations.removeValue(forKey: id) else { return }
        do {
            try registrar.unregister(active.token)
        } catch {
            activeRegistrations[id] = active
            operationError = error.localizedDescription
            statuses[id] = .failed(error.localizedDescription)
            throw error
        }
    }

    private func dispatch(bindingID id: ShortcutBindingID, invocationID: UUID) {
        guard !isRecording,
              let configuration, configuration.isEnabled,
              let binding = binding(for: id), binding.isEnabled,
              isActionAvailable(binding.action),
              activeRegistrations[id]?.invocationID == invocationID else {
            return
        }
        performAction(binding.action)
    }

    private func updateAllStatuses() {
        guard let configuration else {
            statuses.removeAll()
            return
        }
        for binding in configuration.bindings {
            if transientRecording {
                statuses[binding.id] = .paused
            } else if let recordingBindingID {
                statuses[binding.id] = binding.id == recordingBindingID ? .recording : .paused
            } else if case .failed = statuses[binding.id] {
                continue
            } else if !configuration.isEnabled {
                statuses[binding.id] = .globallyDisabled
            } else if !binding.isEnabled {
                statuses[binding.id] = .disabled
            } else if binding.shortcut == nil {
                statuses[binding.id] = .unbound
            } else if !isActionAvailable(binding.action) {
                statuses[binding.id] = .targetModuleDisabled
            } else if activeRegistrations[binding.id] != nil {
                statuses[binding.id] = .registered
            } else {
                statuses[binding.id] = .failed("尚未注册。")
            }
        }
    }
}

enum ShortcutOperationError: LocalizedError, Equatable {
    case bindingNotFound
    case configurationUnavailable
    case invalidApplication
    case applicationAlreadyBound
    case applicationIdentityMismatch
    case internalBindingCannotBeRemoved
    case rollbackUnregisterFailed(persistence: String, registration: String)

    var errorDescription: String? {
        switch self {
        case .bindingNotFound:
            "快捷键绑定不存在。"
        case .configurationUnavailable:
            "快捷键配置不可用。"
        case .invalidApplication:
            "所选项目不是具有有效 bundle ID 的应用。"
        case .applicationAlreadyBound:
            "该应用已有快捷键绑定。"
        case .applicationIdentityMismatch:
            "所选应用与原绑定不是同一个应用，请选择原应用的新位置。"
        case .internalBindingCannotBeRemoved:
            "nylai 内置动作不能删除。"
        case .rollbackUnregisterFailed(let persistence, let registration):
            "保存失败：\(persistence)；撤销新注册也失败：\(registration)。旧快捷键仍保持生效。"
        }
    }
}

enum ReservedShortcut {
    static let combinations: [ShortcutKey] = [
        key(UInt32(kVK_Tab), [.command]),
        key(UInt32(kVK_Space), [.command]),
        key(UInt32(kVK_Space), [.control]),
        key(UInt32(kVK_Escape), [.command, .option]),
        key(UInt32(kVK_ANSI_Q), [.control, .command]),
        key(UInt32(kVK_ANSI_Q), [.command]),
        key(UInt32(kVK_ANSI_W), [.command]),
        key(UInt32(kVK_ANSI_H), [.command]),
        key(UInt32(kVK_ANSI_M), [.command]),
        key(UInt32(kVK_ANSI_Comma), [.command]),
    ]

    static func isReserved(_ shortcut: ShortcutKey) -> Bool {
        combinations.contains(shortcut)
    }

    private static func key(_ code: UInt32, _ modifiers: ShortcutModifiers) -> ShortcutKey {
        ShortcutKey(keyCode: code, modifiers: modifiers)
    }
}
