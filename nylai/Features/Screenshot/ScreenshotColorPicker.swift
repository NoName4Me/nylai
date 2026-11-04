import AppKit

enum ScreenshotColorPalette {
    static let columnCount = 7
    static let rowCount = 8

    static let brightnessLevels: [CGFloat] = [1, 0.97, 0.94, 0.89, 0.78, 0.66, 0.48, 0.28]

    static func color(column: Int, row: Int) -> ScreenshotAnnotationColor {
        let safeColumn = min(max(column, 0), columnCount - 1)
        let safeRow = min(max(row, 0), rowCount - 1)
        let brightness = brightnessLevels[safeRow]
        if safeColumn == columnCount - 1 {
            return ScreenshotAnnotationColor(
                red: Double(brightness),
                green: Double(brightness),
                blue: Double(brightness),
                alpha: 1
            )
        }
        let hue = [0.0, 0.075, 0.14, 0.36, 0.58, 0.73][safeColumn]
        let saturation: CGFloat = [0.24, 0.45, 0.70, 0.90, 0.90, 0.90, 0.90, 0.90][safeRow]
        return NSColor(
            hue: hue,
            saturation: saturation,
            brightness: brightness,
            alpha: 1
        ).screenshotColor
    }

    static func parseHex(_ text: String) -> ScreenshotAnnotationColor? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }
        guard value.count == 6,
              let number = UInt32(value, radix: 16) else {
            return nil
        }
        return ScreenshotAnnotationColor(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension ScreenshotAnnotationColor {
    var hexText: String {
        String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
}

private extension NSColor {
    var screenshotColor: ScreenshotAnnotationColor {
        let color = usingColorSpace(.sRGB) ?? .systemRed
        return ScreenshotAnnotationColor(
            red: Double(color.redComponent),
            green: Double(color.greenComponent),
            blue: Double(color.blueComponent),
            alpha: 1
        )
    }
}

@MainActor
final class ScreenshotColorPopoverViewController: NSViewController {
    var onColorChanged: ((ScreenshotAnnotationColor) -> Void)?

    private(set) var color: ScreenshotAnnotationColor
    private var hue: CGFloat
    private var saturation: CGFloat
    private var brightness: CGFloat
    private var swatches: [ScreenshotColorSwatchButton] = []
    private var isUpdating = false
    private let preview = ScreenshotColorSwatchButton()
    private let hexField = NSTextField()
    private let fieldView = ColorSaturationBrightnessView()
    private let hueView = ColorHueSliderView()

    init(color: ScreenshotAnnotationColor) {
        self.color = color
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        (color.nsColor.usingColorSpace(.sRGB) ?? .systemRed).getHue(
            &h,
            saturation: &s,
            brightness: &b,
            alpha: &a
        )
        hue = h
        saturation = s
        brightness = b
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 404, height: 264)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从归档创建颜色选择器")
    }

    override func loadView() {
        let root = NSView(frame: CGRect(origin: .zero, size: preferredContentSize))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view = root
        buildContent(in: root)
        updateInterface()
    }

    func setColor(_ color: ScreenshotAnnotationColor, notify: Bool = false) {
        self.color = color
        let nsColor = color.nsColor.usingColorSpace(.sRGB) ?? .systemRed
        var nextHue: CGFloat = hue
        var nextSaturation: CGFloat = 0
        var nextBrightness: CGFloat = 0
        var alpha: CGFloat = 0
        nsColor.getHue(
            &nextHue,
            saturation: &nextSaturation,
            brightness: &nextBrightness,
            alpha: &alpha
        )
        if nextSaturation > 0.001 {
            hue = nextHue
        }
        saturation = nextSaturation
        brightness = nextBrightness
        updateInterface()
        if notify {
            onColorChanged?(color)
        }
    }

    private func buildContent(in root: NSView) {
        let left = buildPalette()
        let right = buildEditor()
        let stack = NSStackView(views: [left, right])
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -14),
        ])
    }

    private func buildPalette() -> NSView {
        var rows: [[NSView]] = []
        for row in 0..<ScreenshotColorPalette.rowCount {
            var views: [NSView] = []
            for column in 0..<ScreenshotColorPalette.columnCount {
                let swatch = ScreenshotColorSwatchButton()
                swatch.color = ScreenshotColorPalette.color(column: column, row: row)
                swatch.size = 20
                swatch.target = self
                swatch.action = #selector(paletteColorChanged(_:))
                swatch.toolTip = swatch.color.hexText
                swatch.setAccessibilityLabel(swatch.color.hexText)
                swatch.widthAnchor.constraint(equalToConstant: 20).isActive = true
                swatch.heightAnchor.constraint(equalToConstant: 20).isActive = true
                swatches.append(swatch)
                views.append(swatch)
            }
            rows.append(views)
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 5
        grid.columnSpacing = 5
        grid.xPlacement = .leading
        grid.yPlacement = .top
        return grid
    }

    private func buildEditor() -> NSView {
        preview.size = 28
        preview.isInteractive = false
        preview.widthAnchor.constraint(equalToConstant: 28).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 28).isActive = true

        hexField.font = .monospacedSystemFont(ofSize: 11.5, weight: .medium)
        hexField.alignment = .left
        hexField.target = self
        hexField.action = #selector(hexChanged)
        hexField.placeholderString = "#RRGGBB"
        hexField.setAccessibilityLabel("十六进制颜色")
        hexField.widthAnchor.constraint(equalToConstant: 92).isActive = true

        let previewRow = NSStackView(views: [preview, hexField])
        previewRow.orientation = .horizontal
        previewRow.alignment = .centerY
        previewRow.spacing = 8

        fieldView.translatesAutoresizingMaskIntoConstraints = false
        fieldView.widthAnchor.constraint(equalToConstant: 176).isActive = true
        fieldView.heightAnchor.constraint(equalToConstant: 132).isActive = true
        fieldView.onChange = { [weak self] saturation, brightness in
            guard let self else { return }
            self.saturation = saturation
            self.brightness = brightness
            self.applyCurrentHSB(notify: true)
        }

        hueView.translatesAutoresizingMaskIntoConstraints = false
        hueView.widthAnchor.constraint(equalToConstant: 176).isActive = true
        hueView.heightAnchor.constraint(equalToConstant: 16).isActive = true
        hueView.onChange = { [weak self] hue in
            guard let self else { return }
            self.hue = hue
            self.applyCurrentHSB(notify: true)
        }

        let stack = NSStackView(views: [previewRow, fieldView, hueView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        return stack
    }

    private func applyCurrentHSB(notify: Bool) {
        let next = NSColor(
            hue: hue,
            saturation: saturation,
            brightness: brightness,
            alpha: 1
        ).screenshotColor
        color = next
        updateInterface()
        if notify {
            onColorChanged?(next)
        }
    }

    private func updateInterface() {
        guard isViewLoaded else { return }
        isUpdating = true
        preview.color = color
        hexField.stringValue = color.hexText
        fieldView.hue = hue
        fieldView.saturation = saturation
        fieldView.brightness = brightness
        hueView.hue = hue
        for swatch in swatches {
            swatch.isSelected = swatch.color == color
        }
        isUpdating = false
    }

    @objc private func paletteColorChanged(_ sender: ScreenshotColorSwatchButton) {
        guard !isUpdating else { return }
        setColor(sender.color, notify: true)
    }

    @objc private func hexChanged() {
        guard let parsed = ScreenshotColorPalette.parseHex(hexField.stringValue) else {
            NSSound.beep()
            hexField.stringValue = color.hexText
            return
        }
        setColor(parsed, notify: true)
    }
}

@MainActor
final class ScreenshotColorSwatchButton: NSButton {
    var color = ScreenshotAnnotationColor.defaultRed {
        didSet { updateAppearance() }
    }
    var isSelected = false {
        didSet { updateAppearance() }
    }
    var isInteractive = true
    var size: CGFloat = 20 {
        didSet { updateAppearance() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        wantsLayer = true
        focusRingType = .none
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从归档创建颜色按钮")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isInteractive ? super.hitTest(point) : nil
    }

    private func updateAppearance() {
        layer?.cornerRadius = max(3, size * 0.22)
        layer?.backgroundColor = color.nsColor.cgColor
        layer?.borderWidth = isSelected ? 2 : 1
        layer?.borderColor = (
            isSelected ? NylaiTheme.accent : NSColor.separatorColor
        ).cgColor
    }
}

@MainActor
private final class ColorSaturationBrightnessView: NSView {
    var hue: CGFloat = 0 { didSet { needsDisplay = true } }
    var saturation: CGFloat = 0.8 { didSet { needsDisplay = true } }
    var brightness: CGFloat = 0.9 { didSet { needsDisplay = true } }
    var onChange: ((CGFloat, CGFloat) -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let path = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        path.addClip()
        NSColor(hue: hue, saturation: 1, brightness: 1, alpha: 1).setFill()
        bounds.fill()
        if let white = NSGradient(colors: [
            NSColor.white,
            NSColor.white.withAlphaComponent(0),
        ]) {
            white.draw(in: bounds, angle: 0)
        }
        if let black = NSGradient(colors: [
            NSColor.black.withAlphaComponent(0),
            NSColor.black,
        ]) {
            black.draw(from: NSPoint(x: bounds.midX, y: bounds.minY),
                       to: NSPoint(x: bounds.midX, y: bounds.maxY),
                       options: [])
        }
        NSGraphicsContext.restoreGraphicsState()

        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        let knob = CGRect(
            x: saturation * bounds.width - 5,
            y: (1 - brightness) * bounds.height - 5,
            width: 10,
            height: 10
        )
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSColor.black.withAlphaComponent(0.55).setStroke()
        let outline = NSBezierPath(ovalIn: knob.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        update(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        update(with: event)
    }

    private func update(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        saturation = min(max(point.x / max(bounds.width, 1), 0), 1)
        brightness = min(max(1 - point.y / max(bounds.height, 1), 0), 1)
        onChange?(saturation, brightness)
    }
}

@MainActor
private final class ColorHueSliderView: NSView {
    var hue: CGFloat = 0 { didSet { needsDisplay = true } }
    var onChange: ((CGFloat) -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0, dy: 3),
            xRadius: 5,
            yRadius: 5
        )
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let colors = stride(from: 0.0, through: 1.0, by: 1.0 / 12.0).map {
            NSColor(hue: $0, saturation: 0.9, brightness: 1, alpha: 1)
        }
        NSGradient(colors: colors)?.draw(in: bounds, angle: 0)
        NSGraphicsContext.restoreGraphicsState()

        let knobX = hue * bounds.width
        let knob = CGRect(
            x: knobX - 4,
            y: bounds.midY - 6,
            width: 8,
            height: 12
        )
        NSColor.white.setFill()
        NSBezierPath(roundedRect: knob, xRadius: 3, yRadius: 3).fill()
        NSColor.black.withAlphaComponent(0.55).setStroke()
        let outline = NSBezierPath(roundedRect: knob.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        outline.lineWidth = 1
        outline.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        update(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        update(with: event)
    }

    private func update(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hue = min(max(point.x / max(bounds.width, 1), 0), 1)
        onChange?(hue)
    }
}
