import AppKit
import XCTest
@testable import nylai

final class PinnedImageTests: XCTestCase {
    @MainActor
    func testControlsStayAtVisibleImageEdgeWhenTransparentPaddingScales() throws {
        let width = 800
        let height = 600
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 60..<500 {
            for x in 40..<740 {
                let offset = (y * width + x) * 4
                pixels[offset] = 120
                pixels[offset + 1] = 170
                pixels[offset + 2] = 90
                pixels[offset + 3] = 255
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let manager = PinnedImageManager()
        manager.pin(image)
        defer { manager.closeAll() }
        let window = try XCTUnwrap(manager.controllers.values.first?.window)
        let content = try XCTUnwrap(window.contentView)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for scale: CGFloat in [0.5, 0.8, 0.6] {
            let size = CGSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale)
            window.setFrame(CGRect(origin: window.frame.origin, size: size), display: false)
            content.needsLayout = true
            content.layoutSubtreeIfNeeded()
        let surfaces = [content] + (window.childWindows ?? []).compactMap(\.contentView)
        let bar = try XCTUnwrap(surfaces.flatMap(descendants).first { $0 is NSVisualEffectView })
        let imageFrame = window.convertToScreen(content.convert(
            CGRect(x: 40 * scale, y: 60 * scale, width: 700 * scale, height: 440 * scale),
            to: nil
        ))
        let barFrame = try XCTUnwrap(bar.window).convertToScreen(bar.convert(bar.bounds, to: nil))
        XCTAssertEqual(barFrame.minX, imageFrame.minX, accuracy: 1)
        XCTAssertEqual(barFrame.minY, imageFrame.maxY + 6, accuracy: 1)
        }
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/nylai-pin-padding-preview.png"))
    }
    @MainActor
    func testControlsFollowImageEdgeImmediatelyAcrossZoomSizes() throws {
        let manager = PinnedImageManager()
        manager.pin(try makeImage(width: 800, height: 600))
        defer { manager.closeAll() }
        let window = try XCTUnwrap(manager.controllers.values.first?.window)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let screen = try XCTUnwrap(window.screen).visibleFrame
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        for width: CGFloat in [240, 180, 230, 480, 350] {
            let frame = CGRect(x: screen.midX - width / 2, y: screen.midY - width * 0.375,
                               width: width, height: width * 0.75)
            window.setFrame(frame, display: false)
            let surfaces = [content] + (window.childWindows ?? []).compactMap(\.contentView)
            let label = try XCTUnwrap(surfaces.flatMap(descendants).first {
                ($0 as? NSTextField)?.toolTip == L10n.shared.string("滚轮缩放")
            })
            var ancestor = label.superview
            while let view = ancestor, !(view is NSVisualEffectView) { ancestor = view.superview }
            let bar = try XCTUnwrap(ancestor)
            let barWindow = try XCTUnwrap(bar.window)
            let global = barWindow.convertToScreen(bar.convert(bar.bounds, to: nil))
            XCTAssertEqual(global.minX, frame.minX, accuracy: 0.5)
            XCTAssertEqual(global.minY, frame.maxY + 6, accuracy: 0.5)
            XCTAssertFalse(global.intersects(frame))
        }
    }
    @MainActor
    func testNarrowImageKeepsOpacityAndZoomInAccessibleControls() throws {
        let manager = PinnedImageManager()
        manager.pin(try makeImage(width: 120, height: 80))
        defer { manager.closeAll() }
        let controller = try XCTUnwrap(manager.controllers.values.first)
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let surfaces = [content] + (window.childWindows ?? []).compactMap(\.contentView)
        let controls = surfaces.flatMap(descendants)
        XCTAssertTrue(controls.contains { $0 is NSSlider && !$0.isHidden })
        XCTAssertTrue(controls.contains { ($0 as? NSTextField)?.toolTip == L10n.shared.string("滚轮缩放") && !$0.isHidden })
        XCTAssertEqual(window.childWindows?.count, 1)
        XCTAssertFalse(window.childWindows?.first?.contentView?.subviews.isEmpty ?? true)
    }
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

    func testPinnedControlsSitOutsideImageAndStayOnScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let image = CGRect(x: 300, y: 200, width: 500, height: 300)
        let controls = PinnedImageLayout.controlsFrame(
            imageFrame: image,
            controlsSize: CGSize(width: 310, height: 34),
            visibleFrame: visible
        )
        XCTAssertEqual(controls.minX, image.minX)
        XCTAssertEqual(controls.minY, image.maxY + 6)
        XCTAssertFalse(controls.intersects(image))
        let topEdge = PinnedImageLayout.controlsFrame(
            imageFrame: CGRect(x: 1380, y: 850, width: 40, height: 40),
            controlsSize: CGSize(width: 310, height: 34),
            visibleFrame: visible
        )
        XCTAssertTrue(visible.contains(topEdge))
        XCTAssertEqual(topEdge.maxX, visible.maxX - 8)
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
