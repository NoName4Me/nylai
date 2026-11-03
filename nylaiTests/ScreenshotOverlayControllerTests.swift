import AppKit
import XCTest
@testable import nylai

final class ScreenshotOverlayControllerTests: XCTestCase {
    @MainActor
    func testEscapeInvokesCancelCallback() throws {
        let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        var calls = 0
        view.onCancel = { calls += 1 }
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ))

        view.keyDown(with: event)

        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testCancelButtonInvokesCancelCallback() throws {
        let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        var calls = 0
        view.onCancel = { calls += 1 }
        view.setSelection(CGRect(x: 40, y: 40, width: 400, height: 300), notify: false)
        let cancelButton = try XCTUnwrap(findButton(titled: "取消", in: view))

        cancelButton.performClick(nil)

        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testToolbarHidesWhenCanvasCannotFitIt() throws {
        let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        view.setSelection(CGRect(x: 20, y: 20, width: 80, height: 50), notify: false)

        XCTAssertNil(findButton(titled: "取消", in: view))
    }

    @MainActor
    func testClickOnTargetPreviewConfirmsTargetWithoutCreatingRegion() throws {
        let content = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = content
        content.highlightedTargetRect = CGRect(x: 10, y: 10, width: 100, height: 80)
        var pickedPoint: CGPoint?
        content.onTargetPick = { pickedPoint = $0 }
        let point = CGPoint(x: 50, y: 50)
        let down = try makeMouseEvent(.leftMouseDown, at: point)
        let up = try makeMouseEvent(.leftMouseUp, at: point)

        content.mouseDown(with: down)
        content.mouseUp(with: up)

        XCTAssertNil(content.selection)
        XCTAssertNotNil(pickedPoint)
    }

    @MainActor
    func testDragFromDisplayPreviewCreatesManualSelection() throws {
        let content = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = content
        content.highlightedTargetRect = content.bounds
        var pickedPoint: CGPoint?
        content.onTargetPick = { pickedPoint = $0 }
        let start = CGPoint(x: 20, y: 20)
        let end = CGPoint(x: 120, y: 90)

        content.mouseDown(with: try makeMouseEvent(.leftMouseDown, in: content, at: start))
        content.mouseDragged(with: try makeMouseEvent(.leftMouseDragged, in: content, at: end))
        content.mouseUp(with: try makeMouseEvent(.leftMouseUp, in: content, at: end))

        XCTAssertEqual(
            content.selection,
            CGRect(x: 20, y: 20, width: 100, height: 70)
        )
        XCTAssertNil(pickedPoint)
        XCTAssertNil(content.highlightedTargetRect)
    }

    @MainActor
    func testObjectDragMovesAnnotationWithoutMovingScreenshotSelection() throws {
        let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        _ = attachToWindow(view)
        view.sourcePixelSize = try PixelSize(width: 200, height: 120)
        let selection = CGRect(x: 0, y: 0, width: 200, height: 120)
        let annotation = ScreenshotAnnotation(
            rect: PixelRect(x: 20, y: 20, width: 100, height: 60)
        )
        view.setSelection(selection, notify: false)
        view.setAnnotations([annotation], selectedID: annotation.id)
        view.setTool(.objectSelection)
        var changedRect: PixelRect?
        view.onAnnotationChanged = { _, rect, _ in changedRect = rect }

        view.mouseDown(with: try makeMouseEvent(.leftMouseDown, in: view, at: CGPoint(x: 50, y: 20)))
        view.mouseDragged(with: try makeMouseEvent(.leftMouseDragged, in: view, at: CGPoint(x: 65, y: 35)))
        view.mouseUp(with: try makeMouseEvent(.leftMouseUp, in: view, at: CGPoint(x: 65, y: 35)))

        XCTAssertEqual(changedRect, PixelRect(x: 35, y: 35, width: 100, height: 60))
        XCTAssertEqual(view.selection, selection)
    }

    @MainActor
    func testSelectedObjectHandleResizesAnnotationWithoutMovingScreenshotSelection() throws {
        let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        _ = attachToWindow(view)
        view.sourcePixelSize = try PixelSize(width: 200, height: 120)
        let selection = CGRect(x: 0, y: 0, width: 200, height: 120)
        let annotation = ScreenshotAnnotation(
            rect: PixelRect(x: 20, y: 20, width: 30, height: 20),
            style: ScreenshotAnnotationStyle(
                color: .defaultRed,
                lineWidth: 7,
                lineStyle: .solid
            )
        )
        view.setSelection(selection, notify: false)
        view.setAnnotations([annotation], selectedID: annotation.id)
        view.setTool(.objectSelection)
        var changedRect: PixelRect?
        view.onAnnotationChanged = { _, rect, _ in changedRect = rect }

        view.mouseDown(with: try makeMouseEvent(.leftMouseDown, in: view, at: CGPoint(x: 45, y: 35)))
        view.mouseDragged(with: try makeMouseEvent(.leftMouseDragged, in: view, at: CGPoint(x: 55, y: 45)))
        view.mouseUp(with: try makeMouseEvent(.leftMouseUp, in: view, at: CGPoint(x: 55, y: 45)))

        XCTAssertEqual(changedRect, PixelRect(x: 20, y: 20, width: 40, height: 30))
        XCTAssertEqual(view.selection, selection)
        if let annotation = view.annotations.first {
            XCTAssertEqual(annotation.rect.width, 40)
            XCTAssertEqual(annotation.rect.height, 30)
            XCTAssertEqual(annotation.style.lineWidth, 7)
        }
    }

    @MainActor
    func testStepAnnotationUsesFourProportionalHandles() throws {
        let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        _ = attachToWindow(view)
        view.sourcePixelSize = try PixelSize(width: 200, height: 120)
        view.setSelection(CGRect(x: 0, y: 0, width: 200, height: 120), notify: false)
        let annotation = ScreenshotAnnotation(
            rect: PixelRect(x: 20, y: 20, width: 40, height: 40),
            kind: .step,
            style: ScreenshotAnnotationStyle(
                color: .defaultRed,
                lineWidth: 40,
                lineStyle: .solid
            )
        )
        view.setAnnotations([annotation], selectedID: annotation.id)
        view.setTool(.objectSelection)
        var changedRect: PixelRect?
        view.onAnnotationChanged = { _, rect, _ in changedRect = rect }

        view.mouseDown(with: try makeMouseEvent(
            .leftMouseDown,
            in: view,
            at: CGPoint(x: 60, y: 60)
        ))
        view.mouseDragged(with: try makeMouseEvent(
            .leftMouseDragged,
            in: view,
            at: CGPoint(x: 70, y: 65)
        ))
        view.mouseUp(with: try makeMouseEvent(
            .leftMouseUp,
            in: view,
            at: CGPoint(x: 70, y: 65)
        ))

        let resized = try XCTUnwrap(changedRect)
        XCTAssertEqual(resized.width, resized.height)
        XCTAssertGreaterThan(resized.width, 40)
    }

    @MainActor
    func testSelectionToolMovesCropInsteadOfAnnotation() throws {
        let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        _ = attachToWindow(view)
        view.sourcePixelSize = try PixelSize(width: 200, height: 120)
        let annotation = ScreenshotAnnotation(
            rect: PixelRect(x: 20, y: 20, width: 30, height: 20)
        )
        view.setSelection(CGRect(x: 20, y: 20, width: 50, height: 30), notify: false)
        view.setAnnotations([annotation], selectedID: annotation.id)
        view.setTool(.selection)
        var changedAnnotation: PixelRect?
        view.onAnnotationChanged = { _, rect, _ in changedAnnotation = rect }

        view.mouseDown(with: try makeMouseEvent(.leftMouseDown, in: view, at: CGPoint(x: 45, y: 35)))
        view.mouseDragged(with: try makeMouseEvent(.leftMouseDragged, in: view, at: CGPoint(x: 55, y: 40)))
        view.mouseUp(with: try makeMouseEvent(.leftMouseUp, in: view, at: CGPoint(x: 55, y: 40)))

        XCTAssertEqual(view.selection, CGRect(x: 30, y: 25, width: 50, height: 30))
        XCTAssertNil(changedAnnotation)
    }

    @MainActor
    func testWindowSourceSelectionCanResizeThenMoveWithinOriginalBounds() throws {
        let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        _ = attachToWindow(view)
        view.sourcePixelSize = try PixelSize(width: 200, height: 120)
        view.isWindowSource = true
        view.setTool(.selection)
        view.setSelection(view.bounds, notify: false)

        // Full-screen selections keep their edge handles outside the visible canvas.
        view.mouseDown(with: try makeMouseEvent(.leftMouseDown, in: view, at: CGPoint(x: 200, y: 120)))
        view.mouseDragged(with: try makeMouseEvent(.leftMouseDragged, in: view, at: CGPoint(x: 190, y: 110)))
        view.mouseUp(with: try makeMouseEvent(.leftMouseUp, in: view, at: CGPoint(x: 190, y: 110)))

        XCTAssertEqual(view.selection, CGRect(x: 0, y: 0, width: 190, height: 110))

        view.mouseDown(with: try makeMouseEvent(.leftMouseDown, in: view, at: CGPoint(x: 95, y: 55)))
        view.mouseDragged(with: try makeMouseEvent(.leftMouseDragged, in: view, at: CGPoint(x: 100, y: 60)))
        view.mouseUp(with: try makeMouseEvent(.leftMouseUp, in: view, at: CGPoint(x: 100, y: 60)))

        XCTAssertEqual(view.selection, CGRect(x: 5, y: 5, width: 190, height: 110))
    }

    @MainActor
    func testRectangleToolCreatesSourcePixelAnnotation() throws {
        let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        _ = attachToWindow(view)
        view.sourcePixelSize = try PixelSize(width: 200, height: 120)
        view.setSelection(CGRect(x: 0, y: 0, width: 200, height: 120), notify: false)
        view.setTool(.rectangle)
        var createdAnnotation: ScreenshotAnnotation?
        view.onAnnotationCreated = { createdAnnotation = $0 }

        view.mouseDown(with: try makeMouseEvent(.leftMouseDown, in: view, at: CGPoint(x: 10, y: 10)))
        view.mouseDragged(with: try makeMouseEvent(.leftMouseDragged, in: view, at: CGPoint(x: 50, y: 40)))
        view.mouseUp(with: try makeMouseEvent(.leftMouseUp, in: view, at: CGPoint(x: 50, y: 40)))

        XCTAssertEqual(createdAnnotation?.kind, .rectangle)
        XCTAssertEqual(createdAnnotation?.rect, PixelRect(x: 10, y: 10, width: 40, height: 30))
        XCTAssertEqual(createdAnnotation?.start, PixelPoint(x: 10, y: 10))
        XCTAssertEqual(createdAnnotation?.end, PixelPoint(x: 50, y: 40))
    }

    @MainActor
    func testCommandZDeleteAndRedoShortcutsInvokeCallbacks() throws {
        let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        var undoCount = 0
        var redoCount = 0
        var deleteCount = 0
        view.onUndo = { undoCount += 1 }
        view.onRedo = { redoCount += 1 }
        view.onDelete = { deleteCount += 1 }
        view.canUndo = true
        view.canRedo = true
        view.canDelete = true

        view.keyDown(with: try makeKeyEvent(characters: "z", keyCode: 6, modifiers: [.command]))
        view.keyDown(with: try makeKeyEvent(
            characters: "Z",
            keyCode: 6,
            modifiers: [.command, .shift]
        ))
        view.keyDown(with: try makeKeyEvent(characters: "\u{7f}", keyCode: 51))

        XCTAssertEqual(undoCount, 1)
        XCTAssertEqual(redoCount, 1)
        XCTAssertEqual(deleteCount, 1)
    }

    @MainActor
    func testScrollCaptureButtonAndShortcutInvokeCallback() throws {
        let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        var calls = 0
        view.onScrollCapture = { calls += 1 }
        view.setSelection(CGRect(x: 40, y: 40, width: 400, height: 300), notify: false)

        let button = try XCTUnwrap(findButton(titled: "滚动截图", in: view))
        button.performClick(nil)
        view.keyDown(with: try makeKeyEvent(
            characters: "r",
            keyCode: 15,
            modifiers: [.command, .control]
        ))

        XCTAssertEqual(calls, 2)
    }

    @MainActor
    func testBlurToolIsNotPresentAndCornerHandleUpdatesAppearance() throws {
        let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        _ = attachToWindow(view)
        let selection = CGRect(x: 80, y: 80, width: 400, height: 300)
        view.outputAppearance = ScreenshotOutputAppearance(roundedCornersEnabled: false, cornerRadius: 0)
        view.setSelection(selection, notify: false)
        XCTAssertNil(findButton(titled: "模糊", in: view))
        var appearance: ScreenshotOutputAppearance?
        view.onOutputAppearanceChanged = { appearance = $0 }
        let handle = SelectionCornerRadiusGeometry.handleCenter(in: selection, radius: 0)
        let end = CGPoint(x: handle.x - 24, y: handle.y - 20)

        view.mouseDown(with: try makeMouseEvent(.leftMouseDown, in: view, at: handle))
        view.mouseDragged(with: try makeMouseEvent(.leftMouseDragged, in: view, at: end))
        view.mouseUp(with: try makeMouseEvent(.leftMouseUp, in: view, at: end))

        XCTAssertEqual(view.selection, selection)
        XCTAssertEqual(appearance?.roundedCornersEnabled, true)
        XCTAssertEqual(appearance?.cornerRadius, 22)
    }

    @MainActor
    func testTwoToolbarGroupsRenderWithoutOverlap() throws {
        let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        _ = attachToWindow(view)
        view.sourcePixelSize = try PixelSize(width: 1000, height: 700)
        view.outputAppearance = ScreenshotOutputAppearance(roundedCornersEnabled: false, cornerRadius: 0)
        view.setSelection(CGRect(x: 180, y: 140, width: 500, height: 300), notify: false)
        var editing: NSView? = try XCTUnwrap(findButton(titled: "矩形", in: view))
        var output: NSView? = try XCTUnwrap(findButton(titled: "复制", in: view))
        while editing?.superview !== view { editing = editing?.superview }
        while output?.superview !== view { output = output?.superview }
        XCTAssertFalse(try XCTUnwrap(editing).frame.intersects(try XCTUnwrap(output).frame))

    }

    @MainActor
    func testScrollCaptureActionPassesCurrentSelectionAndClosesOverlay() async throws {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.screens.first,
              screen.frame.width >= 820,
              screen.frame.height >= 700 else {
            throw XCTSkip("当前测试进程没有可用于覆盖层工具栏的屏幕。")
        }
        var request: ScrollCaptureStartRequest?
        let controller = ScreenshotOverlayController(
            displayCapturer: ImmediateOverlayCapturer(
                image: try makeScreenImage(size: screen.frame.size)
            ),
            windowCapturer: EmptyWindowCapturer(),
            startScrollCapture: { request = $0 },
            presentError: { _ in }
        )
        await controller.begin()
        let view = try XCTUnwrap(overlayView(in: NSApp.windows))
        let selectedRect = CGRect(x: 20, y: 20, width: 240, height: 160)
        view.setSelection(selectedRect, notify: true)
        XCTAssertEqual(controller.session.phase, .editing)
        XCTAssertNotNil(controller.session.selection)

        let button = try XCTUnwrap(findButton(titled: "滚动截图", in: view))
        XCTAssertTrue(button.isEnabled)
        button.performClick(nil)

        let captured = try XCTUnwrap(request)
        XCTAssertEqual(captured.displayFrame, screen.frame)
        XCTAssertEqual(captured.selectionGlobalRect.width, selectedRect.width)
        XCTAssertEqual(captured.selectionGlobalRect.height, selectedRect.height)
        XCTAssertEqual(captured.pointPixelScale, 1)
        XCTAssertEqual(controller.session.phase, .ended)
    }

    @MainActor
    func testConcurrentTriggerKeepsSingleCaptureAndAutoTargetsDisplay() async throws {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.screens.first else {
            throw XCTSkip("当前测试进程没有可用 NSScreen。")
        }
        let image = try makeScreenImage(size: screen.frame.size)
        let capturer = SuspendedOverlayCapturer()
        var errors: [Error] = []
        let controller = ScreenshotOverlayController(
            displayCapturer: capturer,
            windowCapturer: EmptyWindowCapturer(),
            presentError: { errors.append($0) }
        )
        let first = Task {
            await controller.begin()
        }
        for _ in 0..<100 where capturer.continuation == nil {
            try await Task.sleep(for: .milliseconds(1))
        }
        let continuation = try XCTUnwrap(capturer.continuation)
        XCTAssertTrue(controller.isCapturing)

        await controller.begin()
        XCTAssertEqual(capturer.calls, 1)

        continuation.resume(returning: image)
        await first.value

        XCTAssertFalse(controller.isCapturing)
        XCTAssertEqual(controller.session.phase, .selecting)
        XCTAssertNil(controller.session.selection)
        XCTAssertEqual(controller.session.targets.count, 1)
        XCTAssertEqual(
            controller.session.targets.first?.frame,
            screen.frame
        )
        XCTAssertTrue(errors.isEmpty)

        controller.close()
        XCTAssertEqual(controller.session.phase, .ended)
    }

    @MainActor
    func testOverlayHighlightsWindowUnderPointerOnOpen() async throws {
        let fixture = try await beginOverlayWithHistory()
        defer { fixture.cleanup() }

        let view = try XCTUnwrap(overlayView(in: NSApp.windows))
        XCTAssertNotNil(view.highlightedTargetRect)
    }

    @MainActor
    func testSuccessfulOutputRecordsExactlyOneHistoryItem() async throws {
        let fixture = try await beginOverlayWithHistory()
        defer { fixture.cleanup() }

        try selectEntireOverlay(for: fixture.controller)
        try clickOverlayAction("复制", for: fixture.controller)
        try await waitUntil { fixture.history.records.count == 1 }

        XCTAssertEqual(fixture.history.records.count, 1)
        XCTAssertEqual(fixture.copyCount(), 1)
        XCTAssertEqual(fixture.controller.session.phase, .ended)

        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(fixture.history.records.count, 1)
    }

    @MainActor
    func testDisabledHistoryDoesNotRecordSuccessfulOutput() async throws {
        let fixture = try await beginOverlayWithHistory(historyEnabled: false)
        defer { fixture.cleanup() }

        try selectEntireOverlay(for: fixture.controller)
        try clickOverlayAction("复制", for: fixture.controller)
        try await waitUntil { fixture.controller.session.phase == .ended }

        XCTAssertEqual(fixture.copyCount(), 1)
        XCTAssertTrue(fixture.history.records.isEmpty)
    }

    @MainActor
    func testCancelledSaveDoesNotRecordHistoryOrEndSession() async throws {
        let saver = CancelledOverlaySaver()
        let fixture = try await beginOverlayWithHistory(saver: saver)
        defer { fixture.cleanup() }

        try selectEntireOverlay(for: fixture.controller)
        try clickOverlayAction("保存", for: fixture.controller)
        try await waitUntil { saver.saveCount == 1 }
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertTrue(fixture.history.records.isEmpty)
        XCTAssertEqual(fixture.controller.session.phase, .editing)
    }

    @MainActor
    func testFailedOutputDoesNotRecordHistory() async throws {
        let paster = FailingOverlayPaster()
        let fixture = try await beginOverlayWithHistory(paster: paster)
        defer { fixture.cleanup() }

        try selectEntireOverlay(for: fixture.controller)
        try clickOverlayAction("复制", for: fixture.controller)
        try await waitUntil { paster.copyCount == 1 }
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertTrue(fixture.history.records.isEmpty)
        XCTAssertEqual(fixture.controller.session.phase, .editing)
    }

    private func makeScreenImage(size: CGSize) throws -> CGImage {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.15, green: 0.3, blue: 0.45, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    @MainActor
    private func beginOverlayWithHistory(
        historyEnabled: Bool = true,
        paster: any ScreenshotPasting = RecordingOverlayPaster(),
        saver: any ScreenshotSaving = CancelledOverlaySaver()
    ) async throws -> OverlayHistoryFixture {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.screens.first else {
            throw XCTSkip("当前测试进程没有可用 NSScreen。")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nylai-overlay-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let history = ScreenshotHistoryStore(directory: directory)
        let controller = ScreenshotOverlayController(
            displayCapturer: ImmediateOverlayCapturer(
                image: try makeScreenImage(size: screen.frame.size)
            ),
            windowCapturer: EmptyWindowCapturer(),
            saver: saver,
            paster: paster,
            outputAppearanceStore: Self.isolatedAppearanceStore(),
            historyStore: history,
            isHistoryEnabled: { historyEnabled },
            presentError: { _ in }
        )
        await controller.begin()
        return OverlayHistoryFixture(
            controller: controller,
            history: history,
            copyCount: {
                (paster as? RecordingOverlayPaster)?.copyCount ?? 0
            },
            directory: directory
        )
    }

    @MainActor
    private func selectEntireOverlay(for controller: ScreenshotOverlayController) throws {
        let view = try XCTUnwrap(overlayView(in: NSApp.windows))
        view.setSelection(view.bounds, notify: true)
        XCTAssertEqual(controller.session.phase, .editing)
    }

    @MainActor
    private func clickOverlayAction(
        _ title: String,
        for controller: ScreenshotOverlayController
    ) throws {
        let view = try XCTUnwrap(overlayView(in: NSApp.windows))
        let button = try XCTUnwrap(findButton(titled: title, in: view))
        XCTAssertTrue(button.isEnabled)
        XCTAssertNotNil(button.target)
        XCTAssertNotNil(button.action)
        button.performClick(nil)
    }

    @MainActor
    private func overlayView(in windows: [NSWindow]) -> ScreenshotOverlayView? {
        for window in windows {
            guard window.isVisible, let contentView = window.contentView else { continue }
            if let view = findOverlayView(in: contentView) {
                return view
            }
        }
        return nil
    }

    @MainActor
    private func findOverlayView(in view: NSView) -> ScreenshotOverlayView? {
        if let overlay = view as? ScreenshotOverlayView {
            return overlay
        }
        for subview in view.subviews {
            if let overlay = findOverlayView(in: subview) {
                return overlay
            }
        }
        return nil
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("等待条件超时。")
    }

    private static func isolatedAppearanceStore() -> ScreenshotOutputAppearanceStore {
        let suite = "ScreenshotOverlayControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return ScreenshotOutputAppearanceStore(defaults: defaults)
    }

    private func makeMouseEvent(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    @MainActor
    private func makeMouseEvent(
        _ type: NSEvent.EventType,
        in view: NSView,
        at viewPoint: CGPoint
    ) throws -> NSEvent {
        try makeMouseEvent(
            type,
            at: CGPoint(x: viewPoint.x, y: view.bounds.height - viewPoint.y)
        )
    }

    private func makeKeyEvent(
        characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters.lowercased(),
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    @MainActor
    private func attachToWindow(_ view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        return window
    }

    @MainActor
    private func findButton(titled title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title {
            return button
        }
        for subview in view.subviews {
            if let button = findButton(titled: title, in: subview) {
                return button
            }
        }
        return nil
    }
}

@MainActor
private final class SuspendedOverlayCapturer: ScreenCapturing {
    var calls = 0
    var continuation: CheckedContinuation<CGImage, Error>?

    func captureDisplay(_ displayID: CGDirectDisplayID) async throws -> CGImage {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
}

@MainActor
private final class EmptyWindowCapturer: WindowCapturing {
    func windowCandidates() async throws -> [WindowCaptureCandidate] {
        []
    }

    func captureWindow(_ windowID: CGWindowID) async throws -> CGImage {
        throw ScreenshotError.windowUnavailable
    }
}

@MainActor
private final class ImmediateOverlayCapturer: ScreenCapturing {
    let image: CGImage

    init(image: CGImage) {
        self.image = image
    }

    func captureDisplay(_ displayID: CGDirectDisplayID) async throws -> CGImage {
        image
    }
}

@MainActor
private final class RecordingOverlayPaster: ScreenshotPasting {
    private(set) var copyCount = 0

    func copy(_ image: CGImage) throws {
        copyCount += 1
    }
}

@MainActor
private final class FailingOverlayPaster: ScreenshotPasting {
    private(set) var copyCount = 0

    func copy(_ image: CGImage) throws {
        copyCount += 1
        throw ScreenshotOutputError.clipboardWriteFailed
    }
}

@MainActor
private final class CancelledOverlaySaver: ScreenshotSaving {
    private(set) var saveCount = 0

    func save(_ image: CGImage) async throws -> URL? {
        saveCount += 1
        return nil
    }
}

@MainActor
private struct OverlayHistoryFixture {
    let controller: ScreenshotOverlayController
    let history: ScreenshotHistoryStore
    let copyCount: @MainActor () -> Int
    let directory: URL

    @MainActor
    func cleanup() {
        controller.close()
        try? FileManager.default.removeItem(at: directory)
    }
}
