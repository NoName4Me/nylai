import AppKit

@MainActor
final class SelectionToolbarView: NSVisualEffectView {
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
        CGSize(width: 330, height: styleControlsEnabled ? 78 : 44)
    }

    private let tools: [ScreenshotEditorTool] = [
        .rectangle, .ellipse, .line, .arrow, .brush, .text, .step, .mosaic,
    ]
    private var toolButtons: [(ScreenshotEditorTool, NSButton)] = []
    private let colorButton = ScreenshotColorSwatchButton()
    private let widthCaption = NSTextField(labelWithString: "粗细")
    private let widthLabel = NSTextField(labelWithString: "3")
    private let widthStepper = NSStepper()
    private let solidButton = NSButton()
    private let dashedButton = NSButton()
    private let shadowButton = NSButton()
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
        styleRow.spacing = 8
        styleRow.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        styleRow.isHidden = true

        let stack = NSStackView(views: [toolRow, styleRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
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

    private func configureSurface() {
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
    }

    private func configureStyleControls() {
        colorButton.size = 24
        colorButton.title = "颜色"
        colorButton.target = self
        colorButton.action = #selector(colorClicked)
        colorButton.toolTip = "标注颜色"
        colorButton.setAccessibilityLabel("标注颜色")

        widthCaption.font = .systemFont(ofSize: 11)
        widthCaption.textColor = .secondaryLabelColor
        widthLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        widthLabel.alignment = .right
        widthLabel.widthAnchor.constraint(equalToConstant: 24).isActive = true

        widthStepper.increment = 1
        widthStepper.valueWraps = false
        widthStepper.controlSize = .small
        widthStepper.target = self
        widthStepper.action = #selector(styleControlChanged)
        widthStepper.setAccessibilityLabel("标注参数")

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
        styleRow = NSStackView(views: [
            colorButton, widthCaption, widthLabel, widthStepper, solidButton, dashedButton,
        ])
    }

    private func updateToolSelection() {
        for (tool, button) in toolButtons {
            Self.setSelected(button, selected: tool == selectedTool)
        }
    }

    private func updateEnabledState() {
        for (_, button) in toolButtons {
            button.isEnabled = !isOutputting
        }
        let stylesEnabled = !isOutputting && styleControlsEnabled
        colorButton.isEnabled = stylesEnabled && (styleKind?.supportsColorControl ?? false)
        widthStepper.isEnabled = stylesEnabled && styleKind != .step
        widthLabel.textColor = widthStepper.isEnabled ? .labelColor : .tertiaryLabelColor
        widthCaption.textColor = widthStepper.isEnabled ? .secondaryLabelColor : .tertiaryLabelColor
        let supportsLine = stylesEnabled && (styleKind?.supportsLineStyleControl ?? false)
        solidButton.isEnabled = supportsLine
        dashedButton.isEnabled = supportsLine
        shadowButton.isEnabled = !isOutputting
    }

    private func updateStyleControlRanges() {
        guard let styleKind else {
            widthCaption.stringValue = "参数"
            widthLabel.stringValue = ""
            return
        }
        let range = styleKind.lineWidthRange
        widthCaption.stringValue = styleKind.lineWidthControlTitle
        widthStepper.minValue = Double(range.lowerBound)
        widthStepper.maxValue = Double(range.upperBound)
        widthStepper.toolTip = "\(styleKind.lineWidthControlTitle) \(range.lowerBound)–\(range.upperBound)"
    }

    private func updateStyleControls() {
        isUpdatingStyleControls = true
        colorButton.color = style.color
        widthStepper.integerValue = style.lineWidth
        widthLabel.stringValue = "\(style.lineWidth)"
        let solid = style.lineStyle == .solid
        Self.setSelected(solidButton, selected: solid)
        Self.setSelected(dashedButton, selected: !solid)
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
        let button = NSButton()
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
        button.layer?.backgroundColor = selected
            ? NylaiTheme.accent.withAlphaComponent(0.15).cgColor
            : NSColor.clear.cgColor
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

@MainActor
final class ScreenshotOutputToolbarView: NSVisualEffectView {
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
        let rows = groups.reduce(0) { $0 + ($1.count + 1) / 2 }
        let height = 18
            + CGFloat(rows * 29)
            + CGFloat(max(0, rows - groups.count) * 4)
            + CGFloat(max(0, groups.count - 1) * 9)
        return CGSize(width: 80, height: height)
    }

    private let cropButton = NSButton()
    private let cursorButton = NSButton()
    private let undoButton = NSButton()
    private let redoButton = NSButton()
    private let deleteButton = NSButton()
    private let scrollButton = NSButton()
    private let reselectButton = NSButton()
    private let copyButton = NSButton()
    private let saveButton = NSButton()
    private let pinButton = NSButton()
    private let cancelButton = NSButton()
    private let zoomOutButton = NSButton()
    private let zoomInButton = NSButton()
    private let fitButton = NSButton()
    private var stack: NSStackView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        configure(cropButton, icon: .crop, action: #selector(cropClicked))
        configure(cursorButton, icon: .cursor, action: #selector(cursorClicked))
        configure(undoButton, icon: .undo, action: #selector(undoClicked))
        configure(redoButton, icon: .redo, action: #selector(redoClicked))
        configure(deleteButton, icon: .trash, action: #selector(deleteClicked))
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
        selectionGroup.append(contentsOf: [cursorButton, undoButton, redoButton, deleteButton])
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
        container.spacing = 8
        container.edgeInsets = NSEdgeInsets(top: 9, left: 9, bottom: 9, right: 9)
        for (index, group) in activeGroups.enumerated() {
            if index > 0 {
                let separator = SelectionToolbarView.separator(orientation: .horizontal)
                separator.widthAnchor.constraint(equalToConstant: 62).isActive = true
                container.addArrangedSubview(separator)
            }
            var offset = 0
            while offset < group.count {
                let end = min(offset + 2, group.count)
                let row = NSStackView(views: Array(group[offset..<end]))
                row.orientation = .horizontal
                row.alignment = .centerY
                row.spacing = 4
                container.addArrangedSubview(row)
                offset = end
            }
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
        button.widthAnchor.constraint(equalToConstant: 29).isActive = true
        button.heightAnchor.constraint(equalToConstant: 29).isActive = true
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
        undoButton.isEnabled = !isOutputting && canUndo
        redoButton.isEnabled = !isOutputting && canRedo
        deleteButton.isEnabled = !isOutputting && canDelete
    }

    @objc private func cropClicked() {
        selectedTool = .selection
        onToolChanged?(.selection)
    }

    @objc private func cursorClicked() {
        selectedTool = .objectSelection
        onToolChanged?(.objectSelection)
    }

    @objc private func undoClicked() { onUndo() }
    @objc private func redoClicked() { onRedo() }
    @objc private func deleteClicked() { onDelete() }
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
    private let toggle = NSButton(checkboxWithTitle: "启用阴影", target: nil, action: nil)
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
            settingRow(title: "柔化", slider: radiusSlider, value: radiusValue),
            settingRow(title: "浓度", slider: opacitySlider, value: opacityValue),
            settingRow(title: "偏移", slider: offsetSlider, value: offsetValue),
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
