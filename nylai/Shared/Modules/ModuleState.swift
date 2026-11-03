import Foundation
import Observation

enum NylaiModuleID: String, CaseIterable, Codable, Equatable, Sendable {
    case screenshot
    case globalShortcuts
    case mouseGestures
    case clipboard
    case windowSwitcher

    var title: String {
        switch self {
        case .screenshot:
            "截图"
        case .globalShortcuts:
            "全局快捷键"
        case .mouseGestures:
            "鼠标手势"
        case .clipboard:
            "剪贴板"
        case .windowSwitcher:
            "窗口切换"
        }
    }

    var summary: String {
        switch self {
        case .screenshot:
            "截图、最近截图、滚动截图与自由拼图。"
        case .globalShortcuts:
            "在任意应用中响应已录入的组合键。"
        case .mouseGestures:
            "按住右键绘制方向路径并执行动作。"
        case .clipboard:
            "记录、搜索并复用复制的文本与图片。"
        case .windowSwitcher:
            "按应用分组预览窗口，并用 Command 快速切换。"
        }
    }
}

enum ModuleRuntimeStatus: Equatable, Sendable {
    case off
    case available
    case starting
    case running
    case failed(String)

    var title: String {
        switch self {
        case .off:
            "已关闭"
        case .available:
            "已开启"
        case .starting:
            "正在启动"
        case .running:
            "运行中"
        case .failed:
            "启动失败"
        }
    }
}

@MainActor
@Observable
final class ModuleStateController {
    let preferences: AppPreferences
    let shortcutRuntime: ShortcutBindingRuntime
    var onLifecycleChange: ((NylaiModuleID, Bool) -> Void)?
    private var reportedStatuses: [NylaiModuleID: ModuleRuntimeStatus] = [:]

    init(preferences: AppPreferences, shortcutRuntime: ShortcutBindingRuntime) {
        self.preferences = preferences
        self.shortcutRuntime = shortcutRuntime
    }

    func isEnabled(_ module: NylaiModuleID) -> Bool {
        switch module {
        case .screenshot:
            preferences.screenshotEnabled
        case .globalShortcuts:
            shortcutRuntime.configuration?.isEnabled ?? true
        case .mouseGestures:
            preferences.mouseGesturesEnabled
        case .clipboard:
            preferences.clipboardEnabled
        case .windowSwitcher:
            preferences.windowSwitcherEnabled
        }
    }

    func status(for module: NylaiModuleID) -> ModuleRuntimeStatus {
        if module == .globalShortcuts, let error = shortcutRuntime.loadError {
            return .failed(error)
        }
        guard isEnabled(module) else { return .off }
        if let reported = reportedStatuses[module] {
            return reported
        }
        switch module {
        case .globalShortcuts:
            guard let configuration = shortcutRuntime.configuration else {
                return .starting
            }
            for binding in configuration.bindings {
                if case .failed(let reason) = shortcutRuntime.status(for: binding.id) {
                    return .failed(reason)
                }
            }
            return .available
        case .screenshot, .mouseGestures, .clipboard, .windowSwitcher:
            return .available
        }
    }

    func setRuntimeStatus(_ status: ModuleRuntimeStatus, for module: NylaiModuleID) {
        reportedStatuses[module] = status
    }

    func setEnabled(_ enabled: Bool, for module: NylaiModuleID) throws {
        guard isEnabled(module) != enabled else { return }
        switch module {
        case .globalShortcuts:
            try shortcutRuntime.setGlobalEnabled(enabled)
        case .screenshot:
            preferences.screenshotEnabled = enabled
        case .mouseGestures:
            preferences.mouseGesturesEnabled = enabled
        case .clipboard:
            preferences.clipboardEnabled = enabled
        case .windowSwitcher:
            preferences.windowSwitcherEnabled = enabled
        }
        reportedStatuses[module] = nil
        onLifecycleChange?(module, enabled)
        if module == .screenshot || module == .clipboard {
            shortcutRuntime.refreshActionAvailability()
        }
    }
}
