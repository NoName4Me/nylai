import Carbon
import XCTest
@testable import nylai

final class ShortcutConflictCheckerTests: XCTestCase {
    @MainActor
    func testRecordingStoresShortcutWithoutStartingCheck() {
        var endCount = 0
        let model = ShortcutConflictCheckerModel(
            beginInterception: {},
            endInterception: { endCount += 1 }
        )
        let shortcut = ShortcutKey(keyCode: UInt32(kVK_ANSI_A), modifiers: [.command, .control])

        XCTAssertTrue(model.beginRecording())
        model.capture(shortcut)

        XCTAssertEqual(model.shortcut, shortcut)
        XCTAssertEqual(endCount, 1)
        XCTAssertFalse(model.isRecording)
        XCTAssertFalse(model.isSearching)
        XCTAssertFalse(model.hasSearched)
    }

    func testMenuShortcutUsesVirtualKeyAndCommandByDefault() {
        XCTAssertEqual(
            ShortcutMenuShortcutResolver.resolve(
                commandCharacter: "P",
                virtualKey: nil,
                rawModifiers: 0
            ),
            ShortcutKey(
                keyCode: UInt32(kVK_ANSI_P),
                modifiers: [.command]
            )
        )
        XCTAssertEqual(
            ShortcutMenuShortcutResolver.resolve(
                commandCharacter: "P",
                virtualKey: Int(kVK_ANSI_P),
                rawModifiers: 1
            ),
            ShortcutKey(
                keyCode: UInt32(kVK_ANSI_P),
                modifiers: [.command, .shift]
            )
        )
        XCTAssertEqual(
            ShortcutMenuShortcutResolver.resolve(
                commandCharacter: nil,
                virtualKey: Int(kVK_UpArrow),
                rawModifiers: 2
            ),
            ShortcutKey(
                keyCode: UInt32(kVK_UpArrow),
                modifiers: [.command, .option]
            )
        )
    }

    func testMenuShortcutCanOmitCommandWhenSystemSaysSo() {
        XCTAssertEqual(
            ShortcutMenuShortcutResolver.resolve(
                commandCharacter: "=",
                virtualKey: nil,
                rawModifiers: 8
            ),
            ShortcutKey(
                keyCode: UInt32(kVK_ANSI_Equal),
                modifiers: []
            )
        )
    }

    func testMenuShortcutRejectsItemsWithoutAKey() {
        XCTAssertNil(ShortcutMenuShortcutResolver.resolve(
            commandCharacter: nil,
            virtualKey: nil,
            rawModifiers: 0
        ))
        XCTAssertNil(ShortcutMenuShortcutResolver.resolve(
            commandCharacter: "",
            virtualKey: nil,
            rawModifiers: 0
        ))
    }

    func testDisplayFormatterResolvesCharactersAndNamedKeys() {
        XCTAssertEqual(
            ShortcutDisplayFormatter.keyCode(for: "p"),
            UInt32(kVK_ANSI_P)
        )
        XCTAssertEqual(
            ShortcutDisplayFormatter.keyCode(for: "\t"),
            UInt32(kVK_Tab)
        )
        XCTAssertEqual(
            ShortcutDisplayFormatter.keyCode(for: "0"),
            UInt32(kVK_ANSI_0)
        )
        XCTAssertNil(ShortcutDisplayFormatter.keyCode(for: "组合键"))
    }

    @MainActor
    func testCancellingRecordingEndsInterception() {
        var beginCount = 0
        var endCount = 0
        let model = ShortcutConflictCheckerModel(
            beginInterception: { beginCount += 1 },
            endInterception: { endCount += 1 }
        )

        XCTAssertTrue(model.beginRecording())
        XCTAssertTrue(model.isRecording)

        model.cancelRecording()

        XCTAssertEqual(beginCount, 1)
        XCTAssertEqual(endCount, 1)
        XCTAssertFalse(model.isRecording)
    }

    @MainActor
    func testStoppingClearsInFlightSearchState() {
        let model = ShortcutConflictCheckerModel(
            beginInterception: {},
            endInterception: {}
        )
        model.isSearching = true
        model.hasSearched = true

        model.stop()

        XCTAssertFalse(model.isSearching)
    }

}
