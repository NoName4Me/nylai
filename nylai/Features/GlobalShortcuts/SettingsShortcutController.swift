import Carbon
import Observation

@MainActor
@Observable
final class SettingsShortcutController {
    enum Status: Equatable {
        case inactive
        case registered
        case failed(String)
    }

    static let shortcut = GlobalShortcut(keyCode: UInt32(kVK_ANSI_N), modifiers: [.control, .option])
    private let registrar: any GlobalShortcutRegistering
    private let openSettings: @MainActor () -> Void
    private(set) var status: Status = .inactive

    init(
        registrar: any GlobalShortcutRegistering = CarbonGlobalShortcutRegistrar(),
        openSettings: @escaping @MainActor () -> Void
    ) {
        self.registrar = registrar
        self.openSettings = openSettings
    }

    func start() {
        guard status != .registered else { return }
        do {
            try registrar.register(Self.shortcut, action: openSettings)
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
