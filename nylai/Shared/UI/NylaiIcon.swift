import AppKit

enum NylaiIcon: String, CaseIterable {
    case crop
    case cursor
    case rectangle
    case ellipse
    case line
    case arrow
    case brush
    case text
    case step
    case mosaic
    case undo
    case redo
    case trash
    case scroll
    case reselect
    case copy
    case save
    case pin
    case close
    case shadow
    case solidLine
    case dashedLine
    case zoomIn
    case zoomOut
    case fitWidth

    var accessibilityLabel: String {
        switch self {
        case .crop: "选区"
        case .cursor: "选择标注"
        case .rectangle: "矩形"
        case .ellipse: "椭圆"
        case .line: "直线"
        case .arrow: "箭头"
        case .brush: "画笔"
        case .text: "文字"
        case .step: "步骤"
        case .mosaic: "马赛克"
        case .undo: "撤销"
        case .redo: "重做"
        case .trash: "删除标注"
        case .scroll: "滚动截图"
        case .reselect: "重新选择"
        case .copy: "复制"
        case .save: "保存"
        case .pin: "置顶"
        case .close: "取消"
        case .shadow: "阴影"
        case .solidLine: "实线"
        case .dashedLine: "虚线"
        case .zoomIn: "放大"
        case .zoomOut: "缩小"
        case .fitWidth: "适合宽度"
        }
    }

    func image(pointSize: CGFloat = 16) -> NSImage {
        let symbol: String? = switch self {
        case .reselect: "viewfinder"
        case .mosaic: "square.grid.3x3.fill"
        case .scroll: "arrow.down.to.line"
        case .save: "square.and.arrow.down"
        default: nil
        }
        let systemImage = symbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: accessibilityLabel)?
                .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        }
        let image = systemImage ?? NSImage(named: assetName)
            ?? NSImage(
                systemSymbolName: "questionmark",
                accessibilityDescription: accessibilityLabel
            ) ?? NSImage()
        image.size = NSSize(width: pointSize, height: pointSize)
        image.isTemplate = true
        return image
    }

    var assetName: String { "Phosphor-\(rawValue)" }
}

@MainActor
enum NylaiTheme {
    static let accent = NylaiPalette.accentNSColor

    static func isDark(_ appearance: NSAppearance = NSApp.effectiveAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func panelBackground(
        for appearance: NSAppearance = NSApp.effectiveAppearance
    ) -> NSColor {
        isDark(appearance)
            ? NSColor(srgbRed: 0.12, green: 0.14, blue: 0.10, alpha: 0.97)
            : NSColor(srgbRed: 0.985, green: 0.98, blue: 0.965, alpha: 0.97)
    }

    static func imageBackground(
        for appearance: NSAppearance = NSApp.effectiveAppearance
    ) -> NSColor {
        isDark(appearance)
            ? NSColor(srgbRed: 0.08, green: 0.10, blue: 0.07, alpha: 1)
            : NSColor(srgbRed: 0.97, green: 0.965, blue: 0.95, alpha: 1)
    }

    static func primaryText(
        for appearance: NSAppearance = NSApp.effectiveAppearance
    ) -> NSColor {
        isDark(appearance)
            ? NylaiPalette.cream.withAlphaComponent(0.94)
            : NSColor(srgbRed: 0.18, green: 0.21, blue: 0.15, alpha: 1)
    }

    static func secondaryText(
        for appearance: NSAppearance = NSApp.effectiveAppearance
    ) -> NSColor {
        isDark(appearance)
            ? NylaiPalette.cream.withAlphaComponent(0.64)
            : NSColor(srgbRed: 0.35, green: 0.38, blue: 0.30, alpha: 1)
    }

    static func border(
        for appearance: NSAppearance = NSApp.effectiveAppearance
    ) -> NSColor {
        isDark(appearance)
            ? NSColor.white.withAlphaComponent(0.18)
            : NSColor.black.withAlphaComponent(0.16)
    }
}
