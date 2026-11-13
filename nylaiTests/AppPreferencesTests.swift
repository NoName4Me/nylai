import XCTest
@testable import nylai

final class AppPreferencesTests: XCTestCase {
    @MainActor
    func testRuntimeLocalizationChangesWithoutRestart() {
        defer { L10n.shared.setLanguage(.system) }

        L10n.shared.setLanguage(.english)
        XCTAssertEqual(L10n.shared.string("跟随系统"), "Follow System")
        XCTAssertEqual(AppName.current, "Nylai")
        XCTAssertEqual(
            L10n.shared.string("当前 %@ × %@", "10", "20"),
            "Current 10 × 20"
        )

        L10n.shared.setLanguage(.simplifiedChinese)
        XCTAssertEqual(L10n.shared.string("跟随系统"), "跟随系统")
        XCTAssertEqual(AppName.current, "拈来")
    }

    @MainActor
    func testFreshPreferencesDoNotOpenSettingsOnLaunch() throws {
        let suiteName = "nylai.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(AppPreferences(defaults: defaults).showSettingsOnLaunch)
        XCTAssertFalse(AppPreferences(defaults: defaults).screenshotHistoryEnabled)
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.appearanceMode, .system)
        XCTAssertEqual(preferences.language, .system)
        XCTAssertTrue(preferences.screenshotEnabled)
        XCTAssertFalse(preferences.mouseGesturesEnabled)
        XCTAssertFalse(preferences.clipboardEnabled)
        XCTAssertFalse(preferences.windowSwitcherEnabled)
    }

    @MainActor
    func testPreferenceSurvivesRecreationAndCanBeTurnedOff() throws {
        let suiteName = "nylai.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        preferences.showSettingsOnLaunch = true
        let restored = AppPreferences(defaults: defaults)
        XCTAssertTrue(restored.showSettingsOnLaunch)
        restored.showSettingsOnLaunch = false
        XCTAssertFalse(AppPreferences(defaults: defaults).showSettingsOnLaunch)

        restored.screenshotHistoryEnabled = false
        XCTAssertFalse(AppPreferences(defaults: defaults).screenshotHistoryEnabled)

        restored.screenshotEnabled = false
        restored.mouseGesturesEnabled = true
        restored.clipboardEnabled = true
        restored.windowSwitcherEnabled = true
        restored.appearanceMode = .dark
        restored.language = .english
        let modules = AppPreferences(defaults: defaults)
        XCTAssertEqual(modules.appearanceMode, .dark)
        XCTAssertEqual(modules.language, .english)
        XCTAssertEqual(defaults.string(forKey: "appLanguage"), "en")
        XCTAssertFalse(modules.screenshotEnabled)
        XCTAssertTrue(modules.mouseGesturesEnabled)
        XCTAssertTrue(modules.clipboardEnabled)
        XCTAssertTrue(modules.windowSwitcherEnabled)

        modules.language = .simplifiedChinese
        XCTAssertEqual(AppPreferences(defaults: defaults).language, .simplifiedChinese)
        XCTAssertEqual(defaults.string(forKey: "appLanguage"), "zh-Hans")

        modules.language = .system
        XCTAssertEqual(AppPreferences(defaults: defaults).language, .system)
        XCTAssertEqual(defaults.string(forKey: "appLanguage"), "system")
    }
}
