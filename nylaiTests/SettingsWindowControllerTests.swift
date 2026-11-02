import AppKit
import XCTest
@testable import nylai

final class SettingsWindowControllerTests: XCTestCase {
    @MainActor
    func testClosingAndReopeningUsesTheSameWindow() throws {
        let suiteName = "nylai.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = SettingsWindowController(preferences: AppPreferences(defaults: defaults))
        let window = try XCTUnwrap(controller.window)
        defer { controller.close() }

        controller.present()
        XCTAssertTrue(window.isVisible)
        controller.close()
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(NSApp.isRunning)
        controller.present()
        XCTAssertTrue(controller.window === window)
        XCTAssertTrue(window.isVisible)
    }
}
