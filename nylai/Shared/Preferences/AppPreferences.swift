import AppKit
import Foundation
import Observation

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "日间"
        case .dark: "夜间"
        }
    }

    @MainActor
    func apply() {
        switch self {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        NSApp.windows
            .filter { $0.identifier?.rawValue == "nylai.settings" }
            .forEach {
                $0.backgroundColor = NylaiTheme.panelBackground(
                    for: $0.effectiveAppearance
                )
            }
    }
}

@MainActor
@Observable
final class AppPreferences {
    private static let appearanceModeKey = "appearanceMode"
    private static let showSettingsOnLaunchKey = "showSettingsOnLaunch"
    private static let screenshotHistoryEnabledKey = "screenshotHistoryEnabled"
    private static let screenshotEnabledKey = "module.screenshot.enabled"
    private static let mouseGesturesEnabledKey = "module.mouse-gestures.enabled"
    private static let clipboardEnabledKey = "module.clipboard.enabled"
    private static let windowSwitcherEnabledKey = "module.window-switcher.enabled"
    private let defaults: UserDefaults

    var appearanceMode: AppAppearanceMode {
        didSet {
            defaults.set(appearanceMode.rawValue, forKey: Self.appearanceModeKey)
        }
    }

    var showSettingsOnLaunch: Bool {
        didSet {
            defaults.set(showSettingsOnLaunch, forKey: Self.showSettingsOnLaunchKey)
        }
    }

    var screenshotHistoryEnabled: Bool {
        didSet {
            defaults.set(screenshotHistoryEnabled, forKey: Self.screenshotHistoryEnabledKey)
        }
    }

    var screenshotEnabled: Bool {
        didSet {
            defaults.set(screenshotEnabled, forKey: Self.screenshotEnabledKey)
        }
    }

    var mouseGesturesEnabled: Bool {
        didSet {
            defaults.set(mouseGesturesEnabled, forKey: Self.mouseGesturesEnabledKey)
        }
    }

    var clipboardEnabled: Bool {
        didSet {
            defaults.set(clipboardEnabled, forKey: Self.clipboardEnabledKey)
        }
    }

    var windowSwitcherEnabled: Bool {
        didSet {
            defaults.set(windowSwitcherEnabled, forKey: Self.windowSwitcherEnabledKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearanceMode = defaults.string(forKey: Self.appearanceModeKey)
            .flatMap(AppAppearanceMode.init(rawValue:)) ?? .system
        showSettingsOnLaunch = defaults.bool(forKey: Self.showSettingsOnLaunchKey)
        screenshotHistoryEnabled = defaults.object(
            forKey: Self.screenshotHistoryEnabledKey
        ) as? Bool ?? false
        screenshotEnabled = defaults.object(
            forKey: Self.screenshotEnabledKey
        ) as? Bool ?? false
        mouseGesturesEnabled = defaults.object(
            forKey: Self.mouseGesturesEnabledKey
        ) as? Bool ?? false
        clipboardEnabled = defaults.object(
            forKey: Self.clipboardEnabledKey
        ) as? Bool ?? false
        windowSwitcherEnabled = defaults.object(
            forKey: Self.windowSwitcherEnabledKey
        ) as? Bool ?? false
    }
}
