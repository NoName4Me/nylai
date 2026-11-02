import AppKit

struct GlobalShortcut: Equatable {
    let keyCode: UInt32
    let modifiers: NSEvent.ModifierFlags
}

// 后续由系统快捷键适配器实现；当前不注册任何快捷键。
@MainActor
protocol GlobalShortcutRegistering: AnyObject {
    func register(_ shortcut: GlobalShortcut, action: @escaping @MainActor () -> Void) throws
    func unregisterAll()
}
