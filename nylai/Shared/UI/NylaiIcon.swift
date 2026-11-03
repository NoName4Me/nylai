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
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" \
            fill="none" stroke="#000000" stroke-width="1.8" stroke-linecap="round" \
            stroke-linejoin="round">\(body)</svg>
            """
        guard let data = svg.data(using: .utf8),
              let image = NSImage(data: data) else {
            return NSImage(
                systemSymbolName: "questionmark",
                accessibilityDescription: accessibilityLabel
            ) ?? NSImage()
        }
        image.size = NSSize(width: pointSize, height: pointSize)
        image.isTemplate = true
        return image
    }

    private var body: String {
        switch self {
        case .crop:
            "<path d='M6 3v12a3 3 0 0 0 3 3h12'/><path d='M18 21V9a3 3 0 0 0-3-3H3'/>"
        case .cursor:
            "<path d='M5 3.8 19 10l-6 2.2-2.2 6z'/><path d='m13 16 4.2 4.2'/>"
        case .rectangle:
            "<rect x='3.5' y='5' width='17' height='14' rx='2'/>"
        case .ellipse:
            "<circle cx='12' cy='12' r='8.5'/>"
        case .line:
            "<path d='M5 19 19 5'/>"
        case .arrow:
            "<path d='M5 19 19 5'/><path d='M11 5h8v8'/>"
        case .brush:
            "<path d='m14.5 5.5 4 4'/><path d='M4 20c2.8.2 4.7-.6 5.8-2.2 1.2-1.7.7-3.6 2.3-5.2l6.2-6.2a2 2 0 0 1 2.8 2.8l-6.2 6.2c-1.6 1.6-3.5 1.1-5.2 2.3C8.1 19 6.9 19.6 4 20Z'/>"
        case .text:
            "<path d='M5 5h14'/><path d='M12 5v14'/>"
        case .step:
            "<circle cx='12' cy='12' r='8.5'/><path d='M10.5 9h2v6'/><path d='M9.5 15h5'/>"
        case .mosaic:
            "<rect x='3.5' y='3.5' width='17' height='17' rx='2'/><path d='M9.2 3.5v17M14.8 3.5v17M3.5 9.2h17M3.5 14.8h17'/>"
        case .undo:
            "<path d='M9 7 4 12l5 5'/><path d='M5 12h8a6 6 0 0 1 6 6'/>"
        case .redo:
            "<path d='m15 7 5 5-5 5'/><path d='M19 12h-8a6 6 0 0 0-6 6'/>"
        case .trash:
            "<path d='M4 7h16'/><path d='M9 7V4h6v3'/><path d='m6 7 1 13h10l1-13'/><path d='M10 11v5M14 11v5'/>"
        case .scroll:
            "<path d='M12 3v12'/><path d='m7 10 5 5 5-5'/><path d='M5 21h14'/>"
        case .reselect:
            "<path d='M4 8V5a1 1 0 0 1 1-1h3M16 4h3a1 1 0 0 1 1 1v3M20 16v3a1 1 0 0 1-1 1h-3M8 20H5a1 1 0 0 1-1-1v-3'/><path d='M9 12h6M12 9v6'/>"
        case .copy:
            "<rect x='8' y='8' width='11' height='11' rx='2'/><path d='M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2'/>"
        case .save:
            "<path d='M5 3h11l3 3v15H5z'/><path d='M8 3v6h7V3'/><path d='M8 21v-7h8v7'/>"
        case .pin:
            "<path d='m9 3 6 6'/><path d='m14 4 6 6-4 1-4 4-1 4-6-6 4-1 4-4z'/><path d='m8 16-4 4'/>"
        case .close:
            "<path d='m6 6 12 12M18 6 6 18'/>"
        case .shadow:
            "<rect x='4' y='4' width='12' height='12' rx='2'/><path d='M18 8v8a4 4 0 0 1-4 4H8'/>"
        case .solidLine:
            "<path d='M4 12h16' stroke-width='2.4'/>"
        case .dashedLine:
            "<path d='M4 12h3M10 12h4M17 12h3' stroke-width='2.4'/>"
        case .zoomIn:
            "<circle cx='10.5' cy='10.5' r='6.5'/><path d='m15.2 15.2 4.3 4.3M8 10.5h5M10.5 8v5'/>"
        case .zoomOut:
            "<circle cx='10.5' cy='10.5' r='6.5'/><path d='m15.2 15.2 4.3 4.3M8 10.5h5'/>"
        case .fitWidth:
            "<path d='M4 5v14M20 5v14'/><path d='M8 12h8M8 12l2-2M8 12l2 2M16 12l-2-2M16 12l-2 2'/>"
        }
    }
}

@MainActor
enum NylaiTheme {
    static let accent = NSColor(srgbRed: 0.16, green: 0.47, blue: 0.95, alpha: 1)

    static func isDark(_ appearance: NSAppearance = NSApp.effectiveAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func panelBackground(
        for appearance: NSAppearance = NSApp.effectiveAppearance
    ) -> NSColor {
        isDark(appearance)
            ? NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 0.97)
            : NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 0.97)
    }

    static func imageBackground(
        for appearance: NSAppearance = NSApp.effectiveAppearance
    ) -> NSColor {
        isDark(appearance)
            ? NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1)
            : NSColor(srgbRed: 0.95, green: 0.95, blue: 0.97, alpha: 1)
    }

    static func primaryText(
        for appearance: NSAppearance = NSApp.effectiveAppearance
    ) -> NSColor {
        isDark(appearance)
            ? NSColor.white.withAlphaComponent(0.92)
            : NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1)
    }

    static func secondaryText(
        for appearance: NSAppearance = NSApp.effectiveAppearance
    ) -> NSColor {
        isDark(appearance)
            ? NSColor.white.withAlphaComponent(0.62)
            : NSColor(srgbRed: 0.34, green: 0.34, blue: 0.38, alpha: 1)
    }

    static func border(
        for appearance: NSAppearance = NSApp.effectiveAppearance
    ) -> NSColor {
        isDark(appearance)
            ? NSColor.white.withAlphaComponent(0.18)
            : NSColor.black.withAlphaComponent(0.16)
    }
}
