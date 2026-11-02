import XCTest
@testable import nylai

final class AppPreferencesTests: XCTestCase {
    @MainActor
    func testFreshPreferencesDoNotOpenSettingsOnLaunch() throws {
        let suiteName = "nylai.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(AppPreferences(defaults: defaults).showSettingsOnLaunch)
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
    }
}
