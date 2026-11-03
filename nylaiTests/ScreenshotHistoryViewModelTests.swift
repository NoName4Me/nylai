import AppKit
import XCTest
@testable import nylai

@MainActor
final class ScreenshotHistoryViewModelTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nylai-history-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testCopyAndSaveDoNotCreateAdditionalHistoryRecords() async throws {
        let store = ScreenshotHistoryStore(directory: directory)
        let record = try XCTUnwrap(try store.add(try makeImage()))
        let paster = HistoryRecordingPaster()
        let saver = HistoryRecordingSaver()
        let model = ScreenshotHistoryViewModel(
            store: store,
            paster: paster,
            saver: saver,
            pinnedImageManager: PinnedImageManager()
        )

        model.copy(record)
        model.save(record)
        try await waitUntil { saver.saveCount == 1 }

        XCTAssertEqual(paster.copyCount, 1)
        XCTAssertEqual(saver.saveCount, 1)
        XCTAssertEqual(store.records, [record])
        XCTAssertNil(model.errorMessage)
    }

    func testMissingFileShowsErrorWithoutWritingClipboard() throws {
        let store = ScreenshotHistoryStore(directory: directory)
        let record = try XCTUnwrap(try store.add(try makeImage()))
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent(record.imageFileName)
        )
        let paster = HistoryRecordingPaster()
        let model = ScreenshotHistoryViewModel(
            store: store,
            paster: paster,
            saver: HistoryRecordingSaver(),
            pinnedImageManager: PinnedImageManager()
        )

        model.copy(record)

        XCTAssertEqual(paster.copyCount, 0)
        XCTAssertNotNil(model.errorMessage)
    }

    func testPinUsesSharedPinnedImageManager() throws {
        let store = ScreenshotHistoryStore(directory: directory)
        let record = try XCTUnwrap(try store.add(try makeImage()))
        let manager = PinnedImageManager()
        let model = ScreenshotHistoryViewModel(
            store: store,
            paster: HistoryRecordingPaster(),
            saver: HistoryRecordingSaver(),
            pinnedImageManager: manager
        )

        model.pin(record)
        defer { manager.closeAll() }

        XCTAssertEqual(manager.windowCount, 1)
        XCTAssertEqual(store.records, [record])
    }

    private func makeImage() throws -> CGImage {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 40,
            height: 30,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        return try XCTUnwrap(context.makeImage())
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("等待条件超时。")
    }
}

@MainActor
private final class HistoryRecordingPaster: ScreenshotPasting {
    private(set) var copyCount = 0

    func copy(_ image: CGImage) throws {
        copyCount += 1
    }
}

@MainActor
private final class HistoryRecordingSaver: ScreenshotSaving {
    private(set) var saveCount = 0

    func save(_ image: CGImage) async throws -> URL? {
        saveCount += 1
        return URL(fileURLWithPath: "/tmp/nylai-history-test.png")
    }
}
