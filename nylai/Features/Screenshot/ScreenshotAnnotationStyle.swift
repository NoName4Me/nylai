import AppKit
import Foundation

struct PixelPoint: Codable, Equatable, Sendable {
    var x: Int
    var y: Int
}

enum ScreenshotAnnotationKind: String, CaseIterable, Codable, Equatable, Sendable {
    case rectangle
    case ellipse
    case line
    case arrow
    case brush
    case marker
    case text
    case step
    case mosaic
    case mosaicStroke
    case blur
    case mosaicBlur
}

enum ScreenshotMosaicMode: String, CaseIterable, Codable, Equatable, Sendable {
    case box
    case stroke

    var title: String {
        switch self {
        case .box: L10n.shared.string("方框")
        case .stroke: L10n.shared.string("涂抹")
        }
    }
}

enum ScreenshotRedactionEffect: String, CaseIterable, Codable, Equatable, Sendable {
    case mosaic
    case blur

    var title: String {
        switch self {
        case .mosaic: L10n.shared.string("马赛克")
        case .blur: L10n.shared.string("高斯模糊")
        }
    }
}

enum ScreenshotAnnotationCornerStyle: String, CaseIterable, Codable, Equatable, Sendable {
    case rounded
    case sharp

    var title: String {
        switch self {
        case .rounded: L10n.shared.string("圆角")
        case .sharp: L10n.shared.string("直角")
        }
    }
}

enum ScreenshotAnnotationLineStyle: String, Codable, Equatable, Sendable {
    case solid
    case dashed
}

enum ScreenshotLineWidthScroll {
    static func adjusted(
        _ lineWidth: Int,
        deltaY: CGFloat,
        precise: Bool,
        range: ClosedRange<Int>
    ) -> Int {
        guard deltaY != 0 else { return lineWidth }
        if precise, abs(deltaY) < 24 {
            return lineWidth
        }
        let magnitude = precise
            ? max(1, Int((abs(deltaY) / 24).rounded(.down)))
            : 1
        let proposed = lineWidth + (deltaY > 0 ? magnitude : -magnitude)
        return min(max(proposed, range.lowerBound), range.upperBound)
    }
}

struct ScreenshotAnnotationColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    static let defaultRed = ScreenshotAnnotationColor(
        red: 1,
        green: 59.0 / 255.0,
        blue: 48.0 / 255.0,
        alpha: 1
    )

    var nsColor: NSColor {
        NSColor(
            srgbRed: red,
            green: green,
            blue: blue,
            alpha: alpha
        )
    }

    var cgColor: CGColor {
        CGColor(
            srgbRed: red,
            green: green,
            blue: blue,
            alpha: alpha
        )
    }
}

enum ScreenshotArrowWidthStyle: String, CaseIterable, Codable, Sendable {
    case uniform
    case tapered

    var title: String {
        switch self {
        case .uniform: L10n.shared.string("等宽")
        case .tapered: L10n.shared.string("渐宽")
        }
    }
}

enum ScreenshotArrowPathStyle: String, CaseIterable, Codable, Sendable {
    case straight
    case curved

    var title: String {
        switch self {
        case .straight: L10n.shared.string("直")
        case .curved: L10n.shared.string("弯")
        }
    }
}

struct ScreenshotArrowOptions: Codable, Equatable, Sendable {
    var widthStyle: ScreenshotArrowWidthStyle
    var pathStyle: ScreenshotArrowPathStyle

    static let `default` = ScreenshotArrowOptions()

    init(
        widthStyle: ScreenshotArrowWidthStyle = .uniform,
        pathStyle: ScreenshotArrowPathStyle = .straight
    ) {
        self.widthStyle = widthStyle
        self.pathStyle = pathStyle
    }

    private enum CodingKeys: String, CodingKey {
        case widthStyle
        case pathStyle
        case form
        case tapered
        case curve
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let widthStyle = try container.decodeIfPresent(
            ScreenshotArrowWidthStyle.self,
            forKey: .widthStyle
        ) {
            self.widthStyle = widthStyle
        } else {
            let form = try container.decodeIfPresent(String.self, forKey: .form)
            let tapered = try container.decodeIfPresent(Bool.self, forKey: .tapered) ?? false
            widthStyle = form == "body" && tapered ? .tapered : .uniform
        }
        if let pathStyle = try container.decodeIfPresent(
            ScreenshotArrowPathStyle.self,
            forKey: .pathStyle
        ) {
            self.pathStyle = pathStyle
        } else {
            let curve = try container.decodeIfPresent(String.self, forKey: .curve)
            pathStyle = curve == "left" || curve == "right" ? .curved : .straight
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(widthStyle, forKey: .widthStyle)
        try container.encode(pathStyle, forKey: .pathStyle)
    }

    var isTapered: Bool {
        widthStyle == .tapered
    }
}

struct ScreenshotAnnotationStyle: Codable, Equatable, Sendable {
    static let minimumLineWidth = 1
    static let maximumLineWidth = 24
    static let minimumTextSize = 8
    static let maximumTextSize = 96
    static let minimumMosaicBlockSize = 1
    static let maximumMosaicBlockSize = 60
    static let minimumStepSize = 16
    static let maximumStepSize = 96

    var color: ScreenshotAnnotationColor
    var lineWidth: Int
    var lineStyle: ScreenshotAnnotationLineStyle
    var fillsShape: Bool? = nil
    var arrowOptions: ScreenshotArrowOptions? = nil
    var fillsTextBackground: Bool? = nil
    var cornerStyle: ScreenshotAnnotationCornerStyle? = nil

    var resolvedCornerStyle: ScreenshotAnnotationCornerStyle {
        cornerStyle ?? .rounded
    }

    var textColor: NSColor {
        guard fillsTextBackground == true else { return color.nsColor }
        let brightness = color.red * 0.2126 + color.green * 0.7152 + color.blue * 0.0722
        return brightness > 0.56 ? .black : .white
    }

    static let `default` = ScreenshotAnnotationStyle(
        color: .defaultRed,
        lineWidth: 3,
        lineStyle: .solid
    )

    static func defaultStyle(for kind: ScreenshotAnnotationKind) -> ScreenshotAnnotationStyle {
        var style = Self.default
        if kind == .text {
            style.lineWidth = 18
        } else if kind == .step {
            style.lineWidth = 24
        } else if kind == .mosaic {
            style.lineWidth = 16
        } else if kind == .mosaicStroke {
            style.lineWidth = 18
        } else if kind == .blur {
            style.lineWidth = 18
        } else if kind == .mosaicBlur {
            style.lineWidth = 18
        } else if kind == .marker {
            style.lineWidth = 18
        } else if kind == .arrow {
            style.arrowOptions = .default
        }
        return style
    }

    func validated() -> ScreenshotAnnotationStyle {
        var copy = self
        copy.lineWidth = min(max(lineWidth, Self.minimumLineWidth), Self.maximumLineWidth)
        copy.color = Self.validated(color)
        return copy
    }

    func validated(for kind: ScreenshotAnnotationKind) -> ScreenshotAnnotationStyle {
        var copy = self
        let range = kind.lineWidthRange
        copy.lineWidth = min(max(lineWidth, range.lowerBound), range.upperBound)
        copy.color = Self.validated(color)
        return copy
    }

    private static func validated(
        _ color: ScreenshotAnnotationColor
    ) -> ScreenshotAnnotationColor {
        var copy = color
        copy.red = min(max(color.red, 0), 1)
        copy.green = min(max(color.green, 0), 1)
        copy.blue = min(max(color.blue, 0), 1)
        copy.alpha = min(max(color.alpha, 0), 1)
        return copy
    }
}

final class ScreenshotAnnotationStyleStore {
    private static let storageKey = "screenshot.annotation-styles.v1"

    private let defaults: UserDefaults
    private var styles: [String: ScreenshotAnnotationStyle]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(
               [String: ScreenshotAnnotationStyle].self,
               from: data
           ) {
            styles = decoded
        } else {
            styles = [:]
        }
    }

    func style(for kind: ScreenshotAnnotationKind) -> ScreenshotAnnotationStyle {
        styles[kind.rawValue]?.validated(for: kind) ?? .defaultStyle(for: kind)
    }

    func setStyle(_ style: ScreenshotAnnotationStyle, for kind: ScreenshotAnnotationKind) {
        styles[kind.rawValue] = style.validated(for: kind)
        if let data = try? JSONEncoder().encode(styles) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    func setStyle(_ style: ScreenshotAnnotationStyle, for tool: ScreenshotEditorTool) {
        guard let kind = tool.annotationKind else { return }
        setStyle(style, for: kind)
    }

    func style(for tool: ScreenshotEditorTool) -> ScreenshotAnnotationStyle? {
        guard let kind = tool.annotationKind else { return nil }
        return style(for: kind)
    }
}

extension ScreenshotAnnotationKind {
    var lineWidthRange: ClosedRange<Int> {
        switch self {
        case .rectangle, .ellipse, .line, .arrow:
            ScreenshotAnnotationStyle.minimumLineWidth...ScreenshotAnnotationStyle.maximumLineWidth
        case .brush:
            2...48
        case .marker:
            2...48
        case .text:
            ScreenshotAnnotationStyle.minimumTextSize...ScreenshotAnnotationStyle.maximumTextSize
        case .step:
            ScreenshotAnnotationStyle.minimumStepSize...ScreenshotAnnotationStyle.maximumStepSize
        case .mosaic, .mosaicStroke, .blur, .mosaicBlur:
            ScreenshotAnnotationStyle.minimumMosaicBlockSize...ScreenshotAnnotationStyle.maximumMosaicBlockSize
        }
    }

    var lineWidthControlTitle: String {
        switch self {
        case .text:
            L10n.shared.string("字号")
        case .mosaic, .mosaicStroke:
            L10n.shared.string("像素块大小")
        case .blur, .mosaicBlur:
            L10n.shared.string("模糊强度")
        case .step:
            L10n.shared.string("直径")
        case .rectangle, .ellipse, .line, .arrow, .brush, .marker:
            L10n.shared.string("粗细")
        }
    }

    var supportsFill: Bool {
        self == .rectangle || self == .ellipse || self == .step
    }

    var supportsColorControl: Bool {
        !isMosaicEffect
    }

    var showsLineWidthControl: Bool {
        self != .step
    }

    var supportsLineStyleControl: Bool {
        switch self {
        case .rectangle, .ellipse, .line, .arrow, .brush:
            true
        case .text, .step, .mosaic, .mosaicStroke, .blur, .mosaicBlur:
            false
        case .marker:
            true
        }
    }

    var isFreehand: Bool {
        self == .brush
            || self == .marker
            || redactionShape == .stroke
    }

    var isEditable: Bool {
        redactionShape != .stroke
    }

    var supportsDirectionConstraint: Bool {
        switch self {
        case .line, .arrow, .brush, .marker:
            true
        case .mosaicStroke, .mosaicBlur:
            true
        case .rectangle, .ellipse, .text, .step, .mosaic, .blur:
            false
        }
    }

    var isMosaicEffect: Bool {
        redactionEffect != nil
    }

    var mosaicMode: ScreenshotMosaicMode? {
        redactionShape
    }

    var redactionEffect: ScreenshotRedactionEffect? {
        switch self {
        case .mosaic, .mosaicStroke:
            .mosaic
        case .blur, .mosaicBlur:
            .blur
        default: nil
        }
    }

    var redactionShape: ScreenshotMosaicMode? {
        switch self {
        case .mosaic, .blur:
            .box
        case .mosaicStroke, .mosaicBlur:
            .stroke
        default: nil
        }
    }

    var usesPointPath: Bool {
        isFreehand || self == .line
    }

    var strokeAlpha: Double {
        1
    }

    var minimumResizeSize: CGSize {
        switch self {
        case .rectangle, .ellipse, .mosaic, .blur, .marker:
            CGSize(width: 8, height: 8)
        case .step:
            CGSize(width: 16, height: 16)
        case .brush:
            CGSize(width: 4, height: 4)
        case .text:
            CGSize(width: 12, height: 8)
        case .line, .arrow, .mosaicStroke, .mosaicBlur:
            CGSize(width: 1, height: 1)
        }
    }

    var supportsCornerStyleControl: Bool {
        self == .rectangle || self == .line || self == .brush
    }
}

extension ScreenshotAnnotation {
    var isTaperedArrow: Bool {
        kind == .arrow && style.arrowOptions?.isTapered == true
    }
}

extension ScreenshotEditorTool {
    var annotationKind: ScreenshotAnnotationKind? {
        switch self {
        case .selection, .objectSelection:
            nil
        case .rectangle:
            .rectangle
        case .ellipse:
            .ellipse
        case .line:
            .line
        case .arrow:
            .arrow
        case .brush:
            .brush
        case .text:
            .text
        case .step:
            .step
        case .mosaic:
            .mosaic
        }
    }

    func annotationKind(
        for effect: ScreenshotRedactionEffect,
        shape: ScreenshotMosaicMode
    ) -> ScreenshotAnnotationKind {
        switch (effect, shape) {
        case (.mosaic, .box):
            return .mosaic
        case (.mosaic, .stroke):
            return .mosaicStroke
        case (.blur, .box):
            return .blur
        case (.blur, .stroke):
            return .mosaicBlur
        }
    }

    func owns(_ kind: ScreenshotAnnotationKind) -> Bool {
        if self == .mosaic {
            return kind.isMosaicEffect
        }
        return annotationKind == kind
    }
}
