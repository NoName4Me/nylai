import AppKit
import XCTest
@testable import nylai

final class ScreenshotOutputAppearanceTests: XCTestCase {
    func testDisabledAppearancePreservesDimensionsAndPixels() throws {
        let source = try makeSource(width: 40, height: 30)
        let selection = PixelRect(x: 0, y: 0, width: 40, height: 30)
        let annotation = ScreenshotAnnotation(
            rect: PixelRect(x: 8, y: 8, width: 10, height: 8)
        )
        let plain = try ScreenshotAnnotationRenderer.render(
            source: source,
            selection: selection,
            annotations: [annotation]
        )
        let unified = try ScreenshotOutputRenderer.render(
            source: source,
            selection: selection,
            annotations: [annotation],
            appearance: .default
        )

        XCTAssertEqual(unified.width, plain.width)
        XCTAssertEqual(unified.height, plain.height)
        XCTAssertEqual(try pngData(plain), try pngData(unified))
    }

    func testRoundedCornersAreTransparentWithoutBlackBackground() throws {
        let source = try makeSource(width: 60, height: 40)
        let selection = PixelRect(x: 0, y: 0, width: 60, height: 40)
        let appearance = ScreenshotOutputAppearance(
            roundedCornersEnabled: true,
            cornerRadius: 16,
            shadowEnabled: false,
            shadowRadius: 12
        )

        let rendered = try ScreenshotOutputRenderer.render(
            source: source,
            selection: selection,
            annotations: [],
            appearance: appearance
        )
        let bitmap = NSBitmapImageRep(cgImage: rendered)

        XCTAssertEqual(rendered.width, 60)
        XCTAssertEqual(rendered.height, 40)
        XCTAssertEqual(bitmap.colorAt(x: 0, y: 0)?.alphaComponent, 0)
        XCTAssertGreaterThan(bitmap.colorAt(x: 30, y: 20)?.alphaComponent ?? 0, 0.99)
    }

    func testShadowExpandsCanvasAndAppearsOnAllSides() throws {
        let source = try makeSource(width: 40, height: 30)
        let selection = PixelRect(x: 0, y: 0, width: 40, height: 30)
        let appearance = ScreenshotOutputAppearance(
            roundedCornersEnabled: true,
            cornerRadius: 10,
            shadowEnabled: true,
            shadowRadius: 10
        )
        let rendered = try ScreenshotOutputRenderer.render(
            source: source,
            selection: selection,
            annotations: [],
            appearance: appearance
        )
        let bitmap = NSBitmapImageRep(cgImage: rendered)
        let padding = (rendered.width - 40) / 2

        XCTAssertGreaterThan(padding, 0)
        XCTAssertEqual(rendered.width, 40 + padding * 2)
        XCTAssertEqual(rendered.height, 30 + padding * 2)
        let alphaBounds = nonzeroAlphaBounds(bitmap)
        XCTAssertLessThan(alphaBounds.minX, CGFloat(padding))
        XCTAssertLessThan(alphaBounds.minY, CGFloat(padding))
        XCTAssertGreaterThan(alphaBounds.maxX, CGFloat(rendered.width - padding))
        XCTAssertGreaterThan(alphaBounds.maxY, CGFloat(rendered.height - padding))
    }

    func testShadowOpacityAndOffsetAffectRenderedPixels() throws {
        let source = try makeSource(width: 40, height: 30)
        let selection = PixelRect(x: 0, y: 0, width: 40, height: 30)
        let transparent = ScreenshotOutputAppearance(
            shadowEnabled: true,
            shadowRadius: 10,
            shadowOpacity: 0,
            shadowOffset: 20
        )
        let visible = ScreenshotOutputAppearance(
            shadowEnabled: true,
            shadowRadius: 10,
            shadowOpacity: 100,
            shadowOffset: 20
        )
        let transparentImage = try ScreenshotOutputRenderer.render(
            source: source,
            selection: selection,
            annotations: [],
            appearance: transparent
        )
        let visibleImage = try ScreenshotOutputRenderer.render(
            source: source,
            selection: selection,
            annotations: [],
            appearance: visible
        )

        XCTAssertEqual(
            transparentImage.width,
            visibleImage.width,
            "阴影参数变化不应改变输出边界计算"
        )
        XCTAssertEqual(
            marginAlphaSum(
                NSBitmapImageRep(cgImage: transparentImage),
                content: try PixelSize(width: 40, height: 30)
            ),
            0,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(
            marginAlphaSum(
                NSBitmapImageRep(cgImage: visibleImage),
                content: try PixelSize(width: 40, height: 30)
            ),
            0
        )
    }

    func testAppearanceStoreRoundTripsAndValidates() throws {
        let suite = "ScreenshotOutputAppearanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ScreenshotOutputAppearanceStore(defaults: defaults)
        XCTAssertEqual(store.appearance, .default)

        store.appearance = ScreenshotOutputAppearance(
            roundedCornersEnabled: true,
            cornerRadius: 100,
            shadowEnabled: true,
            shadowRadius: 100,
            shadowOpacity: 200,
            shadowOffset: 100
        )
        let reloaded = ScreenshotOutputAppearanceStore(defaults: defaults)

        XCTAssertTrue(reloaded.appearance.roundedCornersEnabled)
        XCTAssertTrue(reloaded.appearance.shadowEnabled)
        XCTAssertEqual(
            reloaded.appearance.cornerRadius,
            ScreenshotOutputAppearance.maximumCornerRadius
        )
        XCTAssertEqual(
            reloaded.appearance.shadowRadius,
            ScreenshotOutputAppearance.maximumShadowRadius
        )
        XCTAssertEqual(
            reloaded.appearance.shadowOpacity,
            ScreenshotOutputAppearance.maximumShadowOpacity
        )
        XCTAssertEqual(
            reloaded.appearance.shadowOffset,
            ScreenshotOutputAppearance.maximumShadowOffset
        )
    }

    func testLegacyAppearanceJSONUsesNewParameterDefaults() throws {
        let data = Data("""
        {
          "roundedCornersEnabled": true,
          "cornerRadius": 20,
          "shadowEnabled": true,
          "shadowRadius": 15
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(ScreenshotOutputAppearance.self, from: data)

        XCTAssertEqual(decoded.cornerRadius, 20)
        XCTAssertEqual(decoded.shadowRadius, 15)
        XCTAssertEqual(decoded.shadowOpacity, ScreenshotOutputAppearance.default.shadowOpacity)
        XCTAssertEqual(decoded.shadowOffset, ScreenshotOutputAppearance.default.shadowOffset)
    }

    private func alpha(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> CGFloat {
        bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
    }

    private func nonzeroAlphaBounds(_ bitmap: NSBitmapImageRep) -> CGRect {
        var minX = bitmap.pixelsWide
        var minY = bitmap.pixelsHigh
        var maxX = -1
        var maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where alpha(bitmap, x: x, y: y) > 0.005 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return .zero }
        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
    }

    private func marginAlphaSum(_ bitmap: NSBitmapImageRep, content: PixelSize) -> CGFloat {
        let paddingX = max(0, (bitmap.pixelsWide - content.width) / 2)
        let paddingY = max(0, (bitmap.pixelsHigh - content.height) / 2)
        var total: CGFloat = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let inside = x >= paddingX
                    && x < paddingX + content.width
                    && y >= paddingY
                    && y < paddingY + content.height
                if !inside {
                    total += alpha(bitmap, x: x, y: y)
                }
            }
        }
        return total
    }

    private func makeSource(width: Int, height: Int) throws -> ScreenshotImageSource {
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
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let geometry = try ScreenshotSourceGeometry(
            kind: .window(7),
            globalFrame: CGRect(x: 0, y: 0, width: width, height: height),
            pointPixelScale: 1,
            pixelSize: PixelSize(width: width, height: height)
        )
        return try ScreenshotImageSource(
            image: try XCTUnwrap(context.makeImage()),
            geometry: geometry
        )
    }

    private func pngData(_ image: CGImage) throws -> Data {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
