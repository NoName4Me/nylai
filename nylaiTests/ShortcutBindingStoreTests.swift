import Carbon
import XCTest
@testable import nylai

final class ShortcutBindingStoreTests: XCTestCase {
    func testFirstLoadCreatesAndPersistsDefaultConfiguration() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }

        let configuration = try fixture.store.loadOrCreateDefaults()

        XCTAssertEqual(configuration, .defaults)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        XCTAssertEqual(try fixture.store.load(), .defaults)
        XCTAssertEqual(configuration.bindings.count, 6)
        XCTAssertEqual(configuration.bindings[0].id, .openSettings)
        XCTAssertNil(configuration.bindings[0].shortcut)
        XCTAssertEqual(configuration.bindings[1].id, .captureInteractive)
        XCTAssertEqual(
            configuration.bindings[1].shortcut,
            ShortcutKey(keyCode: UInt32(kVK_ANSI_A), modifiers: [.option])
        )
        XCTAssertTrue(configuration.bindings[1].isEnabled)
        XCTAssertFalse(configuration.isEnabled)
        XCTAssertEqual(configuration.bindings[2].id, .screenshotHistory)
        XCTAssertNil(configuration.bindings[2].shortcut)
        XCTAssertEqual(configuration.bindings[3].id, .collage)
        XCTAssertNil(configuration.bindings[3].shortcut)
        XCTAssertEqual(configuration.bindings[4].id, .scrollCapture)
        XCTAssertNil(configuration.bindings[4].shortcut)
        XCTAssertEqual(configuration.bindings[5].id, .clipboardHistory)
        XCTAssertNil(configuration.bindings[5].shortcut)
    }

    func testVersionOneMigratesInteractiveCaptureWithoutReplacingExistingBindings() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        try fixture.createParentDirectory()
        let inheritedShortcut = ShortcutKey(
            keyCode: UInt32(kVK_F6),
            modifiers: [.command, .option]
        )
        let versionOne = ShortcutBindingConfiguration(
            version: 1,
            isEnabled: true,
            bindings: [
                ShortcutBindingConfiguration.defaults.bindings[0],
                ShortcutBinding(
                    id: .captureMainDisplay,
                    action: .captureMainDisplay,
                    shortcut: inheritedShortcut,
                    isEnabled: false
                ),
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(versionOne).write(to: fixture.fileURL)

        let migrated = try fixture.store.load()

        XCTAssertEqual(migrated.version, ShortcutBindingConfiguration.currentVersion)
        XCTAssertEqual(migrated.bindings.count, 6)
        XCTAssertEqual(migrated.bindings[0], versionOne.bindings[0])
        XCTAssertEqual(migrated.bindings[1].id, .captureInteractive)
        XCTAssertEqual(migrated.bindings[1].action, .captureInteractive)
        XCTAssertEqual(migrated.bindings[1].shortcut, inheritedShortcut)
        XCTAssertFalse(migrated.bindings[1].isEnabled)
        XCTAssertEqual(migrated.bindings[2].id, .screenshotHistory)
        XCTAssertEqual(migrated.bindings[3].id, .collage)
        XCTAssertEqual(migrated.bindings[4].id, .scrollCapture)
        XCTAssertEqual(migrated.bindings[5].id, .clipboardHistory)
        XCTAssertEqual(try fixture.store.load(), migrated)
    }

    func testVersionTwoMigratesToSingleCaptureActionAndPreservesApplications() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        try fixture.createParentDirectory()
        let application = ShortcutBinding(
            id: ShortcutBindingID(rawValue: "application.8B71A3C2"),
            action: .application(ApplicationShortcutTarget(
                bundleIdentifier: "com.example.Editor",
                path: "/Applications/Editor.app",
                hidesOnRepeatTrigger: true
            )),
            shortcut: ShortcutKey(keyCode: UInt32(kVK_F7), modifiers: [.control, .option]),
            isEnabled: true
        )
        let legacyShortcut = ShortcutKey(
            keyCode: UInt32(kVK_ANSI_S),
            modifiers: [.control, .option]
        )
        let versionTwo = ShortcutBindingConfiguration(
            version: 2,
            isEnabled: true,
            bindings: [
                ShortcutBinding(
                    id: .openSettings,
                    action: .openSettings,
                    shortcut: ShortcutKey(keyCode: UInt32(kVK_ANSI_N), modifiers: [.control, .option]),
                    isEnabled: true
                ),
                ShortcutBinding(
                    id: .captureMainDisplay,
                    action: .captureMainDisplay,
                    shortcut: legacyShortcut,
                    isEnabled: true
                ),
                application,
                ShortcutBinding(
                    id: .captureInteractive,
                    action: .captureInteractive,
                    shortcut: nil,
                    isEnabled: true
                ),
            ]
        )
        try JSONEncoder().encode(versionTwo).write(to: fixture.fileURL)

        let migrated = try fixture.store.load()

        XCTAssertEqual(migrated.version, ShortcutBindingConfiguration.currentVersion)
        XCTAssertEqual(migrated.bindings.count, 7)
        XCTAssertEqual(migrated.bindings[0].id, .openSettings)
        XCTAssertEqual(migrated.bindings[1].id, .captureInteractive)
        XCTAssertEqual(migrated.bindings[1].shortcut, legacyShortcut)
        XCTAssertEqual(migrated.bindings[2], application)
        XCTAssertEqual(migrated.bindings[3].id, .screenshotHistory)
        XCTAssertEqual(migrated.bindings[4].id, .collage)
        XCTAssertEqual(migrated.bindings[5].id, .scrollCapture)
        XCTAssertEqual(migrated.bindings[6].id, .clipboardHistory)
        XCTAssertFalse(migrated.bindings.contains {
            $0.id == .captureMainDisplay || $0.action == .captureMainDisplay
        })
    }

    func testVersionTwoKeepsExplicitInteractiveShortcutWhenMerging() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        try fixture.createParentDirectory()
        let explicitShortcut = ShortcutKey(
            keyCode: UInt32(kVK_F6),
            modifiers: [.command, .option]
        )
        let versionTwo = ShortcutBindingConfiguration(
            version: 2,
            isEnabled: true,
            bindings: [
                ShortcutBindingConfiguration.defaults.bindings[0],
                ShortcutBinding(
                    id: .captureMainDisplay,
                    action: .captureMainDisplay,
                    shortcut: ShortcutKey(keyCode: UInt32(kVK_ANSI_S), modifiers: [.control, .option]),
                    isEnabled: true
                ),
                ShortcutBinding(
                    id: .captureInteractive,
                    action: .captureInteractive,
                    shortcut: explicitShortcut,
                    isEnabled: false
                ),
            ]
        )
        try JSONEncoder().encode(versionTwo).write(to: fixture.fileURL)

        let migrated = try fixture.store.load()

        XCTAssertEqual(migrated.bindings.count, 6)
        XCTAssertEqual(migrated.bindings[1].id, .captureInteractive)
        XCTAssertEqual(migrated.bindings[1].shortcut, explicitShortcut)
        XCTAssertFalse(migrated.bindings[1].isEnabled)
        XCTAssertEqual(migrated.bindings[2].id, .screenshotHistory)
        XCTAssertEqual(migrated.bindings[3].id, .collage)
        XCTAssertEqual(migrated.bindings[4].id, .scrollCapture)
        XCTAssertEqual(migrated.bindings[5].id, .clipboardHistory)
    }

    func testVersionThreeAddsUnboundHistoryActionAndKeepsExistingChoices() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        try fixture.createParentDirectory()
        let versionThree = ShortcutBindingConfiguration(
            version: 3,
            isEnabled: false,
            bindings: [
                ShortcutBindingConfiguration.defaults.bindings[0],
                ShortcutBinding(
                    id: .captureInteractive,
                    action: .captureInteractive,
                    shortcut: nil,
                    isEnabled: false
                ),
            ]
        )
        try JSONEncoder().encode(versionThree).write(to: fixture.fileURL)

        let migrated = try fixture.store.load()

        XCTAssertEqual(migrated.version, ShortcutBindingConfiguration.currentVersion)
        XCTAssertFalse(migrated.isEnabled)
        XCTAssertEqual(migrated.bindings.count, 6)
        XCTAssertEqual(migrated.bindings[1].id, .captureInteractive)
        XCTAssertNil(migrated.bindings[1].shortcut)
        XCTAssertEqual(migrated.bindings[2].id, .screenshotHistory)
        XCTAssertEqual(migrated.bindings[2].action, .screenshotHistory)
        XCTAssertNil(migrated.bindings[2].shortcut)
        XCTAssertEqual(migrated.bindings[3].id, .collage)
        XCTAssertEqual(migrated.bindings[3].action, .openCollage)
        XCTAssertNil(migrated.bindings[3].shortcut)
        XCTAssertEqual(migrated.bindings[4].id, .scrollCapture)
        XCTAssertEqual(migrated.bindings[4].action, .scrollCapture)
        XCTAssertNil(migrated.bindings[4].shortcut)
        XCTAssertEqual(migrated.bindings[5].id, .clipboardHistory)
    }

    func testVersionFourAddsUnboundCollageAndScrollActions() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        try fixture.createParentDirectory()
        let versionFour = ShortcutBindingConfiguration(
            version: 4,
            isEnabled: true,
            bindings: Array(ShortcutBindingConfiguration.defaults.bindings.prefix(3))
        )
        try JSONEncoder().encode(versionFour).write(to: fixture.fileURL)

        let migrated = try fixture.store.load()

        XCTAssertEqual(migrated.version, ShortcutBindingConfiguration.currentVersion)
        XCTAssertEqual(migrated.bindings.count, 6)
        XCTAssertEqual(migrated.bindings[3].id, .collage)
        XCTAssertEqual(migrated.bindings[3].action, .openCollage)
        XCTAssertNil(migrated.bindings[3].shortcut)
        XCTAssertEqual(migrated.bindings[4].id, .scrollCapture)
        XCTAssertEqual(migrated.bindings[4].action, .scrollCapture)
        XCTAssertNil(migrated.bindings[4].shortcut)
        XCTAssertEqual(migrated.bindings[5].id, .clipboardHistory)
    }

    func testVersionFiveAddsUnboundScrollAction() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        try fixture.createParentDirectory()
        let versionFive = ShortcutBindingConfiguration(
            version: 5,
            isEnabled: false,
            bindings: Array(ShortcutBindingConfiguration.defaults.bindings.prefix(4))
        )
        try JSONEncoder().encode(versionFive).write(to: fixture.fileURL)

        let migrated = try fixture.store.load()

        XCTAssertEqual(migrated.version, ShortcutBindingConfiguration.currentVersion)
        XCTAssertFalse(migrated.isEnabled)
        XCTAssertEqual(migrated.bindings.count, 6)
        XCTAssertEqual(migrated.bindings[4].id, .scrollCapture)
        XCTAssertEqual(migrated.bindings[4].action, .scrollCapture)
        XCTAssertNil(migrated.bindings[4].shortcut)
        XCTAssertEqual(migrated.bindings[5].id, .clipboardHistory)
    }

    func testVersionSixAddsUnboundClipboardHistoryAction() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        try fixture.createParentDirectory()
        let versionSix = ShortcutBindingConfiguration(
            version: 6,
            isEnabled: true,
            bindings: Array(ShortcutBindingConfiguration.defaults.bindings.prefix(5))
        )
        try JSONEncoder().encode(versionSix).write(to: fixture.fileURL)

        let migrated = try fixture.store.load()

        XCTAssertEqual(migrated.version, ShortcutBindingConfiguration.currentVersion)
        XCTAssertEqual(migrated.bindings.count, 6)
        XCTAssertEqual(migrated.bindings.last?.id, .clipboardHistory)
        XCTAssertNil(migrated.bindings.last?.shortcut)
    }

    func testVersionSevenMigratesUntouchedShortcutDefaults() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        try fixture.createParentDirectory()
        var versionSeven = ShortcutBindingConfiguration.defaults
        versionSeven.version = 7
        versionSeven.isEnabled = true
        versionSeven.bindings[0].shortcut = ShortcutKey(
            keyCode: UInt32(kVK_ANSI_N),
            modifiers: [.control, .option]
        )
        versionSeven.bindings[1].shortcut = ShortcutKey(
            keyCode: UInt32(kVK_ANSI_S),
            modifiers: [.control, .option]
        )
        try JSONEncoder().encode(versionSeven).write(to: fixture.fileURL)

        let migrated = try fixture.store.load()

        XCTAssertEqual(migrated.version, ShortcutBindingConfiguration.currentVersion)
        XCTAssertFalse(migrated.isEnabled)
        XCTAssertNil(migrated.bindings[0].shortcut)
        XCTAssertEqual(
            migrated.bindings[1].shortcut,
            ShortcutKey(keyCode: UInt32(kVK_ANSI_A), modifiers: [.option])
        )
    }

    func testClearedAndDisabledBindingsDoNotReviveDefaultsAfterReload() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        _ = try fixture.store.loadOrCreateDefaults()

        var cleared = ShortcutBindingConfiguration.defaults
        cleared.isEnabled = false
        cleared.bindings[0].isEnabled = false
        for index in cleared.bindings.indices {
            cleared.bindings[index].shortcut = nil
        }
        try fixture.store.save(cleared)

        let reloaded = try fixture.store.loadOrCreateDefaults()
        XCTAssertEqual(reloaded, cleared)
        XCTAssertFalse(reloaded.isEnabled)
        XCTAssertFalse(reloaded.bindings[0].isEnabled)
        XCTAssertTrue(reloaded.bindings.allSatisfy { $0.shortcut == nil })
    }

    func testApplicationBindingAndSwitchesRoundTrip() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let target = ApplicationShortcutTarget(
            bundleIdentifier: "com.example.Editor",
            path: "/Applications/Editor.app",
            hidesOnRepeatTrigger: false
        )
        let configuration = ShortcutBindingConfiguration(
            version: ShortcutBindingConfiguration.currentVersion,
            isEnabled: false,
            bindings: ShortcutBindingConfiguration.defaults.bindings + [
                ShortcutBinding(
                    id: ShortcutBindingID(rawValue: "application.8B71A3C2"),
                    action: .application(target),
                    shortcut: ShortcutKey(
                        keyCode: UInt32(kVK_F6),
                        modifiers: [.command, .shift]
                    ),
                    isEnabled: true
                ),
            ]
        )

        try fixture.store.save(configuration)

        XCTAssertEqual(try fixture.store.load(), configuration)
    }

    func testCorruptFileIsReportedAndOriginalBytesArePreserved() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        try fixture.createParentDirectory()
        let original = Data("{\"version\":1,\"isEnabled\":".utf8)
        try original.write(to: fixture.fileURL)

        XCTAssertThrowsError(try fixture.store.loadOrCreateDefaults()) { error in
            XCTAssertEqual(error as? ShortcutBindingStoreError, .corruptedData)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), original)
    }

    func testUnknownVersionIsReportedAndOriginalBytesArePreserved() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        try fixture.createParentDirectory()
        let original = Data("{\"version\":999,\"isEnabled\":true,\"bindings\":[]}".utf8)
        try original.write(to: fixture.fileURL)

        XCTAssertThrowsError(try fixture.store.loadOrCreateDefaults()) { error in
            XCTAssertEqual(error as? ShortcutBindingStoreError, .unsupportedVersion(999))
        }
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), original)
    }

    func testWriteFailureLeavesExistingConfigurationUntouched() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        try fixture.store.save(.defaults)
        let original = try Data(contentsOf: fixture.fileURL)
        let failingStore = ShortcutBindingStore(fileURL: fixture.fileURL, fileWriter: FailingWriter())

        var changed = ShortcutBindingConfiguration.defaults
        changed.isEnabled = false
        XCTAssertThrowsError(try failingStore.save(changed))

        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), original)
        XCTAssertEqual(try fixture.store.load(), .defaults)
    }
}

private struct StoreFixture {
    let directoryURL: URL
    let fileURL: URL
    let store: ShortcutBindingStore

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "nylai-shortcut-binding-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        fileURL = directoryURL.appending(path: "shortcut-bindings.json")
        store = ShortcutBindingStore(fileURL: fileURL)
    }

    func createParentDirectory() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private struct FailingWriter: ShortcutBindingFileWriting {
    func write(_ data: Data, to fileURL: URL) throws {
        throw TestWriteError.failed
    }
}

private enum TestWriteError: LocalizedError {
    case failed

    var errorDescription: String? {
        "模拟写入失败。"
    }
}
