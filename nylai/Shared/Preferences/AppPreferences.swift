import Foundation
import Observation

@MainActor
@Observable
final class AppPreferences {
    private static let showSettingsOnLaunchKey = "showSettingsOnLaunch"
    private static let screenshotHistoryEnabledKey = "screenshotHistoryEnabled"
    private static let screenshotEnabledKey = "module.screenshot.enabled"
    private static let mouseGesturesEnabledKey = "module.mouse-gestures.enabled"
    private static let clipboardEnabledKey = "module.clipboard.enabled"
    private static let windowSwitcherEnabledKey = "module.window-switcher.enabled"
    private let defaults: UserDefaults

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
