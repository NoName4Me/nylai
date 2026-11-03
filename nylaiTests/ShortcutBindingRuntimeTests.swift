import Carbon
import XCTest
@testable import nylai

final class ShortcutBindingRuntimeTests: XCTestCase {
    @MainActor
    func testStartupRegistersEnabledConfigurationAndRoutesActions() throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        var actions: [ShortcutAction] = []
        let runtime = ShortcutBindingRuntime(
            store: fixture.store,
            registrar: fixture.registrar,
            performAction: { actions.append($0) }
        )

        runtime.start()

        XCTAssertEqual(runtime.status(for: .openSettings), .registered)
        XCTAssertEqual(runtime.status(for: .captureInteractive), .registered)
        XCTAssertEqual(fixture.registrar.activeShortcuts.count, 2)
        fixture.registrar.trigger(runtimeTestConfiguration().bindings[0].shortcut!)
        XCTAssertEqual(actions, [.openSettings])
        fixture.registrar.trigger(runtimeTestConfiguration().bindings[1].shortcut!)
        XCTAssertEqual(actions, [.openSettings, .captureInteractive])
    }

    @MainActor
    func testInteractiveCaptureCanBeBoundAndRouted() throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        var actions: [ShortcutAction] = []
        let runtime = ShortcutBindingRuntime(
            store: fixture.store,
            registrar: fixture.registrar,
            performAction: { actions.append($0) }
        )
        runtime.start()
        let shortcut = ShortcutKey(
            keyCode: UInt32(kVK_F6),
            modifiers: [.control, .option]
        )

        try runtime.updateShortcut(shortcut, for: .captureInteractive)
        fixture.registrar.trigger(shortcut)

        XCTAssertEqual(actions, [.captureInteractive])
        XCTAssertEqual(runtime.status(for: .captureInteractive), .registered)
        XCTAssertEqual(
            try fixture.store.load().bindings.first { $0.id == .captureInteractive }?.shortcut,
            shortcut
        )
    }

    @MainActor
    func testNewRegistrationFailureKeepsOldShortcutAndConfiguration() throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let runtime = ShortcutBindingRuntime(store: fixture.store, registrar: fixture.registrar) { _ in }
        runtime.start()
        let replacement = ShortcutKey(keyCode: UInt32(kVK_F6), modifiers: [.command, .option])
        fixture.registrar.failureForShortcut = replacement

        XCTAssertThrowsError(try runtime.updateShortcut(replacement, for: .openSettings)) { error in
            XCTAssertEqual(error as? GlobalShortcutError, .occupied)
        }

        XCTAssertEqual(runtime.binding(for: .openSettings)?.shortcut, runtimeTestConfiguration().bindings[0].shortcut)
        XCTAssertEqual(runtime.status(for: .openSettings), .registered)
        XCTAssertEqual(fixture.registrar.activeShortcuts.count, 2)
        XCTAssertEqual(try fixture.store.load(), runtimeTestConfiguration())
    }

    @MainActor
    func testPersistenceFailureRollsBackNewRegistrationAndKeepsOldAction() throws {
        let fixture = try RuntimeFixture(fileWriter: FailingRuntimeWriter())
        defer { fixture.remove() }
        let defaultsStore = ShortcutBindingStore(fileURL: fixture.store.fileURL)
        try defaultsStore.save(runtimeTestConfiguration())
        let runtime = ShortcutBindingRuntime(store: fixture.store, registrar: fixture.registrar) { _ in }
        runtime.start()
        let replacement = ShortcutKey(keyCode: UInt32(kVK_F6), modifiers: [.command, .option])

        XCTAssertThrowsError(try runtime.updateShortcut(replacement, for: .openSettings))

        XCTAssertEqual(runtime.binding(for: .openSettings)?.shortcut, runtimeTestConfiguration().bindings[0].shortcut)
        XCTAssertEqual(runtime.status(for: .openSettings), .registered)
        XCTAssertEqual(fixture.registrar.activeShortcuts.count, 2)
        XCTAssertEqual(try defaultsStore.load(), runtimeTestConfiguration())
        fixture.registrar.trigger(runtimeTestConfiguration().bindings[0].shortcut!)
    }

    @MainActor
    func testUnregisterFailureIsReportedAndDoesNotClaimSuccess() throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let runtime = ShortcutBindingRuntime(store: fixture.store, registrar: fixture.registrar) { _ in }
        runtime.start()
        fixture.registrar.failUnregister = true

        XCTAssertThrowsError(try runtime.setBindingEnabled(false, for: .openSettings)) { error in
            XCTAssertEqual(error as? GlobalShortcutError, .systemFailure(-1))
        }
        XCTAssertEqual(runtime.binding(for: .openSettings)?.isEnabled, true)
        guard case .failed(let message) = runtime.status(for: .openSettings) else {
            return XCTFail("注销失败必须显示实际失败状态")
        }
        XCTAssertTrue(message.contains("注册失败"))
    }

    @MainActor
    func testGlobalDisableReleasesAllAndEnableRestoresIndependently() throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let runtime = ShortcutBindingRuntime(store: fixture.store, registrar: fixture.registrar) { _ in }
        runtime.start()
        try runtime.setGlobalEnabled(false)

        XCTAssertEqual(runtime.status(for: .openSettings), .globallyDisabled)
        XCTAssertEqual(runtime.status(for: .captureInteractive), .globallyDisabled)
        XCTAssertTrue(fixture.registrar.activeShortcuts.isEmpty)

        fixture.registrar.failureForShortcut = runtimeTestConfiguration().bindings[0].shortcut
        try runtime.setGlobalEnabled(true)
        XCTAssertEqual(
            runtime.status(for: .openSettings),
            .failed(GlobalShortcutError.occupied.localizedDescription)
        )
        XCTAssertEqual(runtime.status(for: .captureInteractive), .registered)
        XCTAssertEqual(fixture.registrar.activeShortcuts.count, 1)
    }

    @MainActor
    func testUnavailableTargetReleasesKeyAndRestoresAfterAvailabilityReturns() throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        var screenshotAvailable = false
        var actions: [ShortcutAction] = []
        let runtime = ShortcutBindingRuntime(
            store: fixture.store,
            registrar: fixture.registrar,
            performAction: { actions.append($0) },
            isActionAvailable: { action in
                switch action {
                case .captureInteractive, .captureMainDisplay, .screenshotHistory,
                     .openCollage, .scrollCapture:
                    screenshotAvailable
                case .clipboardHistory, .openSettings, .application:
                    true
                }
            }
        )
        runtime.start()

        XCTAssertEqual(runtime.status(for: .openSettings), .registered)
        XCTAssertEqual(runtime.status(for: .captureInteractive), .targetModuleDisabled)
        XCTAssertEqual(fixture.registrar.activeShortcuts.count, 1)
        XCTAssertEqual(runtime.binding(for: .captureInteractive)?.shortcut != nil, true)

        screenshotAvailable = true
        runtime.refreshActionAvailability()
        XCTAssertEqual(runtime.status(for: .captureInteractive), .registered)
        XCTAssertEqual(fixture.registrar.activeShortcuts.count, 2)
        fixture.registrar.trigger(runtimeTestConfiguration().bindings[1].shortcut!)
        XCTAssertEqual(actions, [.captureInteractive])
    }

    @MainActor
    func testGlobalDisableUnregisterFailureKeepsConfigurationEnabled() throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let runtime = ShortcutBindingRuntime(store: fixture.store, registrar: fixture.registrar) { _ in }
        runtime.start()
        fixture.registrar.failUnregister = true

        XCTAssertThrowsError(try runtime.setGlobalEnabled(false)) { error in
            XCTAssertEqual(error as? GlobalShortcutError, .systemFailure(-1))
        }
        XCTAssertEqual(runtime.configuration?.isEnabled, true)
        XCTAssertEqual(runtime.status(for: .openSettings), .registered)
        XCTAssertEqual(fixture.registrar.activeShortcuts.count, 2)
    }

    @MainActor
    func testRecordingPausesOtherBindingsAndEndRestoresThem() throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let runtime = ShortcutBindingRuntime(store: fixture.store, registrar: fixture.registrar) { _ in }
        runtime.start()

        try runtime.beginRecording(.openSettings)
        XCTAssertTrue(runtime.isRecording)
        XCTAssertTrue(fixture.registrar.activeShortcuts.isEmpty)
        XCTAssertEqual(runtime.recordingBindingID, .openSettings)
        XCTAssertEqual(runtime.status(for: .openSettings), .recording)
        XCTAssertEqual(runtime.status(for: .captureInteractive), .paused)

        runtime.endRecording()
        XCTAssertFalse(runtime.isRecording)
        XCTAssertNil(runtime.recordingBindingID)
        XCTAssertEqual(runtime.status(for: .openSettings), .registered)
        XCTAssertEqual(runtime.status(for: .captureInteractive), .registered)
        XCTAssertEqual(fixture.registrar.activeShortcuts.count, 2)
    }

    @MainActor
    func testTransientRecordingPausesBindingsAndEndRestoresThem() throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let runtime = ShortcutBindingRuntime(store: fixture.store, registrar: fixture.registrar) { _ in }
        runtime.start()

        try runtime.beginTransientRecording()
        XCTAssertTrue(runtime.isRecording)
        XCTAssertNil(runtime.recordingBindingID)
        XCTAssertTrue(fixture.registrar.activeShortcuts.isEmpty)
        XCTAssertEqual(runtime.status(for: .openSettings), .paused)
        XCTAssertEqual(runtime.status(for: .captureInteractive), .paused)

        runtime.endTransientRecording()
        XCTAssertFalse(runtime.isRecording)
        XCTAssertEqual(runtime.status(for: .openSettings), .registered)
        XCTAssertEqual(fixture.registrar.activeShortcuts.count, 2)
    }

    @MainActor
    func testRetryClearsFailureStatusAfterSuccessfulRegistration() throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        fixture.registrar.failureForShortcut = runtimeTestConfiguration().bindings[0].shortcut
        let runtime = ShortcutBindingRuntime(store: fixture.store, registrar: fixture.registrar) { _ in }
        runtime.start()
        XCTAssertEqual(
            runtime.status(for: .openSettings),
            .failed(GlobalShortcutError.occupied.localizedDescription)
        )

        fixture.registrar.failureForShortcut = nil
        runtime.retry(.openSettings)
        XCTAssertEqual(runtime.status(for: .openSettings), .registered)
        XCTAssertEqual(fixture.registrar.activeShortcuts.count, 2)
    }

    @MainActor
    func testDuplicateAndReservedShortcutsAreRejected() throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let runtime = ShortcutBindingRuntime(store: fixture.store, registrar: fixture.registrar) { _ in }
        runtime.start()
        let duplicate = runtimeTestConfiguration().bindings[1].shortcut!
        XCTAssertThrowsError(try runtime.validate(duplicate, excluding: .openSettings)) { error in
            guard case ShortcutValidationError.duplicate = error else {
                return XCTFail("应用内重复绑定必须拦截")
            }
        }
        let reserved = ShortcutKey(keyCode: UInt32(kVK_ANSI_Q), modifiers: [.command])
        XCTAssertThrowsError(try runtime.validate(reserved)) { error in
            XCTAssertEqual(error as? ShortcutValidationError, .reserved)
        }
    }

    @MainActor
    func testDisabledBindingKeepsShortcutAndReleasesRegistration() throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let runtime = ShortcutBindingRuntime(store: fixture.store, registrar: fixture.registrar) { _ in }
        runtime.start()

        try runtime.setBindingEnabled(false, for: .openSettings)
        XCTAssertEqual(runtime.status(for: .openSettings), .disabled)
        XCTAssertEqual(runtime.binding(for: .openSettings)?.shortcut, runtimeTestConfiguration().bindings[0].shortcut)
        XCTAssertEqual(fixture.registrar.activeShortcuts.count, 1)

        try runtime.setBindingEnabled(true, for: .openSettings)
        XCTAssertEqual(runtime.status(for: .openSettings), .registered)
        XCTAssertEqual(fixture.registrar.activeShortcuts.count, 2)
    }

    @MainActor
    func testApplicationBindingsRoundTripAndStayUnique() throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let runtime = ShortcutBindingRuntime(store: fixture.store, registrar: fixture.registrar) { _ in }
        runtime.start()

        let id = try runtime.addApplicationBinding(
            bundleIdentifier: "com.example.Editor",
            path: "/Applications/Editor.app",
            hidesOnRepeatTrigger: false
        )
        XCTAssertEqual(runtime.binding(for: id)?.applicationTarget?.hidesOnRepeatTrigger, false)
        XCTAssertEqual(runtime.status(for: id), .unbound)
        XCTAssertThrowsError(try runtime.addApplicationBinding(
            bundleIdentifier: "com.example.Editor",
            path: "/Applications/Editor copy.app"
        )) { error in
            XCTAssertEqual(error as? ShortcutOperationError, .applicationAlreadyBound)
        }

        let reloaded = try ShortcutBindingStore(fileURL: fixture.store.fileURL).load()
        XCTAssertEqual(reloaded.bindings.last?.id, id)
        XCTAssertEqual(reloaded.bindings.last?.applicationTarget?.bundleIdentifier, "com.example.Editor")

        try runtime.setHidesOnRepeatTrigger(true, for: id)
        XCTAssertEqual(runtime.binding(for: id)?.applicationTarget?.hidesOnRepeatTrigger, true)
        try runtime.removeApplicationBinding(id)
        XCTAssertNil(runtime.binding(for: id))
        XCTAssertEqual(
            try fixture.store.load().bindings.count,
            runtimeTestConfiguration().bindings.count
        )
    }

    @MainActor
    func testRelocateRequiresSameBundleIdentifier() throws {
        let fixture = try RuntimeFixture()
        defer { fixture.remove() }
        let runtime = ShortcutBindingRuntime(store: fixture.store, registrar: fixture.registrar) { _ in }
        runtime.start()
        let id = try runtime.addApplicationBinding(
            bundleIdentifier: "com.example.Editor",
            path: "/Applications/Editor.app"
        )

        XCTAssertThrowsError(try runtime.relocateApplication(
            id,
            path: "/Applications/Other.app",
            bundleIdentifier: "com.example.Other"
        )) { error in
            XCTAssertEqual(error as? ShortcutOperationError, .applicationIdentityMismatch)
        }
        XCTAssertEqual(runtime.binding(for: id)?.applicationTarget?.path, "/Applications/Editor.app")

        try runtime.relocateApplication(
            id,
            path: "/Applications/Moved/Editor.app",
            bundleIdentifier: "com.example.Editor"
        )
        XCTAssertEqual(runtime.binding(for: id)?.applicationTarget?.path, "/Applications/Moved/Editor.app")
    }
}

@MainActor
private final class FakeShortcutRegistrar: GlobalShortcutRegistering {
    private(set) var activeShortcuts: [GlobalShortcutRegistrationToken: (ShortcutKey, () -> Void)] = [:]
    var failureForShortcut: ShortcutKey?
    var failUnregister = false

    func register(
        _ shortcut: ShortcutKey,
        action: @escaping @MainActor () -> Void
    ) throws -> GlobalShortcutRegistrationToken {
        if failureForShortcut == shortcut {
            throw GlobalShortcutError.occupied
        }
        let token = GlobalShortcutRegistrationToken()
        activeShortcuts[token] = (shortcut, action)
        return token
    }

    func unregister(_ token: GlobalShortcutRegistrationToken) throws {
        if failUnregister {
            throw GlobalShortcutError.systemFailure(-1)
        }
        guard activeShortcuts.removeValue(forKey: token) != nil else {
            throw GlobalShortcutError.registrationNotFound
        }
    }

    func unregisterAll() throws {
        if failUnregister {
            throw GlobalShortcutError.systemFailure(-1)
        }
        activeShortcuts.removeAll()
    }

    func trigger(_ shortcut: ShortcutKey) {
        activeShortcuts.values.first { $0.0 == shortcut }?.1()
    }
}

private struct FailingRuntimeWriter: ShortcutBindingFileWriting {
    func write(_ data: Data, to fileURL: URL) throws {
        throw RuntimeWriteError.failed
    }
}

private enum RuntimeWriteError: LocalizedError {
    case failed
    var errorDescription: String? { "模拟写入失败。" }
}

private func runtimeTestConfiguration() -> ShortcutBindingConfiguration {
    var configuration = ShortcutBindingConfiguration.defaults
    configuration.isEnabled = true
    configuration.bindings[0].shortcut = ShortcutKey(
        keyCode: UInt32(kVK_F5),
        modifiers: [.control, .option]
    )
    return configuration
}

private struct RuntimeFixture {
    let directoryURL: URL
    let store: ShortcutBindingStore
    let registrar: FakeShortcutRegistrar

    @MainActor
    init(fileWriter: any ShortcutBindingFileWriting = AtomicShortcutBindingFileWriter()) throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "nylai-shortcut-runtime-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileURL = directoryURL.appending(path: "shortcut-bindings.json")
        try ShortcutBindingStore(fileURL: fileURL).save(runtimeTestConfiguration())
        store = ShortcutBindingStore(
            fileURL: fileURL,
            fileWriter: fileWriter
        )
        registrar = FakeShortcutRegistrar()
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
