import XCTest
@testable import nylai

final class ModuleStateTests: XCTestCase {
    @MainActor
    func testDefaultsAndLifecycleChangesUseSingleSourcesOfTruth() throws {
        let suiteName = "nylai.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        let store = ShortcutBindingStore(
            fileURL: FileManager.default.temporaryDirectory
                .appending(path: "nylai-module-state-\(UUID().uuidString).json")
        )
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        let runtime = ShortcutBindingRuntime(
            store: store,
            registrar: ModuleNoopRegistrar()
        ) { _ in }
        runtime.start()
        let controller = ModuleStateController(
            preferences: preferences,
            shortcutRuntime: runtime
        )
        var changes: [(NylaiModuleID, Bool)] = []
        controller.onLifecycleChange = { changes.append(($0, $1)) }

        XCTAssertFalse(controller.isEnabled(.screenshot))
        XCTAssertFalse(controller.isEnabled(.globalShortcuts))
        XCTAssertFalse(controller.isEnabled(.mouseGestures))
        XCTAssertFalse(controller.isEnabled(.clipboard))
        XCTAssertFalse(controller.isEnabled(.windowSwitcher))
        XCTAssertEqual(controller.status(for: .globalShortcuts), .off)

        try controller.setEnabled(true, for: .globalShortcuts)
        XCTAssertEqual(runtime.configuration?.isEnabled, true)
        XCTAssertEqual(controller.status(for: .globalShortcuts), .available)
        try controller.setEnabled(true, for: .screenshot)
        try controller.setEnabled(true, for: .clipboard)

        XCTAssertEqual(changes.map(\.0), [.globalShortcuts, .screenshot, .clipboard])
        XCTAssertEqual(changes.map(\.1), [true, true, true])
        XCTAssertTrue(AppPreferences(defaults: defaults).clipboardEnabled)
    }

    @MainActor
    func testFailedGlobalShortcutLoadIsReportedAsFailedNotRunning() throws {
        let suiteName = "nylai.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "nylai-module-corrupt-\(UUID().uuidString).json")
        try Data("not-json".utf8).write(to: storeURL)
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let preferences = AppPreferences(defaults: defaults)
        let runtime = ShortcutBindingRuntime(
            store: ShortcutBindingStore(fileURL: storeURL),
            registrar: ModuleNoopRegistrar()
        ) { _ in }
        runtime.start()
        let controller = ModuleStateController(
            preferences: preferences,
            shortcutRuntime: runtime
        )

        guard case .failed = controller.status(for: .globalShortcuts) else {
            return XCTFail("加载失败必须显示失败状态")
        }
    }

    @MainActor
    func testRegistrationFailureIsSurfacedByGlobalShortcutModuleStatus() throws {
        let suiteName = "nylai.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ShortcutBindingStore(
            fileURL: FileManager.default.temporaryDirectory
                .appending(path: "nylai-module-failed-\(UUID().uuidString).json")
        )
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        var configuration = ShortcutBindingConfiguration.defaults
        configuration.isEnabled = true
        try store.save(configuration)
        let preferences = AppPreferences(defaults: defaults)
        preferences.screenshotEnabled = true
        let runtime = ShortcutBindingRuntime(
            store: store,
            registrar: ModuleFailingRegistrar()
        ) { _ in }
        runtime.start()
        let controller = ModuleStateController(
            preferences: preferences,
            shortcutRuntime: runtime
        )

        guard case .failed = controller.status(for: .globalShortcuts) else {
            return XCTFail("注册失败必须显示为失败状态")
        }
    }

    @MainActor
    func testClipboardModuleChangeReleasesAndRestoresItsShortcut() throws {
        let suiteName = "nylai.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.clipboardEnabled = true
        let store = ShortcutBindingStore(
            fileURL: FileManager.default.temporaryDirectory
                .appending(path: "nylai-module-target-\(UUID().uuidString).json")
        )
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        var configuration = ShortcutBindingConfiguration.defaults
        configuration.isEnabled = true
        try store.save(configuration)
        let registrar = ModuleTrackingRegistrar()
        let box = ModuleStateBox()
        let runtime = ShortcutBindingRuntime(
            store: store,
            registrar: registrar,
            performAction: { _ in },
            isActionAvailable: { action in
                switch action {
                case .clipboardHistory:
                    box.controller?.isEnabled(.clipboard) ?? false
                case .openSettings, .application:
                    true
                case .captureMainDisplay, .captureInteractive, .screenshotHistory,
                     .openCollage, .scrollCapture:
                    box.controller?.isEnabled(.screenshot) ?? false
                }
            }
        )
        let controller = ModuleStateController(
            preferences: preferences,
            shortcutRuntime: runtime
        )
        box.controller = controller
        runtime.start()
        try runtime.updateShortcut(
            ShortcutKey(keyCode: 8, modifiers: [.command, .option]),
            for: .clipboardHistory
        )
        XCTAssertEqual(registrar.activeCount, 1)

        try controller.setEnabled(false, for: .clipboard)
        XCTAssertEqual(registrar.activeCount, 0)

        try controller.setEnabled(true, for: .clipboard)
        XCTAssertEqual(registrar.activeCount, 1)
    }
}

@MainActor
private final class ModuleNoopRegistrar: GlobalShortcutRegistering {
    func register(
        _ shortcut: ShortcutKey,
        action: @escaping @MainActor () -> Void
    ) throws -> GlobalShortcutRegistrationToken {
        GlobalShortcutRegistrationToken()
    }

    func unregister(_ token: GlobalShortcutRegistrationToken) throws {}
    func unregisterAll() throws {}
}

@MainActor
private final class ModuleFailingRegistrar: GlobalShortcutRegistering {
    func register(
        _ shortcut: ShortcutKey,
        action: @escaping @MainActor () -> Void
    ) throws -> GlobalShortcutRegistrationToken {
        throw ModuleRegistrarError.conflict
    }

    func unregister(_ token: GlobalShortcutRegistrationToken) throws {}
    func unregisterAll() throws {}
}

private enum ModuleRegistrarError: LocalizedError {
    case conflict

    var errorDescription: String? { "快捷键冲突" }
}

@MainActor
private final class ModuleStateBox {
    var controller: ModuleStateController?
}

@MainActor
private final class ModuleTrackingRegistrar: GlobalShortcutRegistering {
    private(set) var activeCount = 0

    func register(
        _ shortcut: ShortcutKey,
        action: @escaping @MainActor () -> Void
    ) throws -> GlobalShortcutRegistrationToken {
        activeCount += 1
        return GlobalShortcutRegistrationToken()
    }

    func unregister(_ token: GlobalShortcutRegistrationToken) throws {
        activeCount = max(0, activeCount - 1)
    }

    func unregisterAll() throws {
        activeCount = 0
    }
}
