import Foundation
import Observation

enum NylaiModuleID: String, CaseIterable, Codable, Equatable, Sendable {
    case screenshot
    case finderEnhancements
    case globalShortcuts
    case mouseGestures
    case clipboard
    case windowSwitcher
    case systemMonitor
    case board

    var title: String {
        switch self {
        case .screenshot:
            L10n.shared.string("截图")
        case .finderEnhancements:
            L10n.shared.string("访达增强")
        case .globalShortcuts:
            L10n.shared.string("快捷键")
        case .mouseGestures:
            L10n.shared.string("鼠标手势")
        case .clipboard:
            L10n.shared.string("剪贴板")
        case .windowSwitcher:
            L10n.shared.string("窗口切换")
        case .board:
            L10n.shared.string("无限画布")
        case .systemMonitor:
            L10n.shared.string("系统监控")
        }
    }

    var summary: String {
        switch self {
        case .screenshot:
            L10n.shared.string("截图、最近截图、滚动截图与自由拼图。")
        case .finderEnhancements:
            L10n.shared.string("在访达右键新建文件、复制路径或打开终端。")
        case .globalShortcuts:
            L10n.shared.string("在任意应用中响应已录入的组合键。")
        case .mouseGestures:
            L10n.shared.string("按住右键绘制方向路径并执行动作。")
        case .clipboard:
            L10n.shared.string("记录、搜索并复用复制的文本与图片。")
        case .windowSwitcher:
            L10n.shared.string("按应用分组预览窗口，并用 Command 快速切换。")
        case .board:
            L10n.shared.string("随手记录便签、图片与涂鸦，自动保存在本地。")
        case .systemMonitor:
            L10n.shared.string("在菜单栏查看 CPU、内存、网络与存储。")
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
            L10n.shared.string("已关闭")
        case .available:
            L10n.shared.string("已开启")
        case .starting:
            L10n.shared.string("正在启动")
        case .running:
            L10n.shared.string("运行中")
        case .failed:
            L10n.shared.string("启动失败")
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
        case .finderEnhancements:
            preferences.finderEnhancementsEnabled
        case .globalShortcuts:
            shortcutRuntime.configuration?.isEnabled ?? true
        case .mouseGestures:
            preferences.mouseGesturesEnabled
        case .clipboard:
            preferences.clipboardEnabled
        case .windowSwitcher:
            preferences.windowSwitcherEnabled
        case .systemMonitor:
            preferences.systemMonitorEnabled
        case .board:
            preferences.boardEnabled
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
        case .screenshot, .finderEnhancements, .mouseGestures, .clipboard,
             .windowSwitcher, .systemMonitor, .board:
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
        case .finderEnhancements:
            preferences.finderEnhancementsEnabled = enabled
        case .mouseGestures:
            preferences.mouseGesturesEnabled = enabled
        case .clipboard:
            preferences.clipboardEnabled = enabled
        case .windowSwitcher:
            preferences.windowSwitcherEnabled = enabled
        case .systemMonitor:
            preferences.systemMonitorEnabled = enabled
        case .board:
            preferences.boardEnabled = enabled
        }
        reportedStatuses[module] = nil
        onLifecycleChange?(module, enabled)
        if module == .screenshot || module == .clipboard || module == .board {
            shortcutRuntime.refreshActionAvailability()
        }
    }
}
