import AppKit

enum NylaiIcon: String, CaseIterable {
    case crop
    case cursor
    case rectangle
    case ellipse
    case line
    case arrow
    case brush
    case marker
    case text
    case step
    case stepFilled
    case mosaic
    case mosaicStroke
    case blur
    case cornerRounded
    case cornerSharp
    case recognize
    case edit
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
        case .crop: L10n.shared.string("选区")
        case .cursor: L10n.shared.string("选择标注")
        case .rectangle: L10n.shared.string("矩形")
        case .ellipse: L10n.shared.string("椭圆")
        case .line: L10n.shared.string("折线")
        case .arrow: L10n.shared.string("箭头")
        case .brush: L10n.shared.string("画笔")
        case .marker: L10n.shared.string("马克笔")
        case .text: L10n.shared.string("文字")
        case .step: L10n.shared.string("步骤")
        case .stepFilled: L10n.shared.string("填充步骤")
        case .mosaic: L10n.shared.string("打码")
        case .mosaicStroke: L10n.shared.string("马赛克涂抹")
        case .blur: L10n.shared.string("模糊")
        case .cornerRounded: L10n.shared.string("圆角")
        case .cornerSharp: L10n.shared.string("直角")
        case .recognize: L10n.shared.string("提取文字")
        case .edit: L10n.shared.string("编辑")
        case .undo: L10n.shared.string("撤销")
        case .redo: L10n.shared.string("重做")
        case .trash: L10n.shared.string("删除标注")
        case .scroll: L10n.shared.string("滚动截图")
        case .reselect: L10n.shared.string("重新选择")
        case .copy: L10n.shared.string("复制")
        case .save: L10n.shared.string("保存")
        case .pin: L10n.shared.string("置顶")
        case .close: L10n.shared.string("取消")
        case .shadow: L10n.shared.string("阴影")
        case .solidLine: L10n.shared.string("实线")
        case .dashedLine: L10n.shared.string("虚线")
        case .zoomIn: L10n.shared.string("放大")
        case .zoomOut: L10n.shared.string("缩小")
        case .fitWidth: L10n.shared.string("适合宽度")
        }
    }

    func image(pointSize: CGFloat = 16) -> NSImage {
        if self == .blur {
            return Self.blurImage(pointSize: pointSize)
        }
        if self == .stepFilled {
            return Self.filledStepImage(pointSize: pointSize)
        }
        let image = NSImage(named: assetName)
            ?? NSImage(
                systemSymbolName: "questionmark",
                accessibilityDescription: accessibilityLabel
            ) ?? NSImage()
        image.size = NSSize(width: pointSize, height: pointSize)
        image.isTemplate = true
        return image
    }

    var assetName: String { "Remix-\(rawValue)" }

    private static func blurImage(pointSize: CGFloat) -> NSImage {
        let image = NSImage(
            size: NSSize(width: pointSize, height: pointSize),
            flipped: false
        ) { rect in
            let side = min(rect.width, rect.height)
            let square = NSBezierPath(
                roundedRect: rect.insetBy(dx: side * 0.19, dy: side * 0.19),
                xRadius: side * 0.08,
                yRadius: side * 0.08
            )
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
            shadow.shadowBlurRadius = max(1.8, side * 0.17)
            shadow.shadowOffset = .zero
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            NSColor.black.withAlphaComponent(0.7).setStroke()
            square.lineWidth = max(1.5, side * 0.12)
            square.stroke()
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func filledStepImage(pointSize: CGFloat) -> NSImage {
        let image = NSImage(
            size: NSSize(width: pointSize, height: pointSize),
            flipped: false
        ) { rect in
            let side = min(rect.width, rect.height)
            let circle = NSBezierPath(ovalIn: rect.insetBy(
                dx: side * 0.11,
                dy: side * 0.11
            ))
            NSColor.black.setFill()
            circle.fill()
            guard let context = NSGraphicsContext.current?.cgContext else {
                return true
            }
            context.saveGState()
            context.setBlendMode(.destinationOut)
            let text = NSAttributedString(
                string: "1",
                attributes: [
                    .font: NSFont.systemFont(
                        ofSize: side * 0.56,
                        weight: .semibold
                    ),
                    .foregroundColor: NSColor.black,
                ]
            )
            let size = text.size()
            text.draw(at: CGPoint(
                x: rect.midX - size.width / 2,
                y: rect.midY - size.height / 2 + side * 0.01
            ))
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        return image
    }
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
            ? NylaiPalette.charcoal.withAlphaComponent(0.97)
            : NylaiPalette.paper.withAlphaComponent(0.97)
    }

    static func imageBackground(
        for appearance: NSAppearance = NSApp.effectiveAppearance
    ) -> NSColor {
        isDark(appearance)
            ? NSColor(srgbRed: 0.085, green: 0.095, blue: 0.09, alpha: 1)
            : NSColor(srgbRed: 0.94, green: 0.945, blue: 0.93, alpha: 1)
    }

    static func primaryText(
        for appearance: NSAppearance = NSApp.effectiveAppearance
    ) -> NSColor {
        isDark(appearance)
            ? NylaiPalette.paper.withAlphaComponent(0.94)
            : NylaiPalette.ink
    }

    static func secondaryText(
        for appearance: NSAppearance = NSApp.effectiveAppearance
    ) -> NSColor {
        isDark(appearance)
            ? NylaiPalette.paper.withAlphaComponent(0.64)
            : NSColor(srgbRed: 0.36, green: 0.39, blue: 0.37, alpha: 1)
    }

    static func border(
        for appearance: NSAppearance = NSApp.effectiveAppearance
    ) -> NSColor {
        isDark(appearance)
            ? NSColor.white.withAlphaComponent(0.18)
            : NSColor.black.withAlphaComponent(0.16)
    }
}
