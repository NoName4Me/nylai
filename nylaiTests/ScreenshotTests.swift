import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import nylai

final class ScreenshotTests: XCTestCase {
    @MainActor
    func testDeniedPermissionDoesNotAttemptCaptureOrSave() async {
        let saver = StubScreenshotSaver()
        var errors: [Error] = []
        let controller = ScreenshotController(
            capturer: ScreenCaptureService(requestAccess: { false }), saver: saver,
            presentError: { errors.append($0) }
        )
        await controller.captureMainDisplay()
        XCTAssertEqual(errors.first as? ScreenshotError, .permissionRequired)
        XCTAssertEqual(saver.calls, 0)
        XCTAssertFalse(controller.isBusy)
    }

    @MainActor
    func testSaveCancellationIsSilentAndAllowsNextCapture() async throws {
        let capturer = StubScreenCapturer(image: try makeImage())
        let saver = StubScreenshotSaver()
        var errors: [Error] = []
        let controller = ScreenshotController(capturer: capturer, saver: saver, presentError: { errors.append($0) })
        await controller.captureMainDisplay()
        await controller.captureMainDisplay()
        XCTAssertEqual(capturer.displayIDs, [CGMainDisplayID(), CGMainDisplayID()])
        XCTAssertEqual(saver.calls, 2)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertFalse(controller.isBusy)
    }

    @MainActor
    func testWriteFailureIsReportedAndDoesNotLeaveControllerBusy() async throws {
        let capturer = StubScreenCapturer(image: try makeImage())
        let saver = StubScreenshotSaver()
        saver.error = CocoaError(.fileWriteNoPermission)
        var errors: [Error] = []
        let controller = ScreenshotController(capturer: capturer, saver: saver, presentError: { errors.append($0) })
        await controller.captureMainDisplay()
        XCTAssertEqual((errors.first as? CocoaError)?.code, .fileWriteNoPermission)
        XCTAssertFalse(controller.isBusy)
        saver.error = nil
        await controller.captureMainDisplay()
        XCTAssertEqual(saver.calls, 2)
        XCTAssertEqual(errors.count, 1)
    }

    @MainActor
    func testConcurrentTriggerDoesNotCreateAnotherCaptureAndCancelledTaskDoesNotSave() async throws {
        let capturer = SuspendedScreenCapturer()
        let saver = StubScreenshotSaver()
        var errors: [Error] = []
        let controller = ScreenshotController(capturer: capturer, saver: saver, presentError: { errors.append($0) })
        let first = Task { await controller.captureMainDisplay() }
        // 等待捕获调用进入受控挂起点，不访问真实屏幕或申请系统权限。
        for _ in 0..<100 where capturer.continuation == nil {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard let continuation = capturer.continuation else {
            first.cancel()
            return XCTFail("未进入截图流程")
        }
        XCTAssertTrue(controller.isBusy)
        await controller.captureMainDisplay()
        XCTAssertEqual(capturer.calls, 1)
        first.cancel()
        continuation.resume(returning: try makeImage())
        await first.value
        XCTAssertEqual(saver.calls, 0)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertFalse(controller.isBusy)
    }

    func testPNGFilePreservesPixelDimensionsAndCanBeDecoded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("capture.png")
        let image = try makeImage()
        try await PNGImageWriter().write(image, to: url)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, image.width)
        XCTAssertEqual(decoded.height, image.height)
    }

    func testPNGWriteToMissingDirectoryFailsWithoutCreatingAFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("capture.png")
        do {
            try await PNGImageWriter().write(try makeImage(), to: url)
            XCTFail("不存在的目录不应保存成功")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }
}

private func makeImage() throws -> CGImage {
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try XCTUnwrap(CGContext(
        data: nil, width: 32, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
    return try XCTUnwrap(context.makeImage())
}

@MainActor
private final class StubScreenCapturer: ScreenCapturing {
    let image: CGImage
    var displayIDs: [CGDirectDisplayID] = []

    init(image: CGImage) { self.image = image }

    func captureDisplay(_ displayID: CGDirectDisplayID) async throws -> CGImage {
        displayIDs.append(displayID)
        return image
    }
}

@MainActor
private final class SuspendedScreenCapturer: ScreenCapturing {
    var calls = 0
    var continuation: CheckedContinuation<CGImage, Error>?

    func captureDisplay(_ displayID: CGDirectDisplayID) async throws -> CGImage {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
}

@MainActor
private final class StubScreenshotSaver: ScreenshotSaving {
    var calls = 0
    var error: Error?

    func save(_ image: CGImage) async throws -> URL? {
        calls += 1
        if let error { throw error }
        return nil
    }
}
