import AppKit
import XCTest
@testable import nylai

final class SettingsWindowControllerTests: XCTestCase {
    @MainActor
    func testClosingAndReopeningUsesTheSameWindow() throws {
        let suiteName = "nylai.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        let runtime = ShortcutBindingRuntime(
                store: ShortcutBindingStore(
                    fileURL: FileManager.default.temporaryDirectory
                        .appending(path: "nylai-settings-window-\(UUID().uuidString).json")
                ),
                registrar: NoopSettingsRegistrar()
            ) { _ in }
        let controller = SettingsWindowController(
            preferences: preferences,
            shortcutRuntime: runtime,
            moduleStateController: ModuleStateController(
                preferences: preferences,
                shortcutRuntime: runtime
            ),
            mouseGestureController: MouseGestureController(
                performNylaiAction: { _ in },
                isNylaiActionAvailable: { _ in true }
            ),
            clipboardHistoryStore: nil,
            clipboardMonitor: nil,
            clipboardLoadError: nil
        )
        let window = try XCTUnwrap(controller.window)
        defer { controller.close() }

        XCTAssertEqual(window.title, "")
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
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

@MainActor
private final class NoopSettingsRegistrar: GlobalShortcutRegistering {
    func register(
        _ shortcut: ShortcutKey,
        action: @escaping @MainActor () -> Void
    ) throws -> GlobalShortcutRegistrationToken {
        GlobalShortcutRegistrationToken()
    }

    func unregister(_ token: GlobalShortcutRegistrationToken) throws {}
    func unregisterAll() throws {}
}
