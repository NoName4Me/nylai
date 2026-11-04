import Carbon
import XCTest
@testable import nylai

@MainActor
final class MouseGestureTests: XCTestCase {
    func testNoisyDiagonalAndOppositeOrderOfLStrokes() {
        func recognize(_ points: [CGPoint]) -> GesturePath? {
            var recognizer = GesturePathRecognizer()
            recognizer.begin(at: points[0])
            for point in points.dropFirst() { recognizer.move(to: point) }
            return recognizer.recognizedPath()
        }

        XCTAssertEqual(recognize([.zero, CGPoint(x: 10, y: 8), CGPoint(x: 25, y: 28),
                                  CGPoint(x: 48, y: 47)]), GesturePath([.upRight]))
        let elbow = [CGPoint(x: 0, y: 50), .zero, CGPoint(x: 50, y: 0)]
        XCTAssertEqual(recognize(elbow), GesturePath([.down, .right]))
        XCTAssertEqual(recognize(Array(elbow.reversed())), GesturePath([.left, .up]))
    }

    func testCircleDirectionAndLegacyPathDecoding() throws {
        for circle in [GestureCircle.clockwise, .counterclockwise] {
            let sign: CGFloat = circle == .clockwise ? -1 : 1
            let points = (0...40).map { index in
                let angle = 0.7 + sign * CGFloat(index) / 40 * 2 * .pi
                return CGPoint(x: 60 * cos(angle), y: 30 * sin(angle))
            }
            var recognizer = GesturePathRecognizer()
            recognizer.begin(at: points[0])
            for point in points.dropFirst() { recognizer.move(to: point) }
            let path = try XCTUnwrap(recognizer.recognizedPath())
            XCTAssertEqual(path, GesturePath(circle: circle))
            XCTAssertEqual(try JSONDecoder().decode(GesturePath.self, from: JSONEncoder().encode(path)), path)
        }
        let oldPath = Data(#"{"directions":["right"]}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(GesturePath.self, from: oldPath), GesturePath([.right]))
    }

    func testControlRightShortcutSendsModifierPressAndRelease() throws {
        let shortcut = ShortcutKey(keyCode: UInt32(kVK_RightArrow), modifiers: [.control])
        let events = try XCTUnwrap(CGEventGestureShortcutSender.keyboardEvents(
            for: shortcut, source: nil, heldFlags: []
        ))
        XCTAssertEqual(events.map(\.type), [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) },
                       [kVK_Control, kVK_RightArrow, kVK_RightArrow, kVK_Control].map(Int64.init))
        XCTAssertEqual(events.map { $0.flags.contains(.maskControl) }, [true, true, true, false])
        XCTAssertEqual(CGEventGestureShortcutSender.sourceState(for: shortcut), .hidSystemState)
        let arrowFlags: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
        XCTAssertEqual(events[1].flags, arrowFlags)
        XCTAssertEqual(events[2].flags, arrowFlags)
        XCTAssertEqual(events[0].flags, [.maskControl])
        XCTAssertEqual(events[3].flags, [])

        let held = try XCTUnwrap(CGEventGestureShortcutSender.keyboardEvents(
            for: shortcut, source: nil, heldFlags: [.maskControl]
        ))
        XCTAssertEqual(held.map(\.type), [.keyDown, .keyUp])
        XCTAssertTrue(held.allSatisfy { $0.flags.contains(.maskControl) })
    }

    func testInterceptedCoordinatesPreserveMovementAcrossDisplays() {
        let start = CGEventTapMouseGestureMonitor.appKitPoint(
            for: CGPoint(x: -20, y: 100), primaryDisplayHeight: 900
        )
        let right = CGEventTapMouseGestureMonitor.appKitPoint(
            for: CGPoint(x: 20, y: 100), primaryDisplayHeight: 900
        )
        let up = CGEventTapMouseGestureMonitor.appKitPoint(
            for: CGPoint(x: 20, y: 60), primaryDisplayHeight: 900
        )
        var recognizer = GesturePathRecognizer()
        recognizer.begin(at: start)
        _ = recognizer.move(to: right)
        _ = recognizer.move(to: up)
        XCTAssertEqual(recognizer.recognizedPath(), GesturePath([.right, .up]))
    }

    func testRecognizerSupportsFourDirectionsAndIgnoresMovementBelowThreshold() {
        var recognizer = GesturePathRecognizer()
        recognizer.begin(at: CGPoint(x: 100, y: 100))
        XCTAssertFalse(recognizer.move(to: CGPoint(x: 105, y: 102)))
        XCTAssertFalse(recognizer.hasEnteredGesture)
        XCTAssertNil(recognizer.recognizedPath())

        XCTAssertTrue(recognizer.move(to: CGPoint(x: 120, y: 100)))
        XCTAssertTrue(recognizer.move(to: CGPoint(x: 120, y: 80)))
        XCTAssertTrue(recognizer.move(to: CGPoint(x: 100, y: 80)))
        XCTAssertTrue(recognizer.move(to: CGPoint(x: 100, y: 100)))

        XCTAssertEqual(
            recognizer.recognizedPath(),
            GesturePath([.right, .down, .left, .up])
        )
    }

    func testRecognizerMergesRepeatedDirectionAndRejectsMoreThanFourSegments() {
        var recognizer = GesturePathRecognizer()
        recognizer.begin(at: .zero)
        _ = recognizer.move(to: CGPoint(x: 30, y: 0))
        _ = recognizer.move(to: CGPoint(x: 60, y: 1))
        XCTAssertEqual(recognizer.recognizedPath(), GesturePath([.right]))

        _ = recognizer.move(to: CGPoint(x: 60, y: 45))
        _ = recognizer.move(to: CGPoint(x: 30, y: 45))
        _ = recognizer.move(to: CGPoint(x: 30, y: 75))
        _ = recognizer.move(to: CGPoint(x: 60, y: 75))
        XCTAssertTrue(recognizer.hasExceededSegmentLimit)
        XCTAssertNil(recognizer.recognizedPath())
    }

    @MainActor
    func testPathRecorderCapturesRightMouseDrag() throws {
        let view = GesturePathRecorderView(
            frame: NSRect(x: 0, y: 0, width: 260, height: 112)
        )
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        defer { window.orderOut(nil) }

        var recordedPath: GesturePath?
        view.onChange = { recordedPath = $0 }

        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: CGPoint(x: 30, y: 56),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let dragged = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDragged,
            location: CGPoint(x: 100, y: 56),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseUp,
            location: CGPoint(x: 100, y: 56),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ))

        view.rightMouseDown(with: down)
        view.rightMouseDragged(with: dragged)
        view.rightMouseUp(with: up)

        XCTAssertEqual(recordedPath, GesturePath([.right]))
    }

    func testResolverPrefersScopedRuleAndNeverFallsBackFromUnavailableScopedRule() {
        let scopedPath = GesturePath([.right])
        let globalPath = GesturePath([.down])
        let scoped = MouseGestureRule(
            path: scopedPath,
            action: .nylai(.openSettings),
            scopeBundleIdentifier: "com.example.Editor",
            isEnabled: false
        )
        let global = MouseGestureRule(
            path: scopedPath,
            action: .nylai(.captureInteractive)
        )
        let other = MouseGestureRule(
            path: globalPath,
            action: .nylai(.scrollCapture),
            scopeBundleIdentifier: "com.example.Editor"
        )
        let configuration = MouseGestureConfiguration(
            version: MouseGestureConfiguration.currentVersion,
            showsTrace: true,
            rules: [scoped, global, other],
            disabledBundleIdentifiers: []
        )
        let resolver = GestureRuleResolver(
            configuration: configuration,
            applicationBundleIdentifier: "com.example.Editor",
            isActionAvailable: { _ in true }
        )

        XCTAssertEqual(resolver.resolve(scopedPath), .consumedWithoutMatch)
        XCTAssertEqual(resolver.resolve(globalPath), .matched(other))
        XCTAssertEqual(resolver.resolve(GesturePath([.left])), .consumedWithoutMatch)

        let disabled = GestureRuleResolver(
            configuration: MouseGestureConfiguration(
                version: 1,
                showsTrace: true,
                rules: [other],
                disabledBundleIdentifiers: ["com.example.Editor"]
            ),
            applicationBundleIdentifier: "com.example.Editor",
            isActionAvailable: { _ in true }
        )
        XCTAssertEqual(disabled.resolve(globalPath), .passThrough)
    }

    func testResolverPassesThroughWhenNoRuleCanRun() {
        let configuration = MouseGestureConfiguration(
            version: 1,
            showsTrace: true,
            rules: [
                MouseGestureRule(
                    path: GesturePath([.up]),
                    action: .nylai(.captureInteractive),
                    scopeBundleIdentifier: "com.example.Editor"
                ),
            ],
            disabledBundleIdentifiers: []
        )
        let resolver = GestureRuleResolver(
            configuration: configuration,
            applicationBundleIdentifier: "com.example.Other",
            isActionAvailable: { _ in true }
        )
        XCTAssertEqual(resolver.resolve(GesturePath([.up])), .passThrough)
    }

    @MainActor
    func testConfigurationRoundTripsAndRejectsDuplicatePathsInSameScope() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "nylai-gestures-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = MouseGestureConfigurationStore(fileURL: fileURL)
        let rule = MouseGestureRule(
            path: GesturePath([.right, .down]),
            action: .application(ApplicationShortcutTarget(
                bundleIdentifier: "com.example.Editor",
                path: "/Applications/Editor.app",
                hidesOnRepeatTrigger: false
            )),
            scopeBundleIdentifier: "com.example.Editor"
        )
        let configuration = MouseGestureConfiguration(
            version: 1,
            showsTrace: false,
            rules: [rule],
            disabledBundleIdentifiers: ["com.example.Secret"]
        )
        try store.save(configuration)
        XCTAssertEqual(try store.load(), configuration)

        let controller = MouseGestureController(
            store: store,
            eventMonitor: FakeGestureMonitor(),
            shortcutSender: FakeGestureShortcutSender(),
            performNylaiAction: { _ in },
            isNylaiActionAvailable: { _ in true }
        )
        controller.start(requestPermission: false)
        try controller.addRule(MouseGestureRule(
            path: GesturePath([.up]),
            action: .nylai(.openSettings)
        ))
        XCTAssertThrowsError(try controller.addRule(MouseGestureRule(
            path: GesturePath([.up]),
            action: .nylai(.openSettings)
        ))) { error in
            XCTAssertEqual(error as? MouseGestureConfigurationError, .duplicatePath)
        }
    }

    @MainActor
    func testControllerRoutesMatchedGestureSuppressesMenuAndRestoresShortRightClick() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "nylai-gesture-controller-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let monitor = FakeGestureMonitor()
        let sender = FakeGestureShortcutSender()
        var actions: [ShortcutAction] = []
        let controller = MouseGestureController(
            store: MouseGestureConfigurationStore(fileURL: storeURL),
            eventMonitor: monitor,
            shortcutSender: sender,
            performNylaiAction: { actions.append($0) },
            isNylaiActionAvailable: { _ in true }
        )
        try controller.addRule(MouseGestureRule(
            path: GesturePath([.right]),
            action: .nylai(.openSettings)
        ))
        controller.start(requestPermission: false)
        XCTAssertTrue(monitor.isRunning)

        XCTAssertTrue(monitor.send(.rightMouseDown(CGPoint(x: 100, y: 100))))
        XCTAssertTrue(monitor.send(.rightMouseDragged(CGPoint(x: 150, y: 100))))
        XCTAssertTrue(monitor.send(.rightMouseUp(CGPoint(x: 150, y: 100))))
        await waitForActions(1, actions: { actions.count })
        XCTAssertEqual(actions, [.openSettings])
        XCTAssertEqual(monitor.restoredClicks, [])

        controller.setRuleEditing(true)
        XCTAssertFalse(monitor.send(.rightMouseDown(CGPoint(x: 100, y: 100))))
        XCTAssertFalse(monitor.send(.rightMouseDragged(CGPoint(x: 150, y: 100))))
        XCTAssertFalse(monitor.send(.rightMouseUp(CGPoint(x: 150, y: 100))))
        XCTAssertEqual(actions, [.openSettings])
        controller.setRuleEditing(false)

        XCTAssertTrue(monitor.send(.rightMouseDown(CGPoint(x: 200, y: 200))))
        XCTAssertTrue(monitor.send(.rightMouseUp(CGPoint(x: 201, y: 200))))
        XCTAssertEqual(monitor.restoredClicks, [CGPoint(x: 201, y: 200)])
        XCTAssertEqual(actions, [.openSettings])

        controller.stop()
        controller.stop()
        XCTAssertFalse(monitor.isRunning)
    }

    @MainActor
    func testEscapeCancelsGestureWithoutActionMenuOrFollowingMouseUp() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "nylai-gesture-escape-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let monitor = FakeGestureMonitor()
        var actions: [ShortcutAction] = []
        let controller = MouseGestureController(
            store: MouseGestureConfigurationStore(fileURL: storeURL),
            eventMonitor: monitor,
            shortcutSender: FakeGestureShortcutSender(),
            performNylaiAction: { actions.append($0) },
            isNylaiActionAvailable: { _ in true },
            frontmostApplication: {
                GestureFrontmostApplication(
                    bundleIdentifier: "com.example.Editor",
                    processIdentifier: 42
                )
            },
            notificationCenter: NotificationCenter()
        )
        try controller.addRule(MouseGestureRule(
            path: GesturePath([.right]),
            action: .nylai(.openSettings)
        ))
        controller.start(requestPermission: false)

        XCTAssertTrue(monitor.send(.rightMouseDown(CGPoint(x: 100, y: 100))))
        XCTAssertTrue(monitor.send(.rightMouseDragged(CGPoint(x: 150, y: 100))))
        XCTAssertTrue(monitor.send(.escape))
        XCTAssertFalse(monitor.send(.rightMouseUp(CGPoint(x: 150, y: 100))))

        XCTAssertTrue(actions.isEmpty)
        XCTAssertTrue(monitor.restoredClicks.isEmpty)
    }

    @MainActor
    func testUnmatchedPathSuppressesMenuAndPassThroughRestoresIt() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "nylai-gesture-unmatched-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let monitor = FakeGestureMonitor()
        let controller = MouseGestureController(
            store: MouseGestureConfigurationStore(fileURL: storeURL),
            eventMonitor: monitor,
            shortcutSender: FakeGestureShortcutSender(),
            performNylaiAction: { _ in },
            isNylaiActionAvailable: { _ in true },
            frontmostApplication: {
                GestureFrontmostApplication(
                    bundleIdentifier: "com.example.Editor",
                    processIdentifier: 42
                )
            },
            notificationCenter: NotificationCenter()
        )
        try controller.addRule(MouseGestureRule(
            path: GesturePath([.up]),
            action: .nylai(.captureInteractive)
        ))
        controller.start(requestPermission: false)

        XCTAssertTrue(monitor.send(.rightMouseDown(CGPoint(x: 100, y: 100))))
        XCTAssertTrue(monitor.send(.rightMouseDragged(CGPoint(x: 100, y: 160))))
        XCTAssertTrue(monitor.send(.rightMouseUp(CGPoint(x: 100, y: 160))))
        XCTAssertTrue(monitor.restoredClicks.isEmpty)

        try controller.setApplicationDisabled(true, bundleIdentifier: "com.example.Editor")
        controller.refreshActionAvailability()
        XCTAssertFalse(monitor.send(.rightMouseDown(CGPoint(x: 100, y: 100))))
    }

    @MainActor
    func testApplicationSwitchCancelsPendingGestureAction() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "nylai-gesture-app-switch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let monitor = FakeGestureMonitor()
        let notifications = NotificationCenter()
        let frontmost = TestFrontmostApplication()
        var actions: [ShortcutAction] = []
        let controller = MouseGestureController(
            store: MouseGestureConfigurationStore(fileURL: storeURL),
            eventMonitor: monitor,
            shortcutSender: FakeGestureShortcutSender(),
            performNylaiAction: { actions.append($0) },
            isNylaiActionAvailable: { _ in true },
            frontmostApplication: { frontmost.value },
            notificationCenter: notifications
        )
        try controller.addRule(MouseGestureRule(
            path: GesturePath([.right]),
            action: .nylai(.openSettings)
        ))
        controller.start(requestPermission: false)

        XCTAssertTrue(monitor.send(.rightMouseDown(CGPoint(x: 100, y: 100))))
        XCTAssertTrue(monitor.send(.rightMouseDragged(CGPoint(x: 150, y: 100))))
        XCTAssertTrue(monitor.send(.rightMouseUp(CGPoint(x: 150, y: 100))))
        frontmost.value = GestureFrontmostApplication(
            bundleIdentifier: "com.example.Other",
            processIdentifier: 99
        )
        notifications.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(actions.isEmpty)
    }

    @MainActor
    func testStopAfterMouseUpPreventsPendingAction() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "nylai-gesture-stop-pending-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let monitor = FakeGestureMonitor()
        var actions: [ShortcutAction] = []
        let controller = MouseGestureController(
            store: MouseGestureConfigurationStore(fileURL: storeURL),
            eventMonitor: monitor,
            shortcutSender: FakeGestureShortcutSender(),
            performNylaiAction: { actions.append($0) },
            isNylaiActionAvailable: { _ in true },
            frontmostApplication: {
                GestureFrontmostApplication(
                    bundleIdentifier: "com.example.Editor",
                    processIdentifier: 42
                )
            },
            notificationCenter: NotificationCenter()
        )
        try controller.addRule(MouseGestureRule(
            path: GesturePath([.up]),
            action: .nylai(.openSettings)
        ))
        controller.start(requestPermission: false)

        XCTAssertTrue(monitor.send(.rightMouseDown(CGPoint(x: 100, y: 100))))
        XCTAssertTrue(monitor.send(.rightMouseDragged(CGPoint(x: 100, y: 160))))
        XCTAssertTrue(monitor.send(.rightMouseUp(CGPoint(x: 100, y: 160))))
        controller.stop()
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(actions.isEmpty)
    }

    @MainActor
    func testControllerDoesNotCaptureInputDuringExclusiveScreenshotInteraction() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "nylai-gesture-suppressed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let monitor = FakeGestureMonitor()
        var actions: [ShortcutAction] = []
        let suppression = TestSuppressionFlag()
        let controller = MouseGestureController(
            store: MouseGestureConfigurationStore(fileURL: storeURL),
            eventMonitor: monitor,
            shortcutSender: FakeGestureShortcutSender(),
            performNylaiAction: { actions.append($0) },
            isNylaiActionAvailable: { _ in true },
            isInputSuppressed: { suppression.value }
        )
        try controller.addRule(MouseGestureRule(
            path: GesturePath([.right]),
            action: .nylai(.openSettings)
        ))
        controller.start(requestPermission: false)

        suppression.value = true
        XCTAssertFalse(monitor.send(.rightMouseDown(CGPoint(x: 100, y: 100))))
        XCTAssertFalse(monitor.send(.rightMouseDragged(CGPoint(x: 150, y: 100))))
        XCTAssertFalse(monitor.send(.rightMouseUp(CGPoint(x: 150, y: 100))))
        XCTAssertEqual(actions, [])
        XCTAssertEqual(monitor.restoredClicks, [])
    }

    @MainActor
    func testControllerWithoutRulesDoesNotStartTap() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "nylai-gesture-empty-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let monitor = FakeGestureMonitor()
        let controller = MouseGestureController(
            store: MouseGestureConfigurationStore(fileURL: storeURL),
            eventMonitor: monitor,
            shortcutSender: FakeGestureShortcutSender(),
            performNylaiAction: { _ in },
            isNylaiActionAvailable: { _ in true }
        )

        controller.start(requestPermission: true)

        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(controller.runtimeStatus, .available)
    }

    @MainActor
    func testPermissionPromptOnlyRunsForExplicitStartWithEffectiveRules() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "nylai-gesture-permission-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let monitor = FakeGestureMonitor()
        var promptCount = 0
        var granted = false
        let controller = MouseGestureController(
            store: MouseGestureConfigurationStore(fileURL: storeURL),
            eventMonitor: monitor,
            shortcutSender: FakeGestureShortcutSender(),
            isInputAccessGranted: { granted },
            requestInputAccess: {
                promptCount += 1
                granted = true
                return true
            },
            performNylaiAction: { _ in },
            isNylaiActionAvailable: { _ in true }
        )
        try controller.addRule(MouseGestureRule(
            path: GesturePath([.up]),
            action: .nylai(.openSettings)
        ))

        controller.start(requestPermission: false)
        XCTAssertEqual(promptCount, 0)

        controller.stop()
        controller.start(requestPermission: true)
        XCTAssertEqual(promptCount, 1)
    }

    @MainActor
    func testAccessibilityPermissionPromptsAtMostOncePerLaunch() {
        AccessibilityPermission.resetPromptStateForTesting()
        defer { AccessibilityPermission.resetPromptStateForTesting() }
        var promptCount = 0

        XCTAssertFalse(AccessibilityPermission.requestIfNeeded(
            isGranted: { false },
            prompt: {
                promptCount += 1
                return false
            }
        ))
        XCTAssertFalse(AccessibilityPermission.requestIfNeeded(
            isGranted: { false },
            prompt: {
                promptCount += 1
                return false
            }
        ))
        XCTAssertEqual(promptCount, 1)
    }

    @MainActor
    func testRulesOnlyForDisabledApplicationsDoNotStartTap() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "nylai-gesture-disabled-scope-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let monitor = FakeGestureMonitor()
        let controller = MouseGestureController(
            store: MouseGestureConfigurationStore(fileURL: storeURL),
            eventMonitor: monitor,
            shortcutSender: FakeGestureShortcutSender(),
            performNylaiAction: { _ in },
            isNylaiActionAvailable: { _ in true }
        )
        try controller.addRule(MouseGestureRule(
            path: GesturePath([.right]),
            action: .nylai(.openSettings),
            scopeBundleIdentifier: "com.example.Disabled"
        ))
        try controller.setApplicationDisabled(true, bundleIdentifier: "com.example.Disabled")

        controller.start(requestPermission: true)

        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(controller.runtimeStatus, .available)
        XCTAssertEqual(controller.configuration?.rules.count, 1)
    }

    @MainActor
    func testMonitorFailureStopsTapAndAllowsCleanRetry() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "nylai-gesture-failure-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let monitor = FakeGestureMonitor()
        let controller = MouseGestureController(
            store: MouseGestureConfigurationStore(fileURL: storeURL),
            eventMonitor: monitor,
            shortcutSender: FakeGestureShortcutSender(),
            performNylaiAction: { _ in },
            isNylaiActionAvailable: { _ in true }
        )
        try controller.addRule(MouseGestureRule(
            path: GesturePath([.up]),
            action: .nylai(.captureInteractive)
        ))
        controller.start(requestPermission: false)
        XCTAssertTrue(monitor.isRunning)

        monitor.fail("监听已停用")

        XCTAssertFalse(monitor.isRunning)
        guard case .failed(let reason) = controller.runtimeStatus else {
            return XCTFail("监听失败必须反映到运行状态")
        }
        XCTAssertEqual(reason, "监听已停用")

        controller.retry()
        XCTAssertTrue(monitor.isRunning)
        XCTAssertEqual(controller.runtimeStatus, .running)
    }

    @MainActor
    func testMonitorFailureAfterMouseUpPreventsPendingAction() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "nylai-gesture-failure-pending-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let monitor = FakeGestureMonitor()
        var actions: [ShortcutAction] = []
        let controller = MouseGestureController(
            store: MouseGestureConfigurationStore(fileURL: storeURL),
            eventMonitor: monitor,
            shortcutSender: FakeGestureShortcutSender(),
            performNylaiAction: { actions.append($0) },
            isNylaiActionAvailable: { _ in true }
        )
        try controller.addRule(MouseGestureRule(
            path: GesturePath([.up]),
            action: .nylai(.openSettings)
        ))
        controller.start(requestPermission: false)

        XCTAssertTrue(monitor.send(.rightMouseDown(CGPoint(x: 100, y: 100))))
        XCTAssertTrue(monitor.send(.rightMouseDragged(CGPoint(x: 100, y: 160))))
        XCTAssertTrue(monitor.send(.rightMouseUp(CGPoint(x: 100, y: 160))))
        monitor.fail("监听已停用")
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(actions.isEmpty)
    }

    @MainActor
    func testTapTimeoutCancelsGestureWithoutStoppingRecoveredTap() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "nylai-gesture-timeout-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let monitor = FakeGestureMonitor()
        let controller = MouseGestureController(
            store: MouseGestureConfigurationStore(fileURL: storeURL),
            eventMonitor: monitor,
            shortcutSender: FakeGestureShortcutSender(),
            performNylaiAction: { _ in },
            isNylaiActionAvailable: { _ in true }
        )
        try controller.addRule(MouseGestureRule(
            path: GesturePath([.left]),
            action: .nylai(.openSettings)
        ))
        controller.start(requestPermission: false)
        XCTAssertTrue(monitor.send(.rightMouseDown(CGPoint(x: 10, y: 10))))

        XCTAssertFalse(monitor.send(.tapTimedOut))

        XCTAssertTrue(monitor.isRunning)
        XCTAssertEqual(controller.runtimeStatus, .running)
    }

    @MainActor
    func testRetryReloadsFixedConfigurationAfterStartupFailure() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "nylai-gesture-recover-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        try Data("not-json".utf8).write(to: storeURL)
        let store = MouseGestureConfigurationStore(fileURL: storeURL)
        let monitor = FakeGestureMonitor()
        let controller = MouseGestureController(
            store: store,
            eventMonitor: monitor,
            shortcutSender: FakeGestureShortcutSender(),
            performNylaiAction: { _ in },
            isNylaiActionAvailable: { _ in true }
        )
        controller.start(requestPermission: false)
        guard case .failed = controller.runtimeStatus else {
            return XCTFail("损坏配置必须显示失败")
        }

        try store.save(.defaults)
        controller.retry()

        XCTAssertEqual(controller.runtimeStatus, .available)
        XCTAssertFalse(monitor.isRunning)
    }

    @MainActor
    func testUnavailableTargetStopsTapWithoutDeletingRule() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "nylai-gesture-target-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let monitor = FakeGestureMonitor()
        let availability = TestAvailabilityFlag()
        let controller = MouseGestureController(
            store: MouseGestureConfigurationStore(fileURL: storeURL),
            eventMonitor: monitor,
            shortcutSender: FakeGestureShortcutSender(),
            performNylaiAction: { _ in },
            isNylaiActionAvailable: { _ in availability.value }
        )
        try controller.addRule(MouseGestureRule(
            path: GesturePath([.right]),
            action: .nylai(.captureInteractive)
        ))
        controller.start(requestPermission: false)
        XCTAssertTrue(monitor.isRunning)

        availability.value = false
        controller.refreshActionAvailability()

        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(controller.runtimeStatus, .available)
        XCTAssertEqual(controller.configuration?.rules.count, 1)
    }

    @MainActor
    func testShortcutGestureRequestsAccessAndDoesNotSendWhenDenied() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "nylai-gesture-shortcut-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let monitor = FakeGestureMonitor()
        let sender = FakeGestureShortcutSender()
        sender.canSend = false
        var errors: [Error] = []
        let controller = MouseGestureController(
            store: MouseGestureConfigurationStore(fileURL: storeURL),
            eventMonitor: monitor,
            shortcutSender: sender,
            performNylaiAction: { _ in },
            isNylaiActionAvailable: { _ in true },
            presentError: { errors.append($0) }
        )
        try controller.addRule(MouseGestureRule(
            path: GesturePath([.up]),
            action: .sendShortcut(ShortcutKey(keyCode: 9, modifiers: [.command]))
        ))
        controller.start(requestPermission: false)

        XCTAssertTrue(monitor.send(.rightMouseDown(CGPoint(x: 100, y: 100))))
        XCTAssertTrue(monitor.send(.rightMouseDragged(CGPoint(x: 100, y: 160))))
        XCTAssertTrue(monitor.send(.rightMouseUp(CGPoint(x: 100, y: 160))))
        await waitForActions(1, actions: { sender.accessRequestCount })

        XCTAssertEqual(sender.accessRequestCount, 1)
        XCTAssertTrue(sender.sent.isEmpty)
        XCTAssertEqual(errors.first as? MouseGestureExecutionError, .cannotSendShortcut)
    }

    @MainActor
    func testMatchedShortcutGestureSendsExactlyOnce() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "nylai-gesture-shortcut-success-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let monitor = FakeGestureMonitor()
        let sender = FakeGestureShortcutSender()
        let expected = ShortcutKey(keyCode: 8, modifiers: [.command, .shift])
        let controller = MouseGestureController(
            store: MouseGestureConfigurationStore(fileURL: storeURL),
            eventMonitor: monitor,
            shortcutSender: sender,
            performNylaiAction: { _ in },
            isNylaiActionAvailable: { _ in true }
        )
        try controller.addRule(MouseGestureRule(
            path: GesturePath([.left]),
            action: .sendShortcut(expected)
        ))
        controller.start(requestPermission: false)

        XCTAssertTrue(monitor.send(.rightMouseDown(CGPoint(x: 200, y: 100))))
        XCTAssertTrue(monitor.send(.rightMouseDragged(CGPoint(x: 140, y: 100))))
        XCTAssertTrue(monitor.send(.rightMouseUp(CGPoint(x: 140, y: 100))))
        await waitForActions(1, actions: { sender.sent.count })

        XCTAssertEqual(sender.sent, [expected])
        XCTAssertEqual(sender.accessRequestCount, 0)
    }

    @MainActor
    func testNewEmptyConfigurationBacksUpCorruptFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "nylai-gesture-reset-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "mouse-gestures.json")
        try Data("not-json".utf8).write(to: storeURL)
        let store = MouseGestureConfigurationStore(fileURL: storeURL)
        let controller = MouseGestureController(
            store: store,
            eventMonitor: FakeGestureMonitor(),
            shortcutSender: FakeGestureShortcutSender(),
            performNylaiAction: { _ in },
            isNylaiActionAvailable: { _ in true }
        )
        controller.start(requestPermission: false)

        try controller.useNewEmptyConfiguration()

        XCTAssertEqual(controller.configuration, .defaults)
        XCTAssertNil(controller.loadError)
        XCTAssertEqual(controller.runtimeStatus, .available)
        let files = try FileManager.default.contentsOfDirectory(
            atPath: directory.path(percentEncoded: false)
        )
        XCTAssertTrue(files.contains { $0.hasPrefix("mouse-gestures.corrupt-") })
        XCTAssertEqual(try store.load(), .defaults)
    }

    private func waitForActions(
        _ count: Int,
        actions: @escaping @MainActor () -> Int
    ) async {
        for _ in 0..<100 where actions() < count {
            await Task.yield()
        }
    }
}

@MainActor
private final class TestSuppressionFlag {
    var value = false
}

@MainActor
private final class TestAvailabilityFlag {
    var value = true
}

@MainActor
private final class TestFrontmostApplication {
    var value: GestureFrontmostApplication? = GestureFrontmostApplication(
        bundleIdentifier: "com.example.Editor",
        processIdentifier: 42
    )
}

@MainActor
private final class FakeGestureMonitor: MouseGestureEventMonitoring {
    private var handler: (@MainActor (MouseGestureInput) -> Bool)?
    private var failure: (@MainActor (String) -> Void)?
    private(set) var restoredClicks: [CGPoint] = []
    private(set) var isRunning = false

    func start(
        handler: @escaping @MainActor (MouseGestureInput) -> Bool,
        onFailure: @escaping @MainActor (String) -> Void
    ) throws {
        self.handler = handler
        failure = onFailure
        isRunning = true
    }

    func stop() {
        handler = nil
        failure = nil
        isRunning = false
    }

    func restoreRightClick(at point: CGPoint) {
        restoredClicks.append(point)
    }

    func send(_ input: MouseGestureInput) -> Bool {
        handler?(input) ?? false
    }

    func fail(_ reason: String) {
        failure?(reason)
    }
}

@MainActor
private final class FakeGestureShortcutSender: GestureShortcutSending {
    var canSend = true
    private(set) var sent: [ShortcutKey] = []
    private(set) var accessRequestCount = 0

    func requestAccess() -> Bool {
        accessRequestCount += 1
        return canSend
    }

    func send(_ shortcut: ShortcutKey) -> Bool {
        sent.append(shortcut)
        return canSend
    }
}
