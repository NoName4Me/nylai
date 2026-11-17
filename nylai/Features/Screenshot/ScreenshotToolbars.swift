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
final class ToolbarIconButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private(set) var hoverHintText: String?
    private var isHovered = false {
        didSet { updateSurface() }
    }

    override var isEnabled: Bool {
        didSet { updateSurface() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        contentTintColor = .labelColor
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
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        showHoverHint()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        ScreenshotHoverHintPresenter.shared.dismiss(owner: self)
    }

    override func mouseDown(with event: NSEvent) {
        ScreenshotHoverHintPresenter.shared.dismiss(owner: self)
        super.mouseDown(with: event)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            ScreenshotHoverHintPresenter.shared.dismiss(owner: self)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func setHoverHint(_ text: String?) {
        hoverHintText = text
    }

    func showHoverHint() {
        guard let window, let hoverHintText, !hoverHintText.isEmpty else { return }
        ScreenshotHoverHintPresenter.shared.show(
            hoverHintText,
            anchor: window.convertToScreen(convert(bounds, to: nil)),
            in: window,
            owner: self
        )
    }

    func refreshSurface() {
        updateSurface()
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
    static let toolbarButtonSize: CGFloat = 34
    static let toolbarIconPointSize: CGFloat = 20

    var onToolChanged: ((ScreenshotEditorTool) -> Void)?
    var onRedactionEffectChanged: ((ScreenshotRedactionEffect) -> Void)?
    var onMosaicModeChanged: ((ScreenshotMosaicMode) -> Void)?
    var onStyleChanged: ((ScreenshotAnnotationStyle) -> Void)?
    var onAppearanceChanged: ((ScreenshotOutputAppearance) -> Void)?

    var isOutputting = false { didSet { updateEnabledState() } }
    var styleControlsEnabled = false {
        didSet {
            styleRow.isHidden = !styleControlsEnabled
            styleSeparator.isHidden = !styleControlsEnabled
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
            updateEnabledState()
        }
    }
    var mosaicMode = ScreenshotMosaicMode.box {
        didSet { updateMosaicModeControl() }
    }
    var redactionEffect = ScreenshotRedactionEffect.mosaic {
        didSet { updateRedactionEffectControl() }
    }
    var outputAppearance = ScreenshotOutputAppearance.default {
        didSet { updateShadowButton() }
    }

    var preferredContentSize: CGSize {
        CGSize(
            width: 366,
            height: styleControlsEnabled
                ? (styleKind == .arrow ? 136 : 92)
                : 48
        )
    }

    private let tools: [ScreenshotEditorTool] = [
        .rectangle, .ellipse, .line, .arrow, .brush, .text, .step, .mosaic,
    ]
    private var toolButtons: [(ScreenshotEditorTool, NSButton)] = []
    private let colorButton = ScreenshotColorSwatchButton()
    private let widthLabel = NSTextField(labelWithString: "3")
    private let widthStepper = NSStepper()
    private let colorWidthLabel = NSTextField(
        labelWithString: L10n.shared.string("颜色 / 粗细")
    )
    private let redactionEffectControl = NSSegmentedControl(frame: .zero)
    private let mosaicModeControl = NSSegmentedControl(frame: .zero)
    private let cornerStyleControl = NSSegmentedControl(frame: .zero)
    private let stepStyleControl = NSSegmentedControl(frame: .zero)
    private var arrowOptionsHost: NSHostingView<AnyView>?
    private let textStyleControl = NSSegmentedControl(labels: ["A", "A"],
                                                       trackingMode: .selectOne, target: nil, action: nil)
    private let lineStyleLabel = NSTextField(
        labelWithString: L10n.shared.string("线型")
    )
    private let lineStyleControl = NSSegmentedControl(frame: .zero)
    private let arrowLineGroupSeparator = SelectionToolbarView.separator(
        orientation: .vertical
    )
    private let fillButton = NSButton(
        checkboxWithTitle: L10n.shared.string("填充"),
        target: nil,
        action: nil
    )
    private let shadowButton = ToolbarIconButton()
    private lazy var styleRow = NSStackView()
    private let styleSeparator = SelectionToolbarView.separator(orientation: .horizontal)
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
            let button = Self.iconButton(icon: icon, label: Self.label(for: tool))
            button.target = self
            button.action = #selector(toolChanged(_:))
            toolButtons.append((tool, button))
            toolRow.addArrangedSubview(button)
        }
        toolRow.addArrangedSubview(Self.separator(orientation: .vertical))
        Self.configure(iconButton: shadowButton, icon: .shadow, action: #selector(shadowClicked), target: self)
        toolRow.addArrangedSubview(shadowButton)

        configureStyleControls()
        styleSeparator.identifier = NSUserInterfaceItemIdentifier(
            "annotationStyleSeparator"
        )
        styleRow.orientation = .horizontal
        styleRow.alignment = .centerY
        styleRow.spacing = 5
        styleRow.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        styleRow.isHidden = true

        let arrowOptionsHost = NSHostingView(
            rootView: AnyView(makeArrowOptionsView().nylaiLocalized())
        )
        arrowOptionsHost.widthAnchor.constraint(equalToConstant: 326).isActive = true
        arrowOptionsHost.heightAnchor.constraint(equalToConstant: 44).isActive = true
        arrowOptionsHost.isHidden = true
        self.arrowOptionsHost = arrowOptionsHost
        let stack = NSStackView(views: [toolRow, styleSeparator, styleRow, arrowOptionsHost])
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
            styleSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
        ])
        styleSeparator.isHidden = true
        updateStyleControls()
        updateStyleControlRanges()
        updateRedactionEffectControl()
        updateMosaicModeControl()
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
        colorWidthLabel.font = .systemFont(ofSize: 10, weight: .medium)
        colorWidthLabel.textColor = .secondaryLabelColor
        colorWidthLabel.setContentCompressionResistancePriority(
            .required,
            for: .horizontal
        )

        widthStepper.increment = 1
        widthStepper.valueWraps = false
        widthStepper.controlSize = .small
        widthStepper.target = self
        widthStepper.action = #selector(styleControlChanged)
        widthStepper.setAccessibilityLabel(L10n.shared.string("标注参数"))
        configureSegmentedControl(redactionEffectControl)
        redactionEffectControl.segmentCount = ScreenshotRedactionEffect.allCases.count
        for (index, effect) in ScreenshotRedactionEffect.allCases.enumerated() {
            redactionEffectControl.setImage(
                effect == .mosaic
                    ? NylaiIcon.mosaic.image(pointSize: Self.toolbarIconPointSize)
                    : NylaiIcon.blur.image(pointSize: Self.toolbarIconPointSize),
                forSegment: index
            )
            redactionEffectControl.setLabel("", forSegment: index)
            redactionEffectControl.setToolTip(effect.title, forSegment: index)
        }
        redactionEffectControl.target = self
        redactionEffectControl.action = #selector(redactionEffectChanged)
        redactionEffectControl.setAccessibilityLabel(L10n.shared.string("打码方式"))
        redactionEffectControl.widthAnchor.constraint(equalToConstant: 80).isActive = true
        configureSegmentedControl(mosaicModeControl)
        mosaicModeControl.segmentCount = ScreenshotMosaicMode.allCases.count
        for (index, mode) in ScreenshotMosaicMode.allCases.enumerated() {
            mosaicModeControl.setImage(
                mode == .box
                    ? NylaiIcon.rectangle.image(pointSize: Self.toolbarIconPointSize)
                    : NSImage(
                        systemSymbolName: "circle.fill",
                        accessibilityDescription: mode.title
                    ),
                forSegment: index
            )
            mosaicModeControl.setLabel("", forSegment: index)
            mosaicModeControl.setToolTip(mode.title, forSegment: index)
        }
        mosaicModeControl.target = self
        mosaicModeControl.action = #selector(mosaicModeChanged)
        mosaicModeControl.setAccessibilityLabel(L10n.shared.string("打码形状"))
        mosaicModeControl.widthAnchor.constraint(equalToConstant: 80).isActive = true

        configureSegmentedControl(cornerStyleControl)
        cornerStyleControl.segmentCount = ScreenshotAnnotationCornerStyle.allCases.count
        for (index, style) in ScreenshotAnnotationCornerStyle.allCases.enumerated() {
            let icon = style == .rounded ? NylaiIcon.cornerRounded : NylaiIcon.cornerSharp
            cornerStyleControl.setImage(
                icon.image(pointSize: Self.toolbarIconPointSize),
                forSegment: index
            )
            cornerStyleControl.setLabel("", forSegment: index)
            cornerStyleControl.setToolTip(style.title, forSegment: index)
        }
        cornerStyleControl.target = self
        cornerStyleControl.action = #selector(cornerStyleChanged)
        cornerStyleControl.setAccessibilityLabel(L10n.shared.string("边角样式"))
        cornerStyleControl.widthAnchor.constraint(equalToConstant: 92).isActive = true

        configureSegmentedControl(stepStyleControl)
        stepStyleControl.segmentCount = 2
        stepStyleControl.setImage(
            NylaiIcon.step.image(pointSize: Self.toolbarIconPointSize),
            forSegment: 0
        )
        stepStyleControl.setImage(
            NylaiIcon.stepFilled.image(pointSize: Self.toolbarIconPointSize),
            forSegment: 1
        )
        stepStyleControl.setLabel("", forSegment: 0)
        stepStyleControl.setLabel("", forSegment: 1)
        stepStyleControl.setToolTip(
            L10n.shared.string("线圈数字"),
            forSegment: 0
        )
        stepStyleControl.setToolTip(
            L10n.shared.string("填充圆数字"),
            forSegment: 1
        )
        stepStyleControl.target = self
        stepStyleControl.action = #selector(annotationVariantChanged(_:))
        stepStyleControl.setAccessibilityLabel(L10n.shared.string("步骤样式"))
        stepStyleControl.widthAnchor.constraint(equalToConstant: 72).isActive = true

        configureSegmentedControl(lineStyleControl)
        lineStyleLabel.font = .systemFont(ofSize: 10, weight: .medium)
        lineStyleLabel.textColor = .secondaryLabelColor
        lineStyleLabel.setContentCompressionResistancePriority(
            .required,
            for: .horizontal
        )
        lineStyleControl.segmentCount = 2
        lineStyleControl.setImage(NylaiIcon.solidLine.image(
            pointSize: Self.toolbarIconPointSize
        ), forSegment: 0)
        lineStyleControl.setImage(NylaiIcon.dashedLine.image(
            pointSize: Self.toolbarIconPointSize
        ), forSegment: 1)
        lineStyleControl.setLabel("", forSegment: 0)
        lineStyleControl.setLabel("", forSegment: 1)
        lineStyleControl.setToolTip(L10n.shared.string("实线"), forSegment: 0)
        lineStyleControl.setToolTip(L10n.shared.string("虚线"), forSegment: 1)
        lineStyleControl.setAccessibilityLabel(L10n.shared.string("线型"))
        lineStyleControl.widthAnchor.constraint(equalToConstant: 64).isActive = true
        lineStyleControl.target = self
        lineStyleControl.action = #selector(lineStyleChanged)
        configureSegmentedControl(textStyleControl)
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
            redactionEffectControl, mosaicModeControl, cornerStyleControl,
            colorWidthLabel, colorButton, widthLabel, widthStepper,
            arrowLineGroupSeparator, lineStyleLabel, lineStyleControl, stepStyleControl,
            fillButton, textStyleControl,
        ])
    }

    private func updateToolSelection() {
        for (tool, button) in toolButtons {
            Self.setSelected(
                button,
                selected: styleKind.map(tool.owns) == true
                    || (styleKind == nil && tool == selectedTool)
            )
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
        let showsLineWidth = styleKind?.showsLineWidthControl == true
        colorWidthLabel.isHidden = styleKind != .arrow || !showsLineWidth
        widthStepper.isEnabled = stylesEnabled && showsLineWidth
        widthStepper.isHidden = !showsLineWidth
        widthLabel.isHidden = !showsLineWidth
        widthLabel.textColor = widthStepper.isEnabled ? .labelColor : .tertiaryLabelColor
        let supportsLine = (styleKind?.supportsLineStyleControl ?? false)
            && (styleKind != .arrow || style.arrowOptions?.widthStyle != .tapered)
        lineStyleControl.isHidden = !supportsLine
        lineStyleControl.isEnabled = stylesEnabled && supportsLine
        lineStyleLabel.isHidden = !supportsLine || styleKind != .arrow
        arrowLineGroupSeparator.isHidden = !supportsLine || styleKind != .arrow
        let showsStepStyle = styleKind == .step
        stepStyleControl.isHidden = !showsStepStyle
        stepStyleControl.isEnabled = stylesEnabled && showsStepStyle
        let showsFill = styleKind?.supportsFill == true && !showsStepStyle
        fillButton.isHidden = !showsFill
        fillButton.isEnabled = stylesEnabled && showsFill
        arrowOptionsHost?.isHidden = !styleControlsEnabled || styleKind != .arrow
        if styleKind == .arrow {
            arrowOptionsHost?.rootView = AnyView(makeArrowOptionsView().nylaiLocalized())
        }
        textStyleControl.isHidden = styleKind != .text
        textStyleControl.isEnabled = stylesEnabled
        let showsMosaicMode = styleKind?.isMosaicEffect == true
        redactionEffectControl.isHidden = !showsMosaicMode
        redactionEffectControl.isEnabled = stylesEnabled && showsMosaicMode
        mosaicModeControl.isHidden = !showsMosaicMode
        mosaicModeControl.isEnabled = stylesEnabled && showsMosaicMode
        let showsCornerStyle = styleKind?.supportsCornerStyleControl == true
        cornerStyleControl.isHidden = !showsCornerStyle
        cornerStyleControl.isEnabled = stylesEnabled && showsCornerStyle
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
        if let mode = styleKind.mosaicMode {
            mosaicMode = mode
        }
        if let effect = styleKind.redactionEffect {
            redactionEffect = effect
        }
    }

    private func updateRedactionEffectControl() {
        guard let index = ScreenshotRedactionEffect.allCases.firstIndex(of: redactionEffect) else {
            return
        }
        let wasUpdating = isUpdatingStyleControls
        isUpdatingStyleControls = true
        redactionEffectControl.selectedSegment = index
        isUpdatingStyleControls = wasUpdating
    }

    private func updateMosaicModeControl() {
        guard let index = ScreenshotMosaicMode.allCases.firstIndex(of: mosaicMode) else {
            return
        }
        let wasUpdating = isUpdatingStyleControls
        isUpdatingStyleControls = true
        mosaicModeControl.selectedSegment = index
        isUpdatingStyleControls = wasUpdating
    }

    private func updateStyleControls() {
        isUpdatingStyleControls = true
        fillButton.state = style.fillsShape == true ? .on : .off
        stepStyleControl.selectedSegment = style.fillsShape == false ? 0 : 1
        textStyleControl.selectedSegment = style.fillsTextBackground == true ? 1 : 0
        cornerStyleControl.selectedSegment = style.resolvedCornerStyle == .rounded ? 0 : 1
        redactionEffectControl.selectedSegment = ScreenshotRedactionEffect.allCases.firstIndex(
            of: redactionEffect
        ) ?? 0
        colorButton.color = style.color
        widthStepper.integerValue = style.lineWidth
        widthLabel.stringValue = "\(style.lineWidth)"
        let solid = style.lineStyle == .solid
        lineStyleControl.selectedSegment = solid ? 0 : 1
        if styleKind == .arrow {
            arrowOptionsHost?.rootView = AnyView(makeArrowOptionsView().nylaiLocalized())
        }
        isUpdatingStyleControls = false
    }

    private func updateShadowButton() {
        Self.setSelected(shadowButton, selected: outputAppearance.shadowEnabled)
    }

    func previewLineWidth(_ lineWidth: Int) {
        isUpdatingStyleControls = true
        widthStepper.integerValue = lineWidth
        widthLabel.stringValue = "\(lineWidth)"
        isUpdatingStyleControls = false
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

    @objc private func lineStyleChanged() {
        guard !isUpdatingStyleControls else { return }
        var updated = style
        updated.lineStyle = lineStyleControl.selectedSegment == 0 ? .solid : .dashed
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

    @objc private func mosaicModeChanged() {
        guard !isUpdatingStyleControls,
              ScreenshotMosaicMode.allCases.indices.contains(
                  mosaicModeControl.selectedSegment
              ) else {
            return
        }
        let mode = ScreenshotMosaicMode.allCases[mosaicModeControl.selectedSegment]
        mosaicMode = mode
        onMosaicModeChanged?(mode)
    }

    @objc private func redactionEffectChanged() {
        guard !isUpdatingStyleControls,
              ScreenshotRedactionEffect.allCases.indices.contains(
                  redactionEffectControl.selectedSegment
              ) else {
            return
        }
        let effect = ScreenshotRedactionEffect.allCases[
            redactionEffectControl.selectedSegment
        ]
        redactionEffect = effect
        onRedactionEffectChanged?(effect)
    }

    @objc private func cornerStyleChanged() {
        guard !isUpdatingStyleControls,
              ScreenshotAnnotationCornerStyle.allCases.indices.contains(
                  cornerStyleControl.selectedSegment
              ) else {
            return
        }
        var updated = style
        updated.cornerStyle = ScreenshotAnnotationCornerStyle.allCases[
            cornerStyleControl.selectedSegment
        ]
        let validated = styleKind.map { updated.validated(for: $0) } ?? updated.validated()
        style = validated
        onStyleChanged?(validated)
    }

    private func makeArrowOptionsView() -> ArrowOptionsView {
        let options = style.arrowOptions ?? .default
        return ArrowOptionsView(
            options: options,
            enabled: !isOutputting && styleControlsEnabled
        ) { [weak self] options in
            guard let self, self.styleKind == .arrow else { return }
            var updated = self.style
            updated.arrowOptions = options
            self.style = updated
            self.onStyleChanged?(updated)
        }
    }

    @objc private func annotationVariantChanged(_ sender: NSSegmentedControl) {
        var updated = style
        if sender === textStyleControl {
            updated.fillsTextBackground = sender.selectedSegment == 1 ? true : nil
        } else if sender === stepStyleControl {
            updated.fillsShape = sender.selectedSegment == 1
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

    private static func label(for tool: ScreenshotEditorTool) -> String {
        tool == .mosaic
            ? L10n.shared.string("打码")
            : icon(for: tool).accessibilityLabel
    }

    private static func configure(
        iconButton button: NSButton,
        icon: NylaiIcon,
        action: Selector,
        target: AnyObject
    ) {
        button.title = icon.accessibilityLabel
        button.image = icon.image(pointSize: toolbarIconPointSize)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.controlSize = .small
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        (button as? ToolbarIconButton)?.setHoverHint(icon.accessibilityLabel)
        button.setAccessibilityLabel(icon.accessibilityLabel)
        button.target = target
        button.action = action
        button.widthAnchor.constraint(equalToConstant: toolbarButtonSize).isActive = true
        button.heightAnchor.constraint(equalToConstant: toolbarButtonSize).isActive = true
    }

    static func iconButton(icon: NylaiIcon, label: String) -> NSButton {
        let button = ToolbarIconButton()
        button.title = label
        button.image = icon.image(pointSize: toolbarIconPointSize)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.controlSize = .small
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.setHoverHint(label)
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: toolbarButtonSize).isActive = true
        button.heightAnchor.constraint(equalToConstant: toolbarButtonSize).isActive = true
        return button
    }

    private func configureSegmentedControl(_ control: NSSegmentedControl) {
        control.controlSize = .regular
        control.segmentStyle = .rounded
        control.heightAnchor.constraint(equalToConstant: 28).isActive = true
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
    let enabled: Bool
    let onChange: (ScreenshotArrowOptions) -> Void

    var body: some View {
        HStack(spacing: 10) {
            group("轮廓") {
                widthChoices
            }
            Divider()
                .frame(height: 30)
            group("路径") {
                choices(
                    "路径",
                    ScreenshotArrowPathStyle.allCases,
                    \.pathStyle,
                    title: { $0.title }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .labelsHidden()
        .controlSize(.regular)
        .font(.system(size: 12))
        .disabled(!enabled)
        .tint(NylaiPalette.accent)
    }

    private func group<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
    }

    private var widthChoices: some View {
        Picker("粗细方式", selection: Binding(
            get: { options.widthStyle },
            set: { value in
                var updated = options
                updated.widthStyle = value
                onChange(updated)
            }
        )) {
            ForEach(ScreenshotArrowWidthStyle.allCases, id: \.self) { value in
                Image(nsImage: ScreenshotArrowWidthIcon.image(for: value))
                    .tag(value)
                    .accessibilityLabel(Text(value.title))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("粗细方式")
        .frame(maxWidth: .infinity)
    }

    private func choices<Value: Hashable>(_ label: String, _ values: [Value],
                                          _ keyPath: WritableKeyPath<ScreenshotArrowOptions, Value>,
                                          title: @escaping (Value) -> String) -> some View {
        Picker(label, selection: Binding(
            get: { options[keyPath: keyPath] },
            set: { value in
                var updated = options
                updated[keyPath: keyPath] = value
                onChange(updated)
            }
        )) {
            ForEach(values, id: \.self) { value in Text(title(value)).tag(value) }
        }
        .pickerStyle(.segmented)
        .help(label)
        .frame(maxWidth: .infinity)
    }
}

private enum ScreenshotArrowWidthIcon {
    static func image(for style: ScreenshotArrowWidthStyle) -> NSImage {
        switch style {
        case .uniform:
            return NSImage(
                systemSymbolName: "arrow.right",
                accessibilityDescription: style.title
            ) ?? NSImage()
        case .tapered:
            let image = NSImage(size: NSSize(width: 24, height: 14))
            image.lockFocus()
            NSColor.clear.setFill()
            NSRect(x: 0, y: 0, width: 24, height: 14).fill()
            var style = ScreenshotAnnotationStyle.default
            style.lineWidth = 3
            style.arrowOptions = ScreenshotArrowOptions(
                widthStyle: .tapered,
                pathStyle: .straight
            )
            let annotation = ScreenshotAnnotation(
                kind: .arrow,
                start: PixelPoint(x: 0, y: 0),
                end: PixelPoint(x: 20, y: 0),
                style: style
            )
            if let path = ScreenshotAnnotationPath.fillPath(
                for: annotation,
                in: CGRect(x: 2, y: 0, width: 20, height: 14),
                flipped: false
            ) {
                NSColor.black.setFill()
                NSBezierPath(cgPath: path).fill()
            }
            image.unlockFocus()
            image.isTemplate = true
            return image
        }
    }
}

@MainActor
final class ScreenshotOutputToolbarView: FloatingToolbarSurfaceView {
    var onRecognizeText: (RecognizedTextLayout) -> Void = { _ in }
    private let recognitionMenu = TextRecognitionMenu()
    private let recognizeButton = ToolbarIconButton()
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
        let height = 10
            + CGFloat(buttons) * SelectionToolbarView.toolbarButtonSize
            + CGFloat(buttons + separators - 1) * 2
            + CGFloat(separators)
        return CGSize(width: 46, height: height)
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
        recognizeButton.image = NylaiIcon.recognize.image(
            pointSize: SelectionToolbarView.toolbarIconPointSize
        )
        recognizeButton.imagePosition = .imageOnly
        recognizeButton.imageScaling = .scaleProportionallyDown
        recognizeButton.setHoverHint(L10n.shared.string("提取文字"))
        recognizeButton.setAccessibilityLabel(L10n.shared.string("提取文字"))
        recognizeButton.isBordered = false
        recognizeButton.target = self
        recognizeButton.action = #selector(recognizeClicked)
        recognizeButton.widthAnchor.constraint(
            equalToConstant: SelectionToolbarView.toolbarButtonSize
        ).isActive = true
        recognizeButton.heightAnchor.constraint(
            equalToConstant: SelectionToolbarView.toolbarButtonSize
        ).isActive = true
        recognitionMenu.onSelect = { [weak self] in self?.onRecognizeText($0) }
        recognizeButton.menu = recognitionMenu.makeMenu()
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
        groups.append([recognizeButton, copyButton, saveButton, pinButton, cancelButton])
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
        container.spacing = 2
        container.edgeInsets = NSEdgeInsets(top: 5, left: 7, bottom: 5, right: 7)
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
        button.image = icon.image(pointSize: SelectionToolbarView.toolbarIconPointSize)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.controlSize = .small
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        (button as? ToolbarIconButton)?.setHoverHint(icon.accessibilityLabel)
        button.setAccessibilityLabel(icon.accessibilityLabel)
        button.target = self
        button.action = action
        button.widthAnchor.constraint(
            equalToConstant: SelectionToolbarView.toolbarButtonSize
        ).isActive = true
        button.heightAnchor.constraint(
            equalToConstant: SelectionToolbarView.toolbarButtonSize
        ).isActive = true
    }

    private func updateToolSelection() {
        SelectionToolbarView.setSelected(cropButton, selected: selectedTool == .selection)
        SelectionToolbarView.setSelected(cursorButton, selected: selectedTool == .objectSelection)
    }

    private func updateEnabledState() {
        for button in [
            cropButton, cursorButton, scrollButton, reselectButton,
            recognizeButton, copyButton, saveButton, pinButton, cancelButton,
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
    @objc private func recognizeClicked() {
        onRecognizeText(NSApp.currentEvent?.modifierFlags.contains(.option) == true ? .paragraph : .lines)
    }
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
