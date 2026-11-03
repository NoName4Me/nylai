import AppKit
import XCTest
@testable import nylai

@MainActor
final class ClipboardDirectPasteTests: XCTestCase {
    func testTerminatedTargetStopsBeforeRequestingPermissionOrActivating() async {
        let target = FakeClipboardPasteTarget(isTerminated: true)
        let sender = FakeGestureShortcutSender(canSend: false)
        var permissionRequests = 0
        let paster = SystemClipboardDirectPaster(
            shortcutSender: sender,
            frontmostApplication: { nil },
            activationDelay: .zero,
            requestEventAccess: { permissionRequests += 1 }
        )
        let pasteboard = DirectPastePasteboard(changeCount: 4)

        let result = await paster.pasteAfterActivating(
            target: target,
            expectedBundleIdentifier: "com.example.Target",
            expectedChangeCount: 4,
            pasteboard: pasteboard
        )

        assertFailure(result, is: .targetUnavailable)
        XCTAssertEqual(permissionRequests, 0)
        XCTAssertEqual(target.activationCount, 0)
        XCTAssertEqual(sender.sendCount, 0)
    }

    func testDeniedPostEventAccessRequestsOnceAndDoesNotActivateOrSend() async {
        let target = FakeClipboardPasteTarget()
        let sender = FakeGestureShortcutSender(canSend: false)
        var permissionRequests = 0
        let paster = SystemClipboardDirectPaster(
            shortcutSender: sender,
            frontmostApplication: { nil },
            activationDelay: .zero,
            requestEventAccess: { permissionRequests += 1 }
        )

        let result = await paster.pasteAfterActivating(
            target: target,
            expectedBundleIdentifier: "com.example.Target",
            expectedChangeCount: 1,
            pasteboard: DirectPastePasteboard(changeCount: 1)
        )

        assertFailure(result, is: .eventPermissionRequired)
        XCTAssertEqual(permissionRequests, 1)
        XCTAssertEqual(target.activationCount, 0)
        XCTAssertEqual(sender.sendCount, 0)
    }

    func testFrontmostApplicationChangeStopsPaste() async {
        let target = FakeClipboardPasteTarget()
        let sender = FakeGestureShortcutSender(canSend: true)
        let paster = SystemClipboardDirectPaster(
            shortcutSender: sender,
            frontmostApplication: {
                ClipboardFrontmostApplication(
                    processIdentifier: 99,
                    bundleIdentifier: "com.example.Other"
                )
            },
            activationDelay: .zero,
            requestEventAccess: {}
        )

        let result = await paster.pasteAfterActivating(
            target: target,
            expectedBundleIdentifier: "com.example.Target",
            expectedChangeCount: 2,
            pasteboard: DirectPastePasteboard(changeCount: 2)
        )

        assertFailure(result, is: .targetChanged)
        XCTAssertEqual(target.activationCount, 1)
        XCTAssertEqual(sender.sendCount, 0)
    }

    func testClipboardChangeStopsPaste() async {
        let target = FakeClipboardPasteTarget()
        let sender = FakeGestureShortcutSender(canSend: true)
        let paster = SystemClipboardDirectPaster(
            shortcutSender: sender,
            frontmostApplication: {
                ClipboardFrontmostApplication(
                    processIdentifier: target.processIdentifier,
                    bundleIdentifier: target.bundleIdentifier
                )
            },
            activationDelay: .zero,
            requestEventAccess: {}
        )

        let result = await paster.pasteAfterActivating(
            target: target,
            expectedBundleIdentifier: "com.example.Target",
            expectedChangeCount: 2,
            pasteboard: DirectPastePasteboard(changeCount: 3)
        )

        assertFailure(result, is: .clipboardChanged)
        XCTAssertEqual(target.activationCount, 1)
        XCTAssertEqual(sender.sendCount, 0)
    }

    func testSuccessfulPasteSendsExactlyOnce() async {
        let target = FakeClipboardPasteTarget()
        let sender = FakeGestureShortcutSender(canSend: true)
        let paster = SystemClipboardDirectPaster(
            shortcutSender: sender,
            frontmostApplication: {
                ClipboardFrontmostApplication(
                    processIdentifier: target.processIdentifier,
                    bundleIdentifier: target.bundleIdentifier
                )
            },
            activationDelay: .zero,
            requestEventAccess: {}
        )

        let result = await paster.pasteAfterActivating(
            target: target,
            expectedBundleIdentifier: "com.example.Target",
            expectedChangeCount: 7,
            pasteboard: DirectPastePasteboard(changeCount: 7)
        )

        guard case .success = result else {
            return XCTFail("直接粘贴应当成功")
        }
        XCTAssertEqual(target.activationCount, 1)
        XCTAssertEqual(sender.sendCount, 1)
        XCTAssertEqual(sender.lastShortcut, ShortcutKey(keyCode: 9, modifiers: [.command]))
    }

    private func assertFailure(
        _ result: Result<Void, Error>,
        is expected: ClipboardDirectPasteError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failure(let error) = result else {
            return XCTFail("直接粘贴应当失败", file: file, line: line)
        }
        XCTAssertEqual(
            error as? ClipboardDirectPasteError,
            expected,
            file: file,
            line: line
        )
    }
}

@MainActor
private final class FakeClipboardPasteTarget: ClipboardPasteTarget {
    let bundleIdentifier: String? = "com.example.Target"
    let processIdentifier: pid_t = 42
    var isTerminated: Bool
    var isActive = false
    private(set) var activationCount = 0

    init(isTerminated: Bool = false) {
        self.isTerminated = isTerminated
    }

    func activate(options: NSApplication.ActivationOptions) -> Bool {
        activationCount += 1
        guard !isTerminated else { return false }
        isActive = true
        return true
    }
}

@MainActor
private final class FakeGestureShortcutSender: GestureShortcutSending {
    let canSend: Bool
    private(set) var sendCount = 0
    private(set) var lastShortcut: ShortcutKey?

    init(canSend: Bool) {
        self.canSend = canSend
    }

    func requestAccess() -> Bool {
        canSend
    }

    func send(_ shortcut: ShortcutKey) -> Bool {
        sendCount += 1
        lastShortcut = shortcut
        return canSend
    }
}

@MainActor
private final class DirectPastePasteboard: ClipboardPasteboardAccessing {
    let changeCount: Int
    let accessState: ClipboardPasteboardAccessState = .allowed

    init(changeCount: Int) {
        self.changeCount = changeCount
    }

    func inspect() throws -> ClipboardPasteboardInspection {
        ClipboardPasteboardInspection(
            changeCount: changeCount,
            types: [],
            items: [],
            sourceBundleIdentifier: nil
        )
    }

    func data(forItemAt index: Int, type: String) -> Data? { nil }

    func string(forItemAt index: Int, type: String) -> String? { nil }

    func write(_ content: ClipboardContent, sourceBundleIdentifier: String) throws {}
}
