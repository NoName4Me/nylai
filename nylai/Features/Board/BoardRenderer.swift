import AppKit

@MainActor
enum BoardRenderer {
    static func draw(_ item: BoardItem, in frame: CGRect, scale: CGFloat, store: BoardStore, showsNoteControls: Bool = false, hidesNoteText: Bool = false) {
        let context = NSGraphicsContext.current
        context?.saveGraphicsState()
        defer { context?.restoreGraphicsState() }
        if item.kind.isAnnotation, item.angle != 0 {
            context?.cgContext.concatenate(BoardGeometry.transform(frame, angle: item.angle))
        }
        switch item.kind {
        case .note:
            drawNote(item, frame: frame, scale: scale, showsControls: showsNoteControls, hidesText: hidesNoteText)
        case .image:
            if let asset = item.asset, let image = store.image(asset) {
                image.draw(in: BoardGeometry.imageRect(frame, imageSize: image.size), from: CGRect(origin: .zero, size: image.size), operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                NSColor.quaternaryLabelColor.setFill()
                NSBezierPath(rect: frame).fill()
                (L10n.shared.string("图片不可用") as NSString).draw(at: frame.origin, withAttributes: [.foregroundColor: NSColor.labelColor])
            }
        case .rectangle, .ellipse, .triangle, .diamond, .star:
            guard let shape = AnnotationShape(rawValue: item.kind.rawValue), let cg = NSGraphicsContext.current?.cgContext else { return }
            cg.addPath(AnnotationGeometry.shape(shape, in: frame, cornerRadius: item.radius * scale))
            cg.setStrokeColor(item.color.ink.withAlphaComponent(item.strokeOpacity).cgColor)
            let width = max(0.8, item.effectiveStrokeWidth * scale)
            cg.setLineWidth(width)
            if item.dashed == true { cg.setLineDash(phase: 0, lengths: [width * 3, width * 2]) }
            cg.setLineJoin(.round)
            if item.filled == true {
                cg.setFillColor(item.color.ink.withAlphaComponent(item.strokeOpacity).cgColor)
                cg.drawPath(using: .fillStroke)
            } else { cg.strokePath() }
        case .pen, .marker, .line, .arrow:
            let points = item.points.map { CGPoint(x: frame.minX + $0.x * frame.width,
                                                   y: frame.minY + $0.y * frame.height) }
            guard let last = points.last, let cg = NSGraphicsContext.current?.cgContext else { return }
            let path = CGMutablePath()
            AnnotationGeometry.appendPolyline(points, to: path)
            let width = max(0.8, item.effectiveStrokeWidth * scale)
            if item.kind == .arrow, points.count >= 2 {
                let previous = points[points.count - 2]
                let angle = atan2(last.y - previous.y, last.x - previous.x)
                let length = max(9 * scale, width * 4)
                path.move(to: CGPoint(x: last.x - length * cos(angle - .pi / 6), y: last.y - length * sin(angle - .pi / 6)))
                path.addLine(to: last)
                path.addLine(to: CGPoint(x: last.x - length * cos(angle + .pi / 6), y: last.y - length * sin(angle + .pi / 6)))
            }
            cg.addPath(path)
            cg.setLineWidth(width)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.setStrokeColor(item.color.ink.withAlphaComponent(item.strokeOpacity).cgColor)
            if item.dashed == true { cg.setLineDash(phase: 0, lengths: [width * 3, width * 2]) }
            cg.strokePath()
        }
    }

    static func noteColorRect(_ frame: CGRect, scale: CGFloat = 1) -> CGRect {
        CGRect(x: frame.minX + 8 * scale, y: frame.minY + 7 * scale, width: 20 * scale, height: 20 * scale)
    }
    static func noteCollapseRect(_ frame: CGRect, scale: CGFloat = 1) -> CGRect {
        CGRect(x: frame.maxX - 29 * scale, y: frame.minY + 7 * scale, width: 22 * scale, height: 22 * scale)
    }

    private static func drawNote(_ item: BoardItem, frame: CGRect, scale: CGFloat, showsControls: Bool, hidesText: Bool) {
        let colored = item.color != .clear
        if colored {
            let fold = item.isCollapsed ? 0 : min(13 * scale, frame.width / 5, frame.height / 5)
            let paper = NSBezierPath()
            paper.move(to: frame.origin)
            paper.line(to: CGPoint(x: frame.maxX, y: frame.minY))
            paper.line(to: CGPoint(x: frame.maxX, y: frame.maxY - fold))
            paper.line(to: CGPoint(x: frame.maxX - fold, y: frame.maxY))
            paper.line(to: CGPoint(x: frame.minX, y: frame.maxY))
            paper.close()
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
            shadow.shadowBlurRadius = 5 * scale
            shadow.shadowOffset = CGSize(width: scale, height: -2 * scale)
            shadow.set()
            item.color.paper.setFill()
            paper.fill()
            NSGraphicsContext.restoreGraphicsState()
            if fold > 0 {
                let corner = NSBezierPath()
                corner.move(to: CGPoint(x: frame.maxX - fold, y: frame.maxY - fold))
                corner.line(to: CGPoint(x: frame.maxX, y: frame.maxY - fold))
                corner.line(to: CGPoint(x: frame.maxX - fold, y: frame.maxY))
                corner.close()
                item.color.ink.withAlphaComponent(0.18).setFill()
                corner.fill()
            }
        }
        NSBezierPath(rect: frame).addClip()
        let ink = colored ? NSColor(calibratedWhite: 0.22, alpha: 1) : NSColor.labelColor
        if showsControls && frame.width >= 50 * scale {
            let circle = noteColorRect(frame, scale: scale).insetBy(dx: 4 * scale, dy: 4 * scale)
            item.color.ink.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: circle).fill()
            let control = noteCollapseRect(frame, scale: scale)
            let delta: CGFloat = item.isCollapsed ? 3 * scale : -3 * scale
            let arrow = NSBezierPath()
            arrow.move(to: CGPoint(x: control.midX - 4 * scale, y: control.midY - delta))
            arrow.line(to: CGPoint(x: control.midX, y: control.midY + delta))
            arrow.line(to: CGPoint(x: control.midX + 4 * scale, y: control.midY - delta))
            ink.withAlphaComponent(0.7).setStroke()
            arrow.lineWidth = 1.4 * scale
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.stroke()
        }
        if hidesText { return }
        if item.isCollapsed {
            let text = item.text.components(separatedBy: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? L10n.shared.string("便签")
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let inset = showsControls ? 32 * scale : 12 * scale
            let area = CGRect(x: frame.minX + inset, y: frame.minY + 10 * scale, width: max(1, frame.width - 2 * inset), height: 20 * scale)
            (text as NSString).draw(in: area, withAttributes: [.font: NSFont.systemFont(ofSize: 13 * scale), .foregroundColor: ink, .paragraphStyle: paragraph])
        } else {
            let top = 32 * scale
            let area = CGRect(x: frame.minX + 12 * scale, y: frame.minY + top, width: max(1, frame.width - 24 * scale), height: max(1, frame.height - top - 10 * scale))
            noteText(item.text, scale: scale, darkInk: colored).draw(with: area, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
    }

    static func noteText(_ markdown: String, scale: CGFloat, darkInk: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let ink = darkInk ? NSColor(calibratedWhite: 0.16, alpha: 1) : NSColor.labelColor
        let lines = markdown.components(separatedBy: "\n")
        var code = false
        for (index, raw) in lines.enumerated() {
            var line = raw
            var font = NSFont.systemFont(ofSize: 14 * scale)
            var strike = false
            if line.hasPrefix("```") {
                code.toggle()
                continue
            }
            if code {
                font = NSFont.monospacedSystemFont(ofSize: 13 * scale, weight: .regular)
            } else if line.hasPrefix("# ") {
                font = .systemFont(ofSize: 21 * scale, weight: .semibold)
                line.removeFirst(2)
            } else if line.hasPrefix("## ") || line.hasPrefix("### ") {
                font = .systemFont(ofSize: 17 * scale, weight: .semibold)
                line = String(line.drop(while: { $0 == "#" || $0 == " " }))
            } else if line.hasPrefix("- [ ] ") {
                line = "☐ " + line.dropFirst(6)
            } else if line.lowercased().hasPrefix("- [x] ") {
                line = "☑ " + line.dropFirst(6)
                strike = true
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                line = "• " + line.dropFirst(2)
            } else if line.hasPrefix("> ") {
                line = "│ " + line.dropFirst(2)
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 2 * scale
            paragraph.paragraphSpacing = 3 * scale
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink, .paragraphStyle: paragraph]
            if strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            let formatted = NSMutableAttributedString(string: line, attributes: attributes)
            if !code {
                // Apply inline Markdown in reverse so replacing markers never shifts earlier ranges.
                let patterns: [(String, NSAttributedString.Key, Any)] = [
                    ("\\*\\*(.+?)\\*\\*", .font, NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)),
                    ("(?<!\\*)\\*([^*]+)\\*(?!\\*)", .font, NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)),
                    ("`([^`]+)`", .font, NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)),
                    ("~~(.+?)~~", .strikethroughStyle, NSUnderlineStyle.single.rawValue),
                    ("\\[([^\\]]+)\\]\\([^)]+\\)", .foregroundColor, NSColor.systemBlue)
                ]
                for (pattern, key, value) in patterns {
                    guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                    let matches = regex.matches(in: formatted.string, range: NSRange(location: 0, length: formatted.length))
                    for match in matches.reversed() {
                        let content = (formatted.string as NSString).substring(with: match.range(at: 1))
                        formatted.replaceCharacters(in: match.range, with: content)
                        formatted.addAttribute(key, value: value, range: NSRange(location: match.range.location, length: (content as NSString).length))
                    }
                }
            }
            result.append(formatted)
            if index < lines.count - 1 { result.append(NSAttributedString(string: "\n", attributes: attributes)) }
        }
        return result
    }

    static func todoLine(in item: BoardItem, at point: CGPoint) -> Int? {
        guard item.kind == .note, !item.locked, !item.isCollapsed else { return nil }
        let area = CGRect(x: item.frame.minX + 12, y: item.frame.minY + 32, width: max(1, item.frame.width - 24), height: max(1, item.frame.height - 42))
        guard area.contains(point), point.x <= area.minX + 20 else { return nil }
        let lines = item.text.components(separatedBy: "\n")
        var y = area.minY
        var code = false
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("```") { code.toggle(); continue }
            let text = noteText(line.isEmpty ? " " : line, scale: 1, darkInk: true)
            let height = max(17, ceil(text.boundingRect(with: CGSize(width: area.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)) + 3
            if !code, point.y >= y, point.y < y + height,
               line.hasPrefix("- [ ] ") || line.lowercased().hasPrefix("- [x] ") { return index }
            y += height
        }
        return nil
    }

    static func export(_ items: [BoardItem], store: BoardStore) -> NSImage? {
        let bounds = items.map(\.rotatedBounds).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -20, dy: -20)
        guard !bounds.isNull, bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0,
              bounds.width <= 12_000, bounds.height <= 12_000,
              bounds.width * bounds.height <= 40_000_000 else { return nil }
        let image = NSImage(size: CGSize(width: ceil(bounds.width), height: ceil(bounds.height)))
        image.lockFocusFlipped(true)
        defer { image.unlockFocus() }
        NSColor.white.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: image.size)).fill()
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            for item in items {
                draw(item, in: item.frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY), scale: 1, store: store)
            }
        }
        return image
    }
}
