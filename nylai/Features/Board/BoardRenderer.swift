import AppKit

@MainActor
enum BoardRenderer {
    static func draw(_ item: BoardItem, in frame: CGRect, scale: CGFloat, store: BoardStore) {
        let context = NSGraphicsContext.current
        context?.saveGraphicsState()
        defer { context?.restoreGraphicsState() }
        switch item.kind {
        case .note:
            if item.color != .clear {
                item.color.paper.setFill()
                NSBezierPath(roundedRect: frame, xRadius: 5 * scale, yRadius: 5 * scale).fill()
            }
            let textRect = frame.insetBy(dx: 12 * scale, dy: 10 * scale)
            NSBezierPath(rect: frame).addClip()
            let text = noteText(item.text, scale: scale, darkInk: item.color != .clear)
            text.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        case .image:
            if let asset = item.asset, let image = store.image(asset) {
                image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                NSColor.quaternaryLabelColor.setFill()
                NSBezierPath(rect: frame).fill()
                (L10n.shared.string("图片不可用") as NSString).draw(at: frame.origin, withAttributes: [.foregroundColor: NSColor.labelColor])
            }
        case .rectangle, .ellipse:
            item.color.ink.setStroke()
            let path = item.kind == .rectangle ? NSBezierPath(rect: frame) : NSBezierPath(ovalIn: frame)
            path.lineWidth = max(0.8, item.strokeWidth * scale)
            path.stroke()
        case .pen, .marker, .line, .arrow:
            let points = item.points.map { CGPoint(x: frame.minX + $0.x * frame.width,
                                                   y: frame.minY + $0.y * frame.height) }
            guard let first = points.first, let last = points.last else { return }
            let path = NSBezierPath()
            path.lineWidth = max(0.8, item.strokeWidth * scale * (item.kind == .marker ? 4 : 1))
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            item.color.ink.withAlphaComponent(item.kind == .marker ? 0.3 : 1).setStroke()
            path.move(to: first)
            if points.count == 1 { path.line(to: CGPoint(x: first.x + 0.1, y: first.y + 0.1)) }
            else { for point in points.dropFirst() { path.line(to: point) } }
            if item.kind == .arrow, points.count >= 2 {
                let previous = points[points.count - 2]
                let angle = atan2(last.y - previous.y, last.x - previous.x)
                let length = max(9 * scale, path.lineWidth * 4)
                path.move(to: CGPoint(x: last.x - length * cos(angle - .pi / 6),
                                      y: last.y - length * sin(angle - .pi / 6)))
                path.line(to: last)
                path.line(to: CGPoint(x: last.x - length * cos(angle + .pi / 6),
                                      y: last.y - length * sin(angle + .pi / 6)))
            }
            path.stroke()
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

    static func export(_ items: [BoardItem], store: BoardStore) -> NSImage? {
        let bounds = items.map(\.frame).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -20, dy: -20)
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
