import AppKit
import XCTest
@testable import nylai

@MainActor
final class LongScreenshotEditorTests: XCTestCase {
    func testEditorUsesSelectionSizedBorderlessWindowAndKeepsNormalTools() throws {
        let preferredFrame = CGRect(x: 120, y: 180, width: 520, height: 440)
        let controller = try LongScreenshotEditorWindowController(
            image: makeImage(width: 900, height: 600),
            pointPixelScale: 1,
            preferredFrame: preferredFrame,
            outputAppearanceStore: Self.isolatedAppearanceStore()
        )
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let root = try XCTUnwrap(window.contentView)

        XCTAssertEqual(window.styleMask, [.borderless, .nonactivatingPanel])
        XCTAssertEqual(window.frame.size, preferredFrame.size)
        let surfaces = (window.childWindows ?? []).compactMap(\.contentView) + [root]
        XCTAssertTrue(surfaces.contains { findButton(titled: "矩形", in: $0) != nil })
        XCTAssertTrue(surfaces.contains { findButton(titled: "复制", in: $0) != nil })
        XCTAssertTrue(surfaces.contains { findButton(titled: "放大", in: $0) != nil })
        XCTAssertEqual(window.childWindows?.count, 2)
        XCTAssertNil(findButton(titled: "选区", in: root))
        XCTAssertNil(findButton(titled: "滚动截图", in: root))
    }

    func testSelectionCanCropLongScreenshotBeforeOutput() async throws {
        let paster = LongScreenshotRecordingPaster()
        let model = try LongScreenshotEditorModel(
            image: makeImage(),
            pointPixelScale: 1,
            outputAppearanceStore: Self.isolatedAppearanceStore(),
            paster: paster
        )

        model.beginSelectionInteraction()
        model.updateSelection(
            viewRect: CGRect(x: 2, y: 4, width: 8, height: 12),
            viewSize: CGSize(width: 20, height: 40)
        )
        model.endInteraction()
        XCTAssertEqual(
            model.session.selection,
            PixelRect(x: 2, y: 4, width: 8, height: 12)
        )

        model.copy()
        let expectedSize = try PixelSize(width: 8, height: 12)
        try await waitUntil {
            paster.copiedSizes == [expectedSize]
        }
    }

    func testRepeatedOutputsRecordOnlyOneHistoryEntryPerEditorSession() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "nylai-long-history-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = ScreenshotHistoryStore(directory: directory)
        let paster = LongScreenshotRecordingPaster()
        let model = try LongScreenshotEditorModel(
            image: makeImage(),
            pointPixelScale: 1,
            outputAppearanceStore: Self.isolatedAppearanceStore(),
            paster: paster,
            historyStore: history,
            isHistoryEnabled: { true }
        )

        model.copy()
        try await waitUntil {
            paster.copyCount == 1 && model.session.phase == .editing
        }
        model.copy()
        try await waitUntil {
            paster.copyCount == 2 && model.session.phase == .editing
        }

        XCTAssertEqual(history.records.count, 1)
    }

    func testClosingWhileSaveIgnoresCancellationPreventsHistoryRecord() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "nylai-long-close-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = ScreenshotHistoryStore(directory: directory)
        let saver = SuspendedLongScreenshotSaver()
        let model = try LongScreenshotEditorModel(
            image: makeImage(),
            pointPixelScale: 1,
            saver: saver,
            historyStore: history,
            isHistoryEnabled: { true }
        )

        model.save()
        try await waitUntil { saver.isStarted }
        model.close()
        XCTAssertEqual(model.session.phase, .ended)
        saver.resume(returning: URL(fileURLWithPath: "/tmp/nylai-never-saved.png"))
        try await waitUntil { saver.isFinished }

        XCTAssertTrue(history.records.isEmpty)
    }

    func testClosingWhileSaveFinishesKeepsSessionCancelled() async throws {
        let saver = SuspendedLongScreenshotSaver()
        let model = try LongScreenshotEditorModel(
            image: makeImage(),
            pointPixelScale: 1,
            saver: saver
        )

        model.save()
        try await waitUntil { saver.isStarted }
        model.close()
        XCTAssertEqual(model.session.phase, .ended)
        saver.resume(returning: URL(fileURLWithPath: "/tmp/nylai-closed-save.png"))
        try await waitUntil { saver.isFinished }
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(model.session.phase, .ended)
        XCTAssertNil(model.session.selection)
        XCTAssertNil(model.session.source)
    }

    func testPinOutputClosesEditorOnlyAfterPinnedImageIsCreated() async throws {
        var pinnedSizes: [PixelSize] = []
        var closeCount = 0
        let model = try LongScreenshotEditorModel(
            image: makeImage(),
            pointPixelScale: 1,
            outputAppearanceStore: Self.isolatedAppearanceStore(),
            pinImage: { image in
                if let size = try? PixelSize(width: image.width, height: image.height) {
                    pinnedSizes.append(size)
                }
            }
        )

        model.pin { closeCount += 1 }
        try await waitUntil { pinnedSizes.count == 1 }
        try await waitUntil { closeCount == 1 }

        XCTAssertEqual(pinnedSizes, [try PixelSize(width: 20, height: 40)])
        XCTAssertEqual(closeCount, 1)
    }

    private func makeImage(width: Int = 20, height: Int = 40) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
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
        let suite = "LongScreenshotEditorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return ScreenshotOutputAppearanceStore(defaults: defaults)
    }

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
private final class LongScreenshotRecordingPaster: ScreenshotPasting {
    private(set) var copyCount = 0
    private(set) var copiedSizes: [PixelSize] = []

    func copy(_ image: CGImage) throws {
        copyCount += 1
        if let size = try? PixelSize(width: image.width, height: image.height) {
            copiedSizes.append(size)
        }
    }
}

@MainActor
private final class SuspendedLongScreenshotSaver: ScreenshotSaving {
    private var continuation: CheckedContinuation<URL?, Error>?
    private(set) var isStarted = false
    private(set) var isFinished = false

    func save(_ image: CGImage) async throws -> URL? {
        isStarted = true
        defer { isFinished = true }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume(returning url: URL?) {
        continuation?.resume(returning: url)
        continuation = nil
    }
}
