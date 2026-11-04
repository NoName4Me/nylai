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
    case text
    case step
    case mosaic
}

enum ScreenshotAnnotationLineStyle: String, Codable, Equatable, Sendable {
    case solid
    case dashed
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

enum ScreenshotArrowStyle: String, Codable, CaseIterable, Sendable {
    case open, solid, double

    var title: String {
        switch self {
        case .open: "开放箭头"
        case .solid: "实心箭头"
        case .double: "双向箭头"
        }
    }
}

struct ScreenshotArrowOptions: Codable, Equatable, Sendable {
    enum Form: String, CaseIterable, Codable, Sendable {
        case line, body
        var title: String { self == .line ? "线形" : "面形" }
    }
    enum Start: String, CaseIterable, Codable, Sendable {
        case none, dot, diamond, fork
        var title: String {
            switch self { case .none: "无"; case .dot: "圆点"; case .diamond: "菱形"; case .fork: "分叉" }
        }
    }
    enum Tip: String, CaseIterable, Codable, Sendable {
        case triangle, open, dart
        var title: String {
            switch self { case .triangle: "三角"; case .open: "线条"; case .dart: "箭矢" }
        }
    }
    enum Curve: String, CaseIterable, Codable, Sendable {
        case straight, left, right
        var title: String {
            switch self { case .straight: "直线"; case .left: "左弯"; case .right: "右弯" }
        }
    }

    var form: Form = .line
    var start: Start = .none
    var tip: Tip = .open
    var curve: Curve = .straight
    var tapered = false
    var filled = true

    var allowedStarts: [Start] { form == .line ? [.none, .dot, .diamond] : [.none, .fork] }
    var allowedTips: [Tip] { form == .line ? [.triangle, .open, .dart] : [.triangle, .dart] }

    func normalized() -> Self {
        var result = self
        if !allowedStarts.contains(start) { result.start = .none }
        if !allowedTips.contains(tip) { result.tip = .triangle }
        if form == .line { result.tapered = false }
        if result.tapered { result.filled = true }
        return result
    }
}

struct ScreenshotAnnotationStyle: Codable, Equatable, Sendable {
    static let minimumLineWidth = 1
    static let maximumLineWidth = 24
    static let minimumTextSize = 8
    static let maximumTextSize = 96
    static let minimumMosaicBlockSize = 4
    static let maximumMosaicBlockSize = 40
    static let minimumStepSize = 16
    static let maximumStepSize = 96

    var color: ScreenshotAnnotationColor
    var lineWidth: Int
    var lineStyle: ScreenshotAnnotationLineStyle
    var fillsShape: Bool? = nil
    var arrowStyle: ScreenshotArrowStyle? = nil
    var arrowOptions: ScreenshotArrowOptions? = nil
    var fillsTextBackground: Bool? = nil

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
            style.lineWidth = 12
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
        case .rectangle, .ellipse, .line, .arrow, .brush:
            ScreenshotAnnotationStyle.minimumLineWidth...ScreenshotAnnotationStyle.maximumLineWidth
        case .text:
            ScreenshotAnnotationStyle.minimumTextSize...ScreenshotAnnotationStyle.maximumTextSize
        case .step:
            ScreenshotAnnotationStyle.minimumStepSize...ScreenshotAnnotationStyle.maximumStepSize
        case .mosaic:
            ScreenshotAnnotationStyle.minimumMosaicBlockSize...ScreenshotAnnotationStyle.maximumMosaicBlockSize
        }
    }

    var lineWidthControlTitle: String {
        switch self {
        case .text:
            "字号"
        case .mosaic:
            "像素块大小"
        case .step:
            "直径"
        case .rectangle, .ellipse, .line, .arrow, .brush:
            "粗细"
        }
    }

    var supportsFill: Bool { self == .rectangle || self == .ellipse }

    var supportsColorControl: Bool {
        self != .mosaic
    }

    var supportsLineStyleControl: Bool {
        switch self {
        case .rectangle, .ellipse, .line, .arrow, .brush:
            true
        case .text, .step, .mosaic:
            false
        }
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
}
