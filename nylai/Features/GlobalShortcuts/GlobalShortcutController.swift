import Observation

@MainActor
@Observable
final class GlobalShortcutController {
    enum Status: Equatable {
        case inactive
        case registered
        case failed(String)
    }

    let shortcut: GlobalShortcut
    private let registrar: any GlobalShortcutRegistering
    private let action: @MainActor () -> Void
    private(set) var status: Status = .inactive

    init(
        shortcut: GlobalShortcut,
        registrar: any GlobalShortcutRegistering = CarbonGlobalShortcutRegistrar(),
        action: @escaping @MainActor () -> Void
    ) {
        self.shortcut = shortcut
        self.registrar = registrar
        self.action = action
    }

    func start() {
        guard status != .registered else { return }
        do {
            try registrar.register(shortcut, action: action)
            status = .registered
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        registrar.unregisterAll()
        status = .inactive
    }
}
