import AppKit
import SwiftUI

@MainActor
class FloatingToolbarSurfaceView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.zPosition = 20
        updateBorderColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从归档创建截图工具栏")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    private func updateBorderColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NylaiTheme.isDark(effectiveAppearance)
                ? NSColor(srgbRed: 0.16, green: 0.18, blue: 0.13, alpha: 1).cgColor
                : NSColor(srgbRed: 0.995, green: 0.992, blue: 0.982, alpha: 1).cgColor
            layer?.borderColor = NylaiTheme.border(for: effectiveAppearance).cgColor
        }
    }
}

@MainActor
final class ToolbarIconButton: NSButton, NSViewToolTipOwner {
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet { updateSurface() }
    }

    override var isEnabled: Bool {
        didSet { updateSurface() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateSurface()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从归档创建截图工具按钮")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        removeAllToolTips()
        addToolTip(bounds, owner: self, userData: nil)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateOverlayHint(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateOverlayHint(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        overlayView?.dismissHoverHint()
        super.mouseDown(with: event)
    }

    private var overlayView: ScreenshotOverlayView? {
        var ancestor = superview
        while let view = ancestor {
            if let overlay = view as? ScreenshotOverlayView { return overlay }
            ancestor = view.superview
        }
        return nil
    }

    private func updateOverlayHint(with event: NSEvent) {
        guard let overlay = overlayView else { return }
        overlay.updateHoverHint(at: overlay.convert(event.locationInWindow, from: nil))
    }

    func refreshSurface() {
        updateSurface()
    }

    func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        toolTip ?? ""
    }

    private func updateSurface() {
        guard let layer else { return }
        let color: NSColor
        if !isEnabled {
            color = .clear
        } else if state == .on {
            color = NylaiTheme.accent.withAlphaComponent(0.18)
        } else if isHovered {
            color = NSColor.labelColor.withAlphaComponent(0.10)
        } else {
            color = .clear
        }
        layer.backgroundColor = color.cgColor
    }
}

@MainActor
final class SelectionToolbarView: FloatingToolbarSurfaceView {
    var onToolChanged: ((ScreenshotEditorTool) -> Void)?
    var onStyleChanged: ((ScreenshotAnnotationStyle) -> Void)?
    var onAppearanceChanged: ((ScreenshotOutputAppearance) -> Void)?

    var isOutputting = false { didSet { updateEnabledState() } }
    var styleControlsEnabled = false {
        didSet {
            styleRow.isHidden = !styleControlsEnabled
            updateEnabledState()
        }
    }
    var styleKind: ScreenshotAnnotationKind? {
        didSet {
            updateStyleControlRanges()
            updateToolSelection()
            updateEnabledState()
        }
    }
    var selectedTool = ScreenshotEditorTool.selection {
        didSet { updateToolSelection() }
    }
    var style = ScreenshotAnnotationStyle.default {
        didSet {
            guard !isUpdatingStyleControls else { return }
            updateStyleControls()
        }
    }
    var outputAppearance = ScreenshotOutputAppearance.default {
        didSet { updateShadowButton() }
    }

    var preferredContentSize: CGSize {
        CGSize(width: 330, height: styleControlsEnabled ? (styleKind == .arrow ? 128 : 78) : 44)
    }

    private let tools: [ScreenshotEditorTool] = [
        .rectangle, .ellipse, .line, .arrow, .brush, .text, .step, .mosaic,
    ]
    private var toolButtons: [(ScreenshotEditorTool, NSButton)] = []
    private let colorButton = ScreenshotColorSwatchButton()
    private let widthLabel = NSTextField(labelWithString: "3")
    private let widthStepper = NSStepper()
    private var arrowOptionsHost: NSHostingView<AnyView>?
    private let textStyleControl = NSSegmentedControl(labels: ["A", "A"],
                                                       trackingMode: .selectOne, target: nil, action: nil)
    private let solidButton = ToolbarIconButton()
    private let dashedButton = ToolbarIconButton()
    private let fillButton = NSButton(
        checkboxWithTitle: L10n.shared.string("填充"),
        target: nil,
        action: nil
    )
    private let shadowButton = ToolbarIconButton()
    private lazy var styleRow = NSStackView()
    private var colorPopover: NSPopover?
    private var shadowPopover: NSPopover?
    private var isUpdatingStyleControls = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureSurface()

        let toolRow = NSStackView()
        toolRow.orientation = .horizontal
        toolRow.alignment = .centerY
        toolRow.spacing = 4
        for tool in tools {
            let icon = Self.icon(for: tool)
            let button = Self.iconButton(icon: icon, label: icon.accessibilityLabel)
            button.target = self
            button.action = #selector(toolChanged(_:))
            toolButtons.append((tool, button))
            toolRow.addArrangedSubview(button)
        }
        toolRow.addArrangedSubview(Self.separator(orientation: .vertical))
        Self.configure(iconButton: shadowButton, icon: .shadow, action: #selector(shadowClicked), target: self)
        toolRow.addArrangedSubview(shadowButton)

        configureStyleControls()
        styleRow.orientation = .horizontal
        styleRow.alignment = .centerY
        styleRow.spacing = 5
        styleRow.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        styleRow.isHidden = true

        let arrowOptionsHost = NSHostingView(
            rootView: AnyView(makeArrowOptionsView().nylaiLocalized())
        )
        arrowOptionsHost.widthAnchor.constraint(equalToConstant: 310).isActive = true
        arrowOptionsHost.heightAnchor.constraint(equalToConstant: 47).isActive = true
        arrowOptionsHost.isHidden = true
        self.arrowOptionsHost = arrowOptionsHost
        let stack = NSStackView(views: [toolRow, styleRow, arrowOptionsHost])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let bottom = stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            bottom,
        ])
        updateStyleControls()
        updateStyleControlRanges()
        updateToolSelection()
        updateShadowButton()
        updateEnabledState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从归档创建标注工具栏")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        return result === self ? nil : result
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    private func configureSurface() {}

    private func configureStyleControls() {
        colorButton.size = 24
        colorButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        colorButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        fillButton.controlSize = .small
        fillButton.target = self
        fillButton.action = #selector(fillChanged)
        colorButton.target = self
        colorButton.action = #selector(colorClicked)
        colorButton.toolTip = L10n.shared.string("标注颜色")
        colorButton.setAccessibilityLabel(L10n.shared.string("标注颜色"))

        widthLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        widthLabel.alignment = .right
        widthLabel.widthAnchor.constraint(equalToConstant: 24).isActive = true

        widthStepper.increment = 1
        widthStepper.valueWraps = false
        widthStepper.controlSize = .small
        widthStepper.target = self
        widthStepper.action = #selector(styleControlChanged)
        widthStepper.setAccessibilityLabel(L10n.shared.string("标注参数"))

        Self.configure(
            iconButton: solidButton,
            icon: .solidLine,
            action: #selector(lineStyleChanged(_:)),
            target: self
        )
        Self.configure(
            iconButton: dashedButton,
            icon: .dashedLine,
            action: #selector(lineStyleChanged(_:)),
            target: self
        )
        textStyleControl.controlSize = .small
        textStyleControl.target = self
        textStyleControl.action = #selector(annotationVariantChanged)
        textStyleControl.toolTip = L10n.shared.string("文字样式")
        for (index, symbol) in ["a.square", "a.square.fill"].enumerated() {
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                textStyleControl.setImage(image, forSegment: index)
                textStyleControl.setLabel("", forSegment: index)
            } else {
                textStyleControl.setLabel(
                    index == 0
                        ? L10n.shared.string("普通")
                        : L10n.shared.string("填充"),
                    forSegment: index
                )
            }
            textStyleControl.setToolTip(
                index == 0
                    ? L10n.shared.string("普通文字")
                    : L10n.shared.string("填充文字背景"),
                forSegment: index
            )
        }
        fillButton.toolTip = L10n.shared.string("使用描边颜色填充")
        styleRow = NSStackView(views: [
            colorButton, widthLabel, widthStepper, solidButton, dashedButton, fillButton,
            textStyleControl,
        ])
    }

    private func updateToolSelection() {
        for (tool, button) in toolButtons {
            Self.setSelected(button, selected: tool.annotationKind == styleKind || (styleKind == nil && tool == selectedTool))
        }
    }

    private func updateEnabledState() {
        for (_, button) in toolButtons {
            button.isEnabled = !isOutputting
        }
        let stylesEnabled = !isOutputting && styleControlsEnabled
        let supportsColor = styleKind?.supportsColorControl ?? false
        colorButton.isHidden = !supportsColor
        colorButton.isEnabled = stylesEnabled && supportsColor
        widthStepper.isEnabled = stylesEnabled && styleKind != .step
        widthLabel.textColor = widthStepper.isEnabled ? .labelColor : .tertiaryLabelColor
        let supportsLine = styleKind != .arrow && (styleKind?.supportsLineStyleControl ?? false)
        solidButton.isHidden = !supportsLine
        dashedButton.isHidden = !supportsLine
        solidButton.isEnabled = stylesEnabled && supportsLine
        dashedButton.isEnabled = stylesEnabled && supportsLine
        fillButton.isHidden = styleKind?.supportsFill != true
        fillButton.isEnabled = stylesEnabled
        arrowOptionsHost?.isHidden = !styleControlsEnabled || styleKind != .arrow
        arrowOptionsHost?.rootView = AnyView(makeArrowOptionsView().nylaiLocalized())
        textStyleControl.isHidden = styleKind != .text
        textStyleControl.isEnabled = stylesEnabled
        shadowButton.isEnabled = !isOutputting
    }

    private func updateStyleControlRanges() {
        guard let styleKind else {
            widthLabel.stringValue = ""
            return
        }
        let range = styleKind.lineWidthRange
        widthStepper.minValue = Double(range.lowerBound)
        widthStepper.maxValue = Double(range.upperBound)
        widthStepper.toolTip = "\(styleKind.lineWidthControlTitle) \(range.lowerBound)–\(range.upperBound)"
    }

    private func updateStyleControls() {
        isUpdatingStyleControls = true
        fillButton.state = style.fillsShape == true ? .on : .off
        textStyleControl.selectedSegment = style.fillsTextBackground == true ? 1 : 0
        colorButton.color = style.color
        widthStepper.integerValue = style.lineWidth
        widthLabel.stringValue = "\(style.lineWidth)"
        let solid = style.lineStyle == .solid
        Self.setSelected(solidButton, selected: solid)
        Self.setSelected(dashedButton, selected: !solid)
        arrowOptionsHost?.rootView = AnyView(makeArrowOptionsView().nylaiLocalized())
        isUpdatingStyleControls = false
    }

    private func updateShadowButton() {
        Self.setSelected(shadowButton, selected: outputAppearance.shadowEnabled)
    }

    private func showPopover(_ popover: NSPopover, relativeTo button: NSButton) {
        popover.behavior = .transient
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = popover.contentViewController?.view.window else {
                return
            }
            window.level = NSWindow.Level(
                rawValue: (self.window?.level.rawValue ?? 0) + 1
            )
        }
    }

    @objc private func toolChanged(_ sender: NSButton) {
        guard let index = toolButtons.firstIndex(where: { $0.1 === sender }) else { return }
        let tool = toolButtons[index].0
        selectedTool = tool
        onToolChanged?(tool)
    }

    @objc private func lineStyleChanged(_ sender: NSButton) {
        guard !isUpdatingStyleControls else { return }
        var updated = style
        updated.lineStyle = sender === solidButton ? .solid : .dashed
        style = updated
        onStyleChanged?(updated)
    }

    @objc private func styleControlChanged() {
        guard !isUpdatingStyleControls else { return }
        var updated = style
        updated.lineWidth = widthStepper.integerValue
        let validated = styleKind.map { updated.validated(for: $0) } ?? updated.validated()
        style = validated
        onStyleChanged?(validated)
    }

    private func makeArrowOptionsView() -> ArrowOptionsView {
        let options = style.arrowOptions ?? (style.arrowStyle == .solid
            ? ScreenshotArrowOptions(form: .body, tip: .triangle)
            : ScreenshotArrowOptions())
        return ArrowOptionsView(
            options: options.normalized(), lineStyle: style.lineStyle,
            enabled: !isOutputting && styleControlsEnabled
        ) { [weak self] options, lineStyle in
            guard let self, self.styleKind == .arrow else { return }
            var updated = self.style
            updated.arrowOptions = options
            updated.arrowStyle = nil
            updated.lineStyle = lineStyle
            self.style = updated
            self.onStyleChanged?(updated)
        }
    }

    @objc private func annotationVariantChanged(_ sender: NSSegmentedControl) {
        var updated = style
        if sender === textStyleControl {
            updated.fillsTextBackground = sender.selectedSegment == 1 ? true : nil
        }
        style = updated
        onStyleChanged?(updated)
    }

    @objc private func fillChanged() {
        var updated = style
        updated.fillsShape = fillButton.state == .on ? true : nil
        style = updated
        onStyleChanged?(updated)
    }

    @objc private func colorClicked() {
        colorPopover?.close()
        let controller = ScreenshotColorPopoverViewController(color: style.color)
        controller.onColorChanged = { [weak self] color in
            guard let self else { return }
            var updated = style
            updated.color = color
            let validated = styleKind.map { updated.validated(for: $0) } ?? updated.validated()
            style = validated
            onStyleChanged?(validated)
        }
        let popover = NSPopover()
        popover.contentViewController = controller
        colorPopover = popover
        showPopover(popover, relativeTo: colorButton)
    }

    @objc private func shadowClicked() {
        shadowPopover?.close()
        let controller = ScreenshotShadowPopoverViewController(
            appearance: outputAppearance
        )
        controller.onAppearanceChanged = { [weak self] appearance in
            guard let self else { return }
            outputAppearance = appearance
            onAppearanceChanged?(appearance)
        }
        let popover = NSPopover()
        popover.contentViewController = controller
        shadowPopover = popover
        showPopover(popover, relativeTo: shadowButton)
    }

    private static func icon(for tool: ScreenshotEditorTool) -> NylaiIcon {
        switch tool {
        case .selection: .crop
        case .objectSelection: .cursor
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .line: .line
        case .arrow: .arrow
        case .brush: .brush
        case .text: .text
        case .step: .step
        case .mosaic: .mosaic
        }
    }

    private static func configure(
        iconButton button: NSButton,
        icon: NylaiIcon,
        action: Selector,
        target: AnyObject
    ) {
        button.title = icon.accessibilityLabel
        button.image = icon.image(pointSize: 15)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.controlSize = .small
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.toolTip = icon.accessibilityLabel
        button.setAccessibilityLabel(icon.accessibilityLabel)
        button.target = target
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 29).isActive = true
        button.heightAnchor.constraint(equalToConstant: 29).isActive = true
    }

    static func iconButton(icon: NylaiIcon, label: String) -> NSButton {
        let button = ToolbarIconButton()
        button.title = label
        button.image = icon.image(pointSize: 15)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.controlSize = .small
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 29).isActive = true
        button.heightAnchor.constraint(equalToConstant: 29).isActive = true
        return button
    }

    static func setSelected(_ button: NSButton, selected: Bool) {
        button.state = selected ? .on : .off
        button.contentTintColor = selected ? NylaiTheme.accent : .labelColor
        (button as? ToolbarIconButton)?.refreshSurface()
    }

    static func separator(orientation: NSUserInterfaceLayoutOrientation) -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        if orientation == .vertical {
            separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
            separator.heightAnchor.constraint(equalToConstant: 22).isActive = true
        } else {
            separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        }
        return separator
    }
}

private struct ArrowOptionsView: View {
    let options: ScreenshotArrowOptions
    let lineStyle: ScreenshotAnnotationLineStyle
    let enabled: Bool
    let onChange: (ScreenshotArrowOptions, ScreenshotAnnotationLineStyle) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                choices("形状", [.line, .body], \.form, title: { $0.title })
                Picker("线型", selection: Binding(get: { lineStyle }, set: { onChange(options, $0) })) {
                    Text("实线").tag(ScreenshotAnnotationLineStyle.solid)
                    Text("虚线").tag(ScreenshotAnnotationLineStyle.dashed)
                }
                .pickerStyle(.segmented)
                if options.form == .body {
                    choices("比例", [false, true], \.tapered, title: { $0 ? "渐宽" : "常规" })
                    if !options.tapered {
                        choices("填充", [false, true], \.filled, title: { $0 ? "填充" : "描边" })
                    }
                }
            }
            HStack(spacing: 5) {
                choices("起点", options.allowedStarts, \.start, title: { $0.title })
                choices("末端", options.allowedTips, \.tip, title: { $0.title })
            }
        }
        .labelsHidden()
        .controlSize(.mini)
        .font(.system(size: 10))
        .disabled(!enabled)
        .tint(NylaiPalette.accent)
    }

    private func choices<Value: Hashable>(_ label: String, _ values: [Value],
                                          _ keyPath: WritableKeyPath<ScreenshotArrowOptions, Value>,
                                          title: @escaping (Value) -> String) -> some View {
        Picker(label, selection: Binding(
            get: { options[keyPath: keyPath] },
            set: { value in
                var updated = options
                updated[keyPath: keyPath] = value
                onChange(updated.normalized(), lineStyle)
            }
        )) {
            ForEach(values, id: \.self) { value in Text(title(value)).tag(value) }
        }
        .pickerStyle(.segmented)
        .help(label)
    }
}

@MainActor
final class ScreenshotOutputToolbarView: FloatingToolbarSurfaceView {
    var onCancel: () -> Void = {}
    var onUndo: () -> Void = {}
    var onRedo: () -> Void = {}
    var onDelete: () -> Void = {}
    var onToolChanged: ((ScreenshotEditorTool) -> Void)?
    var onReselect: () -> Void = {}
    var onScrollCapture: () -> Void = {}
    var onCopy: () -> Void = {}
    var onSave: () -> Void = {}
    var onPin: () -> Void = {}
    var onZoomIn: () -> Void = {}
    var onZoomOut: () -> Void = {}
    var onFitWidth: () -> Void = {}

    var showsSelectionTool = true { didSet { rebuildContent() } }
    var showsReselectButton = false { didSet { rebuildContent() } }
    var showsScrollCaptureButton = true { didSet { rebuildContent() } }
    var showsZoomControls = false { didSet { rebuildContent() } }
    var selectedTool = ScreenshotEditorTool.selection {
        didSet { updateToolSelection() }
    }
    var canUndo = false { didSet { updateEnabledState() } }
    var canRedo = false { didSet { updateEnabledState() } }
    var canDelete = false { didSet { updateEnabledState() } }
    var isOutputting = false { didSet { updateEnabledState() } }

    var preferredContentSize: CGSize {
        let groups = activeGroups
        let buttons = groups.reduce(0) { $0 + $1.count }
        let separators = max(0, groups.count - 1)
        let height = 14 + buttons * 26 + (buttons + separators - 1) * 3 + separators
        return CGSize(width: 40, height: height)
    }

    private let cropButton = ToolbarIconButton()
    private let cursorButton = ToolbarIconButton()
    private let scrollButton = ToolbarIconButton()
    private let reselectButton = ToolbarIconButton()
    private let copyButton = ToolbarIconButton()
    private let saveButton = ToolbarIconButton()
    private let pinButton = ToolbarIconButton()
    private let cancelButton = ToolbarIconButton()
    private let zoomOutButton = ToolbarIconButton()
    private let zoomInButton = ToolbarIconButton()
    private let fitButton = ToolbarIconButton()
    private var stack: NSStackView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        configure(cropButton, icon: .crop, action: #selector(cropClicked))
        configure(cursorButton, icon: .cursor, action: #selector(cursorClicked))
        configure(scrollButton, icon: .scroll, action: #selector(scrollCaptureClicked))
        configure(reselectButton, icon: .reselect, action: #selector(reselectClicked))
        configure(copyButton, icon: .copy, action: #selector(copyClicked))
        configure(saveButton, icon: .save, action: #selector(saveClicked))
        configure(pinButton, icon: .pin, action: #selector(pinClicked))
        configure(cancelButton, icon: .close, action: #selector(cancelClicked))
        configure(zoomOutButton, icon: .zoomOut, action: #selector(zoomOutClicked))
        configure(zoomInButton, icon: .zoomIn, action: #selector(zoomInClicked))
        configure(fitButton, icon: .fitWidth, action: #selector(fitClicked))
        rebuildContent()
        updateEnabledState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从归档创建输出工具栏")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        return result === self ? nil : result
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    private var activeGroups: [[NSButton]] {
        var groups: [[NSButton]] = []
        var selectionGroup: [NSButton] = []
        if showsSelectionTool {
            selectionGroup.append(cropButton)
        }
        selectionGroup.append(cursorButton)
        groups.append(selectionGroup)
        let scrollGroup = [
            showsScrollCaptureButton ? scrollButton : nil,
            showsReselectButton ? reselectButton : nil,
        ].compactMap { $0 }
        if !scrollGroup.isEmpty {
            groups.append(scrollGroup)
        }
        groups.append([copyButton, saveButton, pinButton, cancelButton])
        if showsZoomControls {
            groups.append([zoomOutButton, zoomInButton, fitButton])
        }
        return groups
    }

    private func rebuildContent() {
        stack?.removeFromSuperview()
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 3
        container.edgeInsets = NSEdgeInsets(top: 7, left: 7, bottom: 7, right: 7)
        for (index, group) in activeGroups.enumerated() {
            if index > 0 {
                let separator = SelectionToolbarView.separator(orientation: .horizontal)
                separator.widthAnchor.constraint(equalToConstant: 26).isActive = true
                container.addArrangedSubview(separator)
            }
            for button in group { container.addArrangedSubview(button) }
        }
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
        stack = container
        updateToolSelection()
        updateEnabledState()
    }

    private func configure(_ button: NSButton, icon: NylaiIcon, action: Selector) {
        button.title = icon.accessibilityLabel
        button.image = icon.image(pointSize: 15)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.controlSize = .small
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.toolTip = icon.accessibilityLabel
        button.setAccessibilityLabel(icon.accessibilityLabel)
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    private func updateToolSelection() {
        SelectionToolbarView.setSelected(cropButton, selected: selectedTool == .selection)
        SelectionToolbarView.setSelected(cursorButton, selected: selectedTool == .objectSelection)
    }

    private func updateEnabledState() {
        for button in [
            cropButton, cursorButton, scrollButton, reselectButton,
            copyButton, saveButton, pinButton, cancelButton,
            zoomOutButton, zoomInButton, fitButton,
        ] {
            button.isEnabled = !isOutputting
        }
    }

    @objc private func cropClicked() {
        selectedTool = .selection
        onToolChanged?(.selection)
    }

    @objc private func cursorClicked() {
        selectedTool = .objectSelection
        onToolChanged?(.objectSelection)
    }

    @objc private func scrollCaptureClicked() { onScrollCapture() }
    @objc private func reselectClicked() { onReselect() }
    @objc private func copyClicked() { onCopy() }
    @objc private func saveClicked() { onSave() }
    @objc private func pinClicked() { onPin() }
    @objc private func cancelClicked() { onCancel() }
    @objc private func zoomOutClicked() { onZoomOut() }
    @objc private func zoomInClicked() { onZoomIn() }
    @objc private func fitClicked() { onFitWidth() }
}

@MainActor
final class ScreenshotShadowPopoverViewController: NSViewController {
    var onAppearanceChanged: ((ScreenshotOutputAppearance) -> Void)?

    private var appearance: ScreenshotOutputAppearance
    private let toggle = NSButton(
        checkboxWithTitle: L10n.shared.string("启用阴影"),
        target: nil,
        action: nil
    )
    private let radiusSlider = NSSlider(value: 12, minValue: 0, maxValue: 64, target: nil, action: nil)
    private let opacitySlider = NSSlider(value: 25, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let offsetSlider = NSSlider(value: 4, minValue: 0, maxValue: 64, target: nil, action: nil)
    private let radiusValue = NSTextField(labelWithString: "")
    private let opacityValue = NSTextField(labelWithString: "")
    private let offsetValue = NSTextField(labelWithString: "")
    private var isUpdating = false

    init(appearance: ScreenshotOutputAppearance) {
        self.appearance = appearance
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 270, height: 174)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从归档创建阴影设置")
    }

    override func loadView() {
        let root = NSView(frame: CGRect(origin: .zero, size: preferredContentSize))
        view = root
        toggle.target = self
        toggle.action = #selector(valueChanged)
        for slider in [radiusSlider, opacitySlider, offsetSlider] {
            slider.target = self
            slider.action = #selector(valueChanged)
            slider.isContinuous = true
        }
        for label in [radiusValue, opacityValue, offsetValue] {
            label.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 30).isActive = true
        }
        let rows = [
            settingRow(title: L10n.shared.string("柔化"), slider: radiusSlider, value: radiusValue),
            settingRow(title: L10n.shared.string("浓度"), slider: opacitySlider, value: opacityValue),
            settingRow(title: L10n.shared.string("偏移"), slider: offsetSlider, value: offsetValue),
        ]
        let stack = NSStackView(views: [toggle] + rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -12),
        ])
        updateInterface()
    }

    private func settingRow(
        title: String,
        slider: NSSlider,
        value: NSTextField
    ) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 30).isActive = true
        slider.widthAnchor.constraint(equalToConstant: 156).isActive = true
        let row = NSStackView(views: [label, slider, value])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        return row
    }

    private func updateInterface() {
        guard isViewLoaded else { return }
        isUpdating = true
        toggle.state = appearance.shadowEnabled ? .on : .off
        radiusSlider.integerValue = appearance.shadowRadius
        opacitySlider.integerValue = appearance.shadowOpacity
        offsetSlider.integerValue = appearance.shadowOffset
        radiusValue.stringValue = "\(appearance.shadowRadius)"
        opacityValue.stringValue = "\(appearance.shadowOpacity)"
        offsetValue.stringValue = "\(appearance.shadowOffset)"
        isUpdating = false
    }

    @objc private func valueChanged() {
        guard !isUpdating else { return }
        appearance = ScreenshotOutputAppearance(
            roundedCornersEnabled: appearance.roundedCornersEnabled,
            cornerRadius: appearance.cornerRadius,
            shadowEnabled: toggle.state == .on,
            shadowRadius: radiusSlider.integerValue,
            shadowOpacity: opacitySlider.integerValue,
            shadowOffset: offsetSlider.integerValue
        ).validated()
        updateInterface()
        onAppearanceChanged?(appearance)
    }
}
