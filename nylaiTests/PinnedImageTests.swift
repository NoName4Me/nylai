import AppKit
import XCTest
@testable import nylai

final class PinnedImageTests: XCTestCase {
    func testInitialLayoutPreservesAspectRatioAndStaysInsideVisibleFrame() {
        let frame = CGRect(x: 100, y: 100, width: 1000, height: 700)
        let size = PinnedImageLayout.initialSize(
            imageSize: CGSize(width: 2400, height: 1200),
            visibleFrame: frame
        )

        XCTAssertLessThanOrEqual(size.width, frame.width * 0.68)
        XCTAssertLessThanOrEqual(size.height, frame.height * 0.68)
        XCTAssertEqual(size.width / size.height, 2, accuracy: 0.001)
    }

    func testProportionalResizeUsesWidthOnlyAndProtectsMinimum() {
        XCTAssertEqual(
            PinnedImageLayout.proportionalHeight(forWidth: 800, aspectRatio: 2),
            400
        )
        XCTAssertEqual(
            PinnedImageLayout.proportionalHeight(forWidth: 20, aspectRatio: 2),
            80
        )
    }

    @MainActor
    func testPinnedWindowsAreIndependentAndOpacityDoesNotFadeControls() throws {
        let manager = PinnedImageManager()
        manager.pin(try makeImage(width: 120, height: 80))
        manager.pin(try makeImage(width: 200, height: 100))
        defer { manager.closeAll() }

        XCTAssertEqual(manager.windowCount, 2)
        let controllers = Array(manager.controllers.values)
        XCTAssertEqual(controllers.count, 2)
        let first = try XCTUnwrap(controllers.first)
        first.imageOpacity = 0.35

        XCTAssertEqual(first.imageOpacity, 0.35, accuracy: 0.001)
        XCTAssertEqual(first.controlsOpacity, 1, accuracy: 0.001)
        XCTAssertEqual(controllers[1].imageOpacity, 1, accuracy: 0.001)

        manager.closeAll()
        XCTAssertEqual(manager.windowCount, 0)
    }

    @MainActor
    func testOpacityIsClampedToTenThroughOneHundredPercent() throws {
        let manager = PinnedImageManager()
        manager.pin(try makeImage(width: 60, height: 40))
        defer { manager.closeAll() }
        let controller = try XCTUnwrap(manager.controllers.values.first)

        controller.imageOpacity = 0
        XCTAssertEqual(controller.imageOpacity, 0.1, accuracy: 0.001)
        controller.imageOpacity = 2
        XCTAssertEqual(controller.imageOpacity, 1, accuracy: 0.001)
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
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
        context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}
