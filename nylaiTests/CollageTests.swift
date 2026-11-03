import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import nylai

@MainActor
final class CollageTests: XCTestCase {
    func testMoveResizeLayerDeleteAndUndoRedo() throws {
        let document = CollageDocument()
        let first = document.add(try makeImage(width: 100, height: 50, color: .red))
        let second = document.add(try makeImage(width: 40, height: 60, color: .blue))

        document.beginInteraction()
        document.updateFrame(CGRect(x: 30, y: 40, width: 100, height: 50), for: first)
        document.endInteraction()
        XCTAssertEqual(document.items.first?.frame, CGRect(x: 30, y: 40, width: 100, height: 50))

        document.undo()
        XCTAssertEqual(document.items.first?.frame, CGRect(x: 100, y: 100, width: 100, height: 50))
        document.redo()
        XCTAssertEqual(document.items.first?.frame, CGRect(x: 30, y: 40, width: 100, height: 50))

        document.select(first)
        XCTAssertTrue(document.canBringForward)
        document.bringForward()
        XCTAssertEqual(document.items.last?.id, first)
        document.sendBackward()
        XCTAssertEqual(document.items.first?.id, first)

        document.select(second)
        document.deleteSelected()
        XCTAssertEqual(document.items.map(\.id), [first])
        document.undo()
        XCTAssertEqual(document.items.map(\.id), [first, second])
    }

    func testHorizontalAndVerticalArrangementUseSixteenPixelGap() throws {
        let document = CollageDocument()
        let first = document.add(try makeImage(width: 100, height: 50, color: .red))
        let second = document.add(try makeImage(width: 40, height: 60, color: .blue))
        document.beginInteraction()
        document.updateFrame(CGRect(x: 300, y: 80, width: 100, height: 50), for: first)
        document.updateFrame(CGRect(x: 20, y: 200, width: 40, height: 60), for: second)
        document.endInteraction()

        document.arrange(.horizontal)
        XCTAssertEqual(document.items[0].frame.minX, 20)
        XCTAssertEqual(document.items[0].frame.minY, 80)
        XCTAssertEqual(document.items[1].frame.minX, 136)
        XCTAssertEqual(document.items[1].frame.minY, 80)

        document.arrange(.vertical)
        XCTAssertEqual(document.items[0].frame.minX, 20)
        XCTAssertEqual(document.items[0].frame.minY, 80)
        XCTAssertEqual(document.items[1].frame.minX, 20)
        XCTAssertEqual(document.items[1].frame.minY, 146)
    }

    func testRenderUsesUnionBoundsIncludingNegativePositionsAndTransparency() throws {
        let document = CollageDocument()
        let red = document.add(try makeImage(width: 20, height: 10, color: .red))
        let blue = document.add(try makeImage(width: 10, height: 20, color: .blue))
        document.beginInteraction()
        document.updateFrame(CGRect(x: -10, y: -5, width: 20, height: 10), for: red)
        document.updateFrame(CGRect(x: 5, y: 0, width: 10, height: 20), for: blue)
        document.endInteraction()

        let rendered = try document.render()
        XCTAssertEqual(rendered.width, 25)
        XCTAssertEqual(rendered.height, 25)
        XCTAssertEqual(pixel(in: rendered, x: 1, y: 24).alpha, 0, accuracy: 0.01)
        let redPixel = pixel(in: rendered, x: 1, y: 1)
        XCTAssertGreaterThan(redPixel.red, 0.8)
        XCTAssertLessThan(redPixel.blue, 0.2)
        let bluePixel = pixel(in: rendered, x: 20, y: 10)
        XCTAssertGreaterThan(bluePixel.blue, 0.8)
    }

    func testRenderRoundsFractionalUnionBoundsOutward() throws {
        let document = CollageDocument()
        let red = document.add(try makeImage(width: 20, height: 10, color: .red))
        let blue = document.add(try makeImage(width: 10, height: 20, color: .blue))
        document.beginInteraction()
        document.updateFrame(CGRect(x: -10.4, y: -5.2, width: 20, height: 10), for: red)
        document.updateFrame(CGRect(x: 4.6, y: -0.7, width: 10, height: 20), for: blue)
        document.endInteraction()

        let rendered = try document.render()

        XCTAssertEqual(rendered.width, 26)
        XCTAssertEqual(rendered.height, 26)
        let rightEdgeCoverage = (0..<rendered.height).reduce(into: 0) { count, y in
            if pixel(in: rendered, x: 25, y: y).alpha > 0.5 {
                count += 1
            }
        }
        XCTAssertGreaterThan(rightEdgeCoverage, 0)
    }

    func testLastItemRendersOnTop() throws {
        let document = CollageDocument()
        let red = document.add(try makeImage(width: 30, height: 30, color: .red))
        let blue = document.add(try makeImage(width: 30, height: 30, color: .blue))
        document.beginInteraction()
        document.updateFrame(CGRect(x: 0, y: 0, width: 30, height: 30), for: red)
        document.updateFrame(CGRect(x: 0, y: 0, width: 30, height: 30), for: blue)
        document.endInteraction()

        let pixel = pixel(in: try document.render(), x: 15, y: 15)

        XCTAssertGreaterThan(pixel.blue, 0.8)
        XCTAssertLessThan(pixel.red, 0.2)
    }

    func testCanvasCornerResizePreservesAspectRatio() throws {
        let document = CollageDocument()
        let id = document.add(
            try makeImage(width: 100, height: 50, color: .green),
            at: CGPoint(x: 20, y: 30)
        )
        let view = CollageCanvasView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.document = document
        let start = CGPoint(x: 115, y: 75)

        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: start))
        view.mouseDragged(with: try mouseEvent(
            .leftMouseDragged,
            at: CGPoint(x: 165, y: 85)
        ))
        view.mouseUp(with: try mouseEvent(
            .leftMouseUp,
            at: CGPoint(x: 165, y: 85)
        ))

        let frame = try XCTUnwrap(document.items.first(where: { $0.id == id })?.frame)
        XCTAssertEqual(frame.width / frame.height, 2, accuracy: 0.001)
        XCTAssertGreaterThan(frame.width, 100)
        XCTAssertEqual(frame.minX, 20, accuracy: 0.001)
        XCTAssertEqual(frame.minY, 30, accuracy: 0.001)
    }

    func testImageLoaderAppliesOrientationMetadata() throws {
        let source = try makeImage(width: 40, height: 20, color: .orange)
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(
            destination,
            source,
            [kCGImagePropertyOrientation: 6] as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nylai-orientation-\(UUID().uuidString).jpg")
        try (data as Data).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try CollageImageLoader.load(url: url)

        XCTAssertEqual(loaded.width, 20)
        XCTAssertEqual(loaded.height, 40)
    }

    func testCopyAndSuccessfulSaveEachRecordOneHistoryItem() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nylai-collage-output-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScreenshotHistoryStore(directory: directory)
        let paster = CollageRecordingPaster()
        let saver = CollageRecordingSaver(result: URL(fileURLWithPath: "/tmp/collage.png"))
        let model = CollageViewModel(
            historyStore: store,
            isHistoryEnabled: { true },
            paster: paster,
            saver: saver
        )
        model.addImage(try makeImage(width: 50, height: 40, color: .purple))

        model.copyImage()
        XCTAssertEqual(paster.copyCount, 1)
        XCTAssertEqual(store.records.count, 1)

        model.saveImage()
        try await waitUntil { saver.saveCount == 1 }
        try await waitUntil { store.records.count == 2 }
        XCTAssertEqual(store.records.count, 2)
    }

    func testCancelledSaveKeepsCanvasAndDoesNotRecordHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nylai-collage-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScreenshotHistoryStore(directory: directory)
        let saver = CollageRecordingSaver(result: nil)
        let model = CollageViewModel(
            historyStore: store,
            isHistoryEnabled: { true },
            paster: CollageRecordingPaster(),
            saver: saver
        )
        model.addImage(try makeImage(width: 50, height: 40, color: .purple))

        model.saveImage()
        try await waitUntil { saver.saveCount == 1 }
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(model.document.items.count, 1)
        XCTAssertTrue(store.records.isEmpty)
    }

    private func makeImage(
        width: Int,
        height: Int,
        color: NSColor
    ) throws -> CGImage {
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
        let converted = color.usingColorSpace(.sRGB) ?? color
        context.setFillColor(converted.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func pixel(in image: CGImage, x: Int, y: Int) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.translateBy(x: CGFloat(-x), y: CGFloat(y - image.height + 1))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (
            CGFloat(bytes[0]) / 255,
            CGFloat(bytes[1]) / 255,
            CGFloat(bytes[2]) / 255,
            CGFloat(bytes[3]) / 255
        )
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: CGPoint(x: point.x, y: 800 - point.y),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
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
private final class CollageRecordingPaster: ScreenshotPasting {
    private(set) var copyCount = 0

    func copy(_ image: CGImage) throws {
        copyCount += 1
    }
}

@MainActor
private final class CollageRecordingSaver: ScreenshotSaving {
    private(set) var saveCount = 0
    private let result: URL?

    init(result: URL?) {
        self.result = result
    }

    func save(_ image: CGImage) async throws -> URL? {
        saveCount += 1
        return result
    }
}
