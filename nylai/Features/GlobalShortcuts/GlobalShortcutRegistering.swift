import AppKit

struct GlobalShortcut: Equatable {
    let keyCode: UInt32
    let modifiers: NSEvent.ModifierFlags
}

// 实现负责报告占用冲突；注销后不再分发动作。
@MainActor
protocol GlobalShortcutRegistering: AnyObject {
    func register(_ shortcut: GlobalShortcut, action: @escaping @MainActor () -> Void) throws
    func unregisterAll()
}
