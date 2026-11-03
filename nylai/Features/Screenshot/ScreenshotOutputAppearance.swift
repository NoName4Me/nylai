import AppKit
import CoreGraphics
import Foundation

struct ScreenshotOutputAppearance: Codable, Equatable, Sendable {
    static let maximumCornerRadius = 64
    static let maximumShadowRadius = 64
    static let maximumShadowOpacity = 100
    static let maximumShadowOffset = 64

    var roundedCornersEnabled: Bool
    var cornerRadius: Int
    var shadowEnabled: Bool
    var shadowRadius: Int
    var shadowOpacity: Int
    var shadowOffset: Int

    static let `default` = ScreenshotOutputAppearance(
        roundedCornersEnabled: false,
        cornerRadius: 12,
        shadowEnabled: false,
        shadowRadius: 12,
        shadowOpacity: 25,
        shadowOffset: 4
    )

    init(
        roundedCornersEnabled: Bool = false,
        cornerRadius: Int = 12,
        shadowEnabled: Bool = false,
        shadowRadius: Int = 12,
        shadowOpacity: Int = 25,
        shadowOffset: Int = 4
    ) {
        self.roundedCornersEnabled = roundedCornersEnabled
        self.cornerRadius = cornerRadius
        self.shadowEnabled = shadowEnabled
        self.shadowRadius = shadowRadius
        self.shadowOpacity = shadowOpacity
        self.shadowOffset = shadowOffset
    }

    var isEnabled: Bool {
        roundedCornersEnabled || shadowEnabled
    }

    func validated() -> ScreenshotOutputAppearance {
        var copy = self
        copy.cornerRadius = min(max(cornerRadius, 0), Self.maximumCornerRadius)
        copy.shadowRadius = min(max(shadowRadius, 0), Self.maximumShadowRadius)
        copy.shadowOpacity = min(max(shadowOpacity, 0), Self.maximumShadowOpacity)
        copy.shadowOffset = min(max(shadowOffset, 0), Self.maximumShadowOffset)
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case roundedCornersEnabled
        case cornerRadius
        case shadowEnabled
        case shadowRadius
        case shadowOpacity
        case shadowOffset
    }

    init(from decoder: Decoder) throws {
        let defaults = Self.default
        let container = try decoder.container(keyedBy: CodingKeys.self)
        roundedCornersEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .roundedCornersEnabled
        ) ?? defaults.roundedCornersEnabled
        cornerRadius = try container.decodeIfPresent(
            Int.self,
            forKey: .cornerRadius
        ) ?? defaults.cornerRadius
        shadowEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .shadowEnabled
        ) ?? defaults.shadowEnabled
        shadowRadius = try container.decodeIfPresent(
            Int.self,
            forKey: .shadowRadius
        ) ?? defaults.shadowRadius
        shadowOpacity = try container.decodeIfPresent(
            Int.self,
            forKey: .shadowOpacity
        ) ?? defaults.shadowOpacity
        shadowOffset = try container.decodeIfPresent(
            Int.self,
            forKey: .shadowOffset
        ) ?? defaults.shadowOffset
    }
}

final class ScreenshotOutputAppearanceStore {
    private static let storageKey = "screenshot.output-appearance.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var appearance: ScreenshotOutputAppearance {
        get {
            guard let data = defaults.data(forKey: Self.storageKey),
                  let decoded = try? JSONDecoder().decode(
                      ScreenshotOutputAppearance.self,
                      from: data
                  ) else {
                return .default
            }
            return decoded.validated()
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue.validated()) else { return }
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}

enum ScreenshotOutputRenderer {
    static func render(
        source: ScreenshotImageSource,
        selection: PixelRect,
        annotations: [ScreenshotAnnotation],
        appearance: ScreenshotOutputAppearance
    ) throws -> CGImage {
        let content = try ScreenshotAnnotationRenderer.render(
            source: source,
            selection: selection,
            annotations: annotations
        )
        let appearance = appearance.validated()
        guard appearance.isEnabled else { return content }
        let rounded = try roundedContent(content, appearance: appearance)
        guard appearance.shadowEnabled else { return rounded }
        return try shadowedContent(rounded, appearance: appearance)
    }

    private static func roundedContent(
        _ content: CGImage,
        appearance: ScreenshotOutputAppearance
    ) throws -> CGImage {
        guard appearance.roundedCornersEnabled else { return content }
        guard let context = makeContext(
            width: content.width,
            height: content.height
        ) else {
            throw ScreenshotOutputError.imageRenderingFailed
        }
        let rect = CGRect(x: 0, y: 0, width: content.width, height: content.height)
        let radius = min(
            CGFloat(appearance.cornerRadius),
            min(rect.width, rect.height) / 2
        )
        context.addPath(CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        ))
        context.clip()
        context.draw(content, in: rect)
        return try makeImage(context)
    }

    private static func shadowedContent(
        _ content: CGImage,
        appearance: ScreenshotOutputAppearance
    ) throws -> CGImage {
        let blur = CGFloat(appearance.shadowRadius)
        let offset = CGFloat(appearance.shadowOffset)
        let opacity = CGFloat(appearance.shadowOpacity) / 100
        let padding = max(1, Int(ceil(blur * 2 + offset + 4)))
        guard let context = makeContext(
            width: content.width + padding * 2,
            height: content.height + padding * 2
        ) else {
            throw ScreenshotOutputError.imageRenderingFailed
        }
        context.setShadow(
            offset: CGSize(width: 0, height: -offset),
            blur: blur,
            color: CGColor(gray: 0, alpha: opacity)
        )
        context.draw(content, in: CGRect(
            x: padding,
            y: padding,
            width: content.width,
            height: content.height
        ))
        return try makeImage(context)
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func makeImage(_ context: CGContext) throws -> CGImage {
        guard let image = context.makeImage() else {
            throw ScreenshotOutputError.imageRenderingFailed
        }
        return image
    }
}
