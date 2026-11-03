import CoreGraphics
import Foundation

struct ScreenshotInspectorColor: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    var hexText: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    var rgbText: String {
        "RGB \(red), \(green), \(blue)"
    }
}

enum ScreenshotColorSampler {
    static func color(
        in image: CGImage,
        at pixel: PixelPoint
    ) -> ScreenshotInspectorColor? {
        guard image.width > 0, image.height > 0 else { return nil }
        let x = min(max(pixel.x, 0), image.width - 1)
        let y = min(max(pixel.y, 0), image.height - 1)
        guard let sample = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let context = CGContext(
                  data: nil,
                  width: 1,
                  height: 1,
                  bitsPerComponent: 8,
                  bytesPerRow: 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)
                      ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                      | CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = context.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        return ScreenshotInspectorColor(
            red: bytes[0],
            green: bytes[1],
            blue: bytes[2]
        )
    }
}
