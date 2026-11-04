import XCTest
@testable import nylai

final class AppPreferencesTests: XCTestCase {
    @MainActor
    func testFreshPreferencesDoNotOpenSettingsOnLaunch() throws {
        let suiteName = "nylai.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(AppPreferences(defaults: defaults).showSettingsOnLaunch)
        XCTAssertFalse(AppPreferences(defaults: defaults).screenshotHistoryEnabled)
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.appearanceMode, .system)
        XCTAssertFalse(preferences.screenshotEnabled)
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
        let modules = AppPreferences(defaults: defaults)
        XCTAssertEqual(modules.appearanceMode, .dark)
        XCTAssertFalse(modules.screenshotEnabled)
        XCTAssertTrue(modules.mouseGesturesEnabled)
        XCTAssertTrue(modules.clipboardEnabled)
        XCTAssertTrue(modules.windowSwitcherEnabled)
    }
}
