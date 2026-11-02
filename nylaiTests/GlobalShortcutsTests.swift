import Carbon
import XCTest
@testable import nylai

final class GlobalShortcutsTests: XCTestCase {
    // 避免与应用的固定快捷键及普通系统快捷键冲突。
    private let testShortcut = GlobalShortcut(
        keyCode: UInt32(kVK_F18), modifiers: [.control, .option, .command]
    )

    @MainActor
    func testExclusiveRegistrationReportsConflictAndUnregisterReleasesKey() throws {
        let first = CarbonGlobalShortcutRegistrar()
        let second = CarbonGlobalShortcutRegistrar()
        defer {
            first.unregisterAll()
            second.unregisterAll()
        }

        try first.register(testShortcut, action: {})
        XCTAssertThrowsError(try second.register(testShortcut, action: {})) { error in
            XCTAssertEqual(error as? GlobalShortcutError, .occupied)
        }
        first.unregisterAll()
        try second.register(testShortcut, action: {})
        second.unregisterAll()
        second.unregisterAll()
        try first.register(testShortcut, action: {})
    }

    @MainActor
    func testDuplicateRegistrationDoesNotReplaceExistingRegistration() throws {
        let registrar = CarbonGlobalShortcutRegistrar()
        defer { registrar.unregisterAll() }
        try registrar.register(testShortcut, action: {})
        XCTAssertThrowsError(try registrar.register(testShortcut, action: {})) { error in
            XCTAssertEqual(error as? GlobalShortcutError, .occupied)
        }
        let competitor = CarbonGlobalShortcutRegistrar()
        defer { competitor.unregisterAll() }
        XCTAssertThrowsError(try competitor.register(testShortcut, action: {})) { error in
            XCTAssertEqual(error as? GlobalShortcutError, .occupied)
        }
    }

    @MainActor
    func testDroppingRegistrarReleasesItsRegistration() async throws {
        var registrar: CarbonGlobalShortcutRegistrar? = CarbonGlobalShortcutRegistrar()
        try XCTUnwrap(registrar).register(testShortcut, action: {})
        registrar = nil
        let replacement = CarbonGlobalShortcutRegistrar()
        defer { replacement.unregisterAll() }

        // 析构将 C 资源清理派发到主线程；允许该任务完成后再检查系统占用。
        for _ in 0..<20 {
            do {
                try replacement.register(testShortcut, action: {})
                return
            } catch GlobalShortcutError.occupied {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        XCTFail("释放注册器后快捷键仍被占用")
    }

    @MainActor
    func testUnsupportedModifiersDoNotCreateARegistration() throws {
        let registrar = CarbonGlobalShortcutRegistrar()
        defer { registrar.unregisterAll() }
        let invalid = GlobalShortcut(keyCode: UInt32(kVK_F18), modifiers: [.function])
        XCTAssertThrowsError(try registrar.register(invalid, action: {})) { error in
            XCTAssertEqual(error as? GlobalShortcutError, .invalidShortcut)
        }
        try registrar.register(testShortcut, action: {})
    }

    @MainActor
    func testControllerReportsFailureAndRetryRegistersOnlyOnce() {
        let registrar = StubRegistrar()
        registrar.error = .occupied
        var invocations = 0
        let controller = GlobalShortcutController(shortcut: .openSettings, registrar: registrar) { invocations += 1 }

        controller.start()
        guard case .failed(let message) = controller.status else {
            return XCTFail("冲突必须显示为注册失败")
        }
        XCTAssertEqual(message, GlobalShortcutError.occupied.localizedDescription)
        registrar.error = nil
        controller.start()
        controller.start()
        XCTAssertEqual(controller.status, .registered)
        XCTAssertEqual(registrar.registrationAttempts, 2)
        XCTAssertEqual(registrar.shortcut, GlobalShortcut.openSettings)
        registrar.action?()
        XCTAssertEqual(invocations, 1)
        controller.stop()
        XCTAssertEqual(controller.status, .inactive)
        XCTAssertNil(registrar.action)
        controller.start()
        XCTAssertEqual(controller.status, .registered)
        XCTAssertEqual(registrar.registrationAttempts, 3)
    }
}

@MainActor
private final class StubRegistrar: GlobalShortcutRegistering {
    var error: GlobalShortcutError?
    var registrationAttempts = 0
    var shortcut: GlobalShortcut?
    var action: (@MainActor () -> Void)?

    func register(_ shortcut: GlobalShortcut, action: @escaping @MainActor () -> Void) throws {
        registrationAttempts += 1
        if let error { throw error }
        self.shortcut = shortcut
        self.action = action
    }

    func unregisterAll() {
        shortcut = nil
        action = nil
    }
}
