import AppKit
import Carbon
import XCTest
@testable import nylai

final class ShortcutRecorderTests: XCTestCase {
    @MainActor
    func testRecorderDrawsShiftCommandOneKeycap() throws {
        let view = ShortcutRecorderView(frame: CGRect(x: 0, y: 0, width: 112, height: 28))
        view.shortcut = ShortcutKey(keyCode: UInt32(kVK_ANSI_1), modifiers: [.shift, .command])
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertEqual(view.accessibilityValue() as? String, "⇧⌘1")
    }

    func testDisplayUsesCurrentPhysicalKeyCode() {
        let shortcut = ShortcutKey(
            keyCode: UInt32(kVK_ANSI_N),
            modifiers: [.control, .option, .shift]
        )
        XCTAssertEqual(ShortcutDisplayFormatter.string(for: shortcut), "⌃⌥⇧N")
    }

    func testReservedCombinationsAreExplicit() {
        XCTAssertEqual(ReservedShortcut.combinations.count, 10)
        XCTAssertTrue(ReservedShortcut.isReserved(
            ShortcutKey(keyCode: UInt32(kVK_ANSI_Q), modifiers: [.command])
        ))
        XCTAssertFalse(ReservedShortcut.isReserved(
            ShortcutKey(keyCode: UInt32(kVK_ANSI_Q), modifiers: [.option])
        ))
    }

    @MainActor
    func testRecorderViewOnlyCapturesWhenRecording() {
        let view = ShortcutRecorderView()
        var captured: ShortcutKey?
        view.onCapture = { captured = $0 }
        view.isRecording = false
        let event = makeEvent(keyCode: UInt32(kVK_ANSI_N), modifiers: [.control, .option])
        view.keyDown(with: event)
        XCTAssertNil(captured)

        view.interceptsSystemEvents = false
        view.isRecording = true
        view.keyDown(with: event)
        XCTAssertEqual(captured, ShortcutKey(keyCode: UInt32(kVK_ANSI_N), modifiers: [.control, .option]))
    }

    func testEscapeCancelsDeleteClearsAndInvalidInputsAreRejected() {
        XCTAssertEqual(
            ShortcutRecorderEvent.keyAction(for: makeEvent(keyCode: UInt32(kVK_Escape), modifiers: [])),
            .cancel
        )
        XCTAssertEqual(
            ShortcutRecorderEvent.keyAction(for: makeEvent(keyCode: UInt32(kVK_Delete), modifiers: [])),
            .clear
        )
        XCTAssertEqual(
            ShortcutRecorderEvent.keyAction(for: makeEvent(keyCode: UInt32(kVK_ANSI_N), modifiers: [.shift])),
            .ignore
        )
        XCTAssertEqual(
            ShortcutRecorderEvent.keyAction(for: makeEvent(keyCode: UInt32(kVK_ANSI_N), modifiers: [])),
            .invalid
        )
    }

    func testControlUpArrowIsCapturedInsteadOfPassingThrough() {
        let shortcut = ShortcutKey(
            keyCode: UInt32(kVK_UpArrow),
            modifiers: [.control]
        )
        XCTAssertEqual(
            ShortcutRecorderEvent.keyAction(
                for: makeEvent(
                    keyCode: UInt32(kVK_UpArrow),
                    modifiers: [.control]
                )
            ),
            .capture(shortcut)
        )
        XCTAssertEqual(ShortcutDisplayFormatter.string(for: shortcut), "⌃↑")
    }

    func testSessionLevelRecorderConsumesAndCapturesControlUpArrow() throws {
        let event = try XCTUnwrap(CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_UpArrow),
            keyDown: true
        ))
        event.flags = [.maskControl]

        XCTAssertTrue(ShortcutRecordingEventMonitor.shouldConsume(type: .keyDown))
        XCTAssertTrue(ShortcutRecordingEventMonitor.shouldConsume(type: .keyUp))
        XCTAssertEqual(
            ShortcutRecorderEvent.keyAction(for: event),
            .capture(ShortcutKey(
                keyCode: UInt32(kVK_UpArrow),
                modifiers: [.control]
            ))
        )
    }

    private func makeEvent(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: UInt16(keyCode)
        )!
    }
}
