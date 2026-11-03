import Foundation

struct GlobalShortcutRegistrationToken: Hashable, Sendable {
    fileprivate let rawValue: UUID

    init() {
        rawValue = UUID()
    }
}

// 实现负责报告占用冲突；注销后不再分发动作。token 不暴露系统注册句柄。
@MainActor
protocol GlobalShortcutRegistering: AnyObject {
    func register(
        _ shortcut: ShortcutKey,
        action: @escaping @MainActor () -> Void
    ) throws -> GlobalShortcutRegistrationToken
    func unregister(_ token: GlobalShortcutRegistrationToken) throws
    func unregisterAll() throws
}
