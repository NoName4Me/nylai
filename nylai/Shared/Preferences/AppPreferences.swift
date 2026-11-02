import Foundation
import Observation

@MainActor
@Observable
final class AppPreferences {
    private static let showSettingsOnLaunchKey = "showSettingsOnLaunch"
    private let defaults: UserDefaults

    var showSettingsOnLaunch: Bool {
        didSet {
            defaults.set(showSettingsOnLaunch, forKey: Self.showSettingsOnLaunchKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showSettingsOnLaunch = defaults.bool(forKey: Self.showSettingsOnLaunchKey)
    }
}
