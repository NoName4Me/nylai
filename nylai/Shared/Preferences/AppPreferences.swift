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
        case .system: L10n.shared.string("跟随系统")
        case .light: L10n.shared.string("日间")
        case .dark: L10n.shared.string("夜间")
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

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            L10n.shared.string("跟随系统")
        case .english:
            L10n.shared.string("英文")
        case .simplifiedChinese:
            L10n.shared.string("简体中文")
        }
    }

    var locale: Locale {
        switch self {
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
            return Locale(identifier: preferred.hasPrefix("zh") ? "zh-Hans" : "en")
        case .english:
            return Locale(identifier: "en")
        case .simplifiedChinese:
            return Locale(identifier: "zh-Hans")
        }
    }
}

@MainActor
@Observable
final class AppPreferences {
    private static let appearanceModeKey = "appearanceMode"
    private static let appLanguageKey = "appLanguage"
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

    var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Self.appLanguageKey)
            L10n.shared.setLanguage(language)
            NotificationCenter.default.post(name: .nylaiLanguageDidChange, object: nil)
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
        let storedLanguage = defaults.string(forKey: Self.appLanguageKey)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
        language = storedLanguage
        L10n.shared.setLanguage(storedLanguage)
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
