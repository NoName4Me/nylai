import Carbon
import XCTest
@testable import nylai

final class GlobalShortcutsTests: XCTestCase {
    // 避免与应用默认快捷键及普通系统快捷键冲突。
    private let testShortcut = ShortcutKey(
        keyCode: UInt32(kVK_F18),
        modifiers: [.control, .option, .command]
    )

    @MainActor
    func testExclusiveRegistrationReportsConflictAndUnregisterReleasesKey() throws {
        let first = CarbonGlobalShortcutRegistrar()
        let second = CarbonGlobalShortcutRegistrar()
        defer {
            try? first.unregisterAll()
            try? second.unregisterAll()
        }

        _ = try first.register(testShortcut, action: {})
        XCTAssertThrowsError(try second.register(testShortcut, action: {})) { error in
            XCTAssertEqual(error as? GlobalShortcutError, .occupied)
        }
        try first.unregisterAll()
        _ = try second.register(testShortcut, action: {})
        try second.unregisterAll()
        try second.unregisterAll()
        _ = try first.register(testShortcut, action: {})
    }

    @MainActor
    func testSingleUnregisterLeavesOtherRegistrationActive() throws {
        let firstShortcut = ShortcutKey(keyCode: UInt32(kVK_F18), modifiers: [.control, .option, .command])
        let secondShortcut = ShortcutKey(keyCode: UInt32(kVK_F19), modifiers: [.control, .option, .command])
        let registrar = CarbonGlobalShortcutRegistrar()
        defer { try? registrar.unregisterAll() }

        let firstToken = try registrar.register(firstShortcut, action: {})
        _ = try registrar.register(secondShortcut, action: {})
        try registrar.unregister(firstToken)

        let competitor = CarbonGlobalShortcutRegistrar()
        defer { try? competitor.unregisterAll() }
        _ = try competitor.register(firstShortcut, action: {})
        XCTAssertThrowsError(try competitor.register(secondShortcut, action: {})) { error in
            XCTAssertEqual(error as? GlobalShortcutError, .occupied)
        }
    }

    @MainActor
    func testUnregisteringUnknownTokenFailsExplicitly() throws {
        let registrar = CarbonGlobalShortcutRegistrar()
        defer { try? registrar.unregisterAll() }
        XCTAssertThrowsError(try registrar.unregister(GlobalShortcutRegistrationToken())) { error in
            XCTAssertEqual(error as? GlobalShortcutError, .registrationNotFound)
        }
    }

    @MainActor
    func testDuplicateRegistrationDoesNotReplaceExistingRegistration() throws {
        let registrar = CarbonGlobalShortcutRegistrar()
        defer { try? registrar.unregisterAll() }
        _ = try registrar.register(testShortcut, action: {})
        XCTAssertThrowsError(try registrar.register(testShortcut, action: {})) { error in
            XCTAssertEqual(error as? GlobalShortcutError, .occupied)
        }
        let competitor = CarbonGlobalShortcutRegistrar()
        defer { try? competitor.unregisterAll() }
        XCTAssertThrowsError(try competitor.register(testShortcut, action: {})) { error in
            XCTAssertEqual(error as? GlobalShortcutError, .occupied)
        }
    }

    @MainActor
    func testDroppingRegistrarReleasesItsRegistration() async throws {
        var registrar: CarbonGlobalShortcutRegistrar? = CarbonGlobalShortcutRegistrar()
        _ = try XCTUnwrap(registrar).register(testShortcut, action: {})
        registrar = nil
        let replacement = CarbonGlobalShortcutRegistrar()
        defer { try? replacement.unregisterAll() }

        // 析构将 C 资源清理派发到主线程；允许该任务完成后再检查系统占用。
        for _ in 0..<20 {
            do {
                _ = try replacement.register(testShortcut, action: {})
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
        defer { try? registrar.unregisterAll() }
        let invalid = ShortcutKey(keyCode: UInt32(kVK_F18), modifiers: [])
        XCTAssertThrowsError(try registrar.register(invalid, action: {})) { error in
            XCTAssertEqual(error as? GlobalShortcutError, .invalidShortcut)
        }
        _ = try registrar.register(testShortcut, action: {})
    }
}
