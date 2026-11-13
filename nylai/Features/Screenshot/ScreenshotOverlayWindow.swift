import AppKit

@MainActor
private final class ScreenshotToolbarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
import CoreGraphics

@MainActor
final class ScreenshotOverlayWindow: NSWindow {
    var onCancel: () -> Void = {}

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if let overlay = contentView?.subviews.compactMap({ $0 as? ScreenshotOverlayView }).first {
            switch event.type {
            case .mouseMoved:
                overlay.updateHoverHint(at: overlay.convert(event.locationInWindow, from: nil))
            case .leftMouseDown, .rightMouseDown, .leftMouseDragged, .mouseExited:
                overlay.dismissHoverHint()
            default:
                break
            }
        }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }

}

enum ScreenshotEditorTool: Equatable, Sendable {
    case selection
    case objectSelection
    case rectangle
    case ellipse
    case line
    case arrow
    case brush
    case text
    case step
    case mosaic
}

enum ScreenshotMagnifierLayout {
    static let panelSize = CGSize(width: 176, height: 236)
    static let inset: CGFloat = 8
    static let imageSize: CGFloat = 160

    static func panel(for point: CGPoint, in bounds: CGRect) -> CGRect {
        var origin = CGPoint(x: point.x + 22, y: point.y + 22)
        if origin.x + panelSize.width > bounds.maxX - 12 {
            origin.x = point.x - 22 - panelSize.width
        }
        if origin.y + panelSize.height > bounds.maxY - 12 {
            origin.y = point.y - 22 - panelSize.height
        }
        origin.x = min(
            max(origin.x, bounds.minX + 12),
            bounds.maxX - panelSize.width - 12
        )
        origin.y = min(
            max(origin.y, bounds.minY + 12),
            bounds.maxY - panelSize.height - 12
        )
        return CGRect(origin: origin, size: panelSize)
    }

    static func imageRect(in panel: CGRect) -> CGRect {
        CGRect(
            x: panel.minX + inset,
            y: panel.minY + inset,
            width: imageSize,
            height: imageSize
        )
    }
}

@MainActor
private final class ScreenshotCrosshairGuideView: NSView {
    private let shadowLayer = CAShapeLayer()
    private let accentLayer = CAShapeLayer()
    private var point: CGPoint?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        for guideLayer in [shadowLayer, accentLayer] {
            guideLayer.fillColor = NSColor.clear.cgColor
            guideLayer.lineCap = .round
            guideLayer.isHidden = true
            guideLayer.actions = [
                "path": NSNull(),
                "strokeColor": NSNull(),
                "hidden": NSNull(),
            ]
            layer?.addSublayer(guideLayer)
        }
        shadowLayer.lineWidth = 1.5
        accentLayer.lineWidth = 0.75
        updateStrokeColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从归档创建截图十字线")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        shadowLayer.frame = bounds
        accentLayer.frame = bounds
        updatePath()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateStrokeColors()
    }

    func setPoint(_ point: CGPoint?) {
        self.point = point
        updatePath()
    }

    private func updatePath() {
        guard let point, bounds.contains(point) else {
            shadowLayer.isHidden = true
            accentLayer.isHidden = true
            return
        }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: bounds.minX, y: point.y))
        path.addLine(to: CGPoint(x: bounds.maxX, y: point.y))
        path.move(to: CGPoint(x: point.x, y: bounds.minY))
        path.addLine(to: CGPoint(x: point.x, y: bounds.maxY))
        shadowLayer.path = path
        accentLayer.path = path
        shadowLayer.isHidden = false
        accentLayer.isHidden = false
    }

    private func updateStrokeColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            shadowLayer.strokeColor = NSColor.black.withAlphaComponent(0.42).cgColor
            accentLayer.strokeColor = NylaiTheme.accent.withAlphaComponent(0.92).cgColor
        }
    }
}

@MainActor
final class ScreenshotOverlayView: NSView {
    enum DragState: Equatable {
        case none
        case creatingSelection(start: CGPoint)
        case movingSelection(origin: CGRect, start: CGPoint)
        case resizingSelection(handle: SelectionResizeHandle, startRect: CGRect, start: CGPoint)
        case adjustingCornerRadius(startRadius: Int, start: CGPoint)
        case creatingAnnotation(start: CGPoint)
        case movingAnnotation(id: UUID, viewOrigin: CGRect, start: CGPoint)
        case adjustingArrow(id: UUID, handle: Int)
        case resizingAnnotation(
            id: UUID,
            handle: SelectionResizeHandle,
            viewStartRect: CGRect,
            start: CGPoint,
            originalStyle: ScreenshotAnnotationStyle
        )
    }

    var onSelectionChanged: ((CGRect?) -> Void)?
    var onSelectionCommitted: ((CGRect?) -> Void)?
    var onInteractionBegan: (() -> Void)?
    var onAnnotationInteractionBegan: ((UUID?) -> Void)?
    var onAnnotationCreated: ((ScreenshotAnnotation) -> Void)?
    var onAnnotationChanged: ((UUID, PixelRect, ScreenshotAnnotationStyle?) -> Void)?
    var onArrowGeometryChanged: ((ScreenshotAnnotation) -> Void)?
    var onAnnotationSelected: ((UUID?) -> Void)?
    var onStyleChanged: ((ScreenshotAnnotationStyle) -> Void)?
    var onOutputAppearanceChanged: ((ScreenshotOutputAppearance) -> Void)?
    var onTextEditingEnded: ((UUID, String, Bool) -> Void)?
    var onInteractionEnded: (() -> Void)?
    var onInteractionCancelled: (() -> Void)?
    var onTargetHover: ((CGPoint?) -> Void)?
    var onTargetPick: ((CGPoint) -> Void)?
    var onReselect: (() -> Void)?
    var onScrollCapture: (() -> Void)?
    var onCopy: (() -> Void)?
    var onRecognizeText: ((RecognizedTextLayout) -> Void)?
    var onSave: (() -> Void)?
    var onPin: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onFitWidth: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onDelete: (() -> Void)?
    var onCancel: () -> Void = {}

    private(set) var selection: CGRect? {
        didSet { updateCrosshairGuide() }
    }
    private(set) var dragState = DragState.none
    private(set) var annotations: [ScreenshotAnnotation] = []
    private(set) var selectedAnnotationID: UUID?
    private(set) var activeTool = ScreenshotEditorTool.selection
    var highlightedTargetRect: CGRect? {
        didSet {
            if oldValue != highlightedTargetRect {
                needsDisplay = true
            }
        }
    }
    var highlightedTargetLabel: String? {
        didSet {
            if oldValue != highlightedTargetLabel {
                needsDisplay = true
            }
        }
    }
    var highlightedTargetIsWindow = false {
        didSet {
            if oldValue != highlightedTargetIsWindow {
                needsDisplay = true
            }
        }
    }
    var pixelScale: CGFloat = 1 {
        didSet { updateToolbar() }
    }
    var sourcePixelSize: PixelSize? {
        didSet { needsDisplay = true }
    }
    var sourceImage: CGImage? {
        didSet { needsDisplay = true }
    }
    var showsColorInspector = false {
        didSet {
            needsDisplay = true
            updateCrosshairGuide()
        }
    }
    var outputAppearance = ScreenshotOutputAppearance.default {
        didSet {
            toolbar.outputAppearance = outputAppearance
            needsDisplay = true
            updateToolbar()
        }
    }
    var canUndo = false {
        didSet { updateToolbar() }
    }
    var canRedo = false {
        didSet { updateToolbar() }
    }
    var canDelete = false {
        didSet { updateToolbar() }
    }
    var hasActiveTargetPreview: Bool {
        highlightedTargetRect != nil && selection == nil
    }
    private var showsReselectAction = false {
        didSet { outputToolbar.showsReselectButton = showsReselectAction }
    }
    var isWindowSource = false {
        didSet {
            showsReselectAction = isWindowSource
            updateToolbar()
        }
    }
    var isOutputting = false {
        didSet {
            toolbar.isOutputting = isOutputting
            outputToolbar.isOutputting = isOutputting
        }
    }
    var showsSelectionChrome = true {
        didSet { needsDisplay = true }
    }
    var showsSelectionTool = true {
        didSet { outputToolbar.showsSelectionTool = showsSelectionTool }
    }
    var showsScrollCaptureAction = true {
        didSet { outputToolbar.showsScrollCaptureButton = showsScrollCaptureAction }
    }
    var showsZoomControls = false {
        didSet { outputToolbar.showsZoomControls = showsZoomControls }
    }
    var toolbarAnchorRect: CGRect? {
        didSet { updateToolbar() }
    }
    var usesExternalToolbars = false
    private var externalToolbarPanels: [NSPanel] = []

    func closeExternalToolbars() {
        for panel in externalToolbarPanels {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        externalToolbarPanels = []
    }
    private var trackingArea: NSTrackingArea?
    private var selectionBeforeDrag: CGRect?
    private var appearanceBeforeDrag: ScreenshotOutputAppearance?
    private var mouseDownPoint: CGPoint?
    private var draftAnnotation: ScreenshotAnnotation?
    private var draftBrushPoints: [PixelPoint] = []
    private var textEditor: AnnotationTextEditorView?
    private var editingTextAnnotationID: UUID?
    private var drawingStyles: [ScreenshotAnnotationKind: ScreenshotAnnotationStyle] = [:]
    private var currentStyle = ScreenshotAnnotationStyle.default
    private var pixelDimensions: (width: Int, height: Int)?
    private var pointerLocation: CGPoint?
    private lazy var crosshairGuide = ScreenshotCrosshairGuideView(frame: bounds)
    private var minimumSelectionSize: CGFloat {
        1 / max(pixelScale, 1)
    }
    private var annotationViewport: ScreenshotAnnotationViewport? {
        guard let sourcePixelSize else { return nil }
        return ScreenshotAnnotationViewport(pixelSize: sourcePixelSize, viewSize: bounds.size)
    }
    private lazy var toolbar: SelectionToolbarView = {
        let toolbar = SelectionToolbarView(frame: .zero)
        toolbar.onToolChanged = { [weak self] tool in self?.setTool(tool) }
        toolbar.onStyleChanged = { [weak self] style in self?.styleEdited(style) }
        toolbar.onAppearanceChanged = { [weak self] appearance in
            guard let self else { return }
            outputAppearance = appearance
            onOutputAppearanceChanged?(appearance)
        }
        return toolbar
    }()
    private lazy var outputToolbar: ScreenshotOutputToolbarView = {
        let toolbar = ScreenshotOutputToolbarView(frame: .zero)
        toolbar.onCancel = { [weak self] in self?.onCancel() }
        toolbar.onUndo = { [weak self] in self?.onUndo?() }
        toolbar.onRedo = { [weak self] in self?.onRedo?() }
        toolbar.onDelete = { [weak self] in self?.onDelete?() }
        toolbar.onToolChanged = { [weak self] tool in self?.setTool(tool) }
        toolbar.onReselect = { [weak self] in self?.onReselect?() }
        toolbar.onScrollCapture = { [weak self] in self?.onScrollCapture?() }
        toolbar.onCopy = { [weak self] in self?.onCopy?() }
        toolbar.onRecognizeText = { [weak self] in self?.onRecognizeText?($0) }
        toolbar.onSave = { [weak self] in self?.onSave?() }
        toolbar.onPin = { [weak self] in self?.onPin?() }
        toolbar.onZoomIn = { [weak self] in self?.onZoomIn?() }
        toolbar.onZoomOut = { [weak self] in self?.onZoomOut?() }
        toolbar.onFitWidth = { [weak self] in self?.onFitWidth?() }
        return toolbar
    }()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        installCrosshairGuideIfNeeded()
    }

    func setSelection(_ rect: CGRect?, notify: Bool = true) {
        selection = rect.map { $0.intersection(bounds) }.flatMap { $0.isEmpty ? nil : $0 }
        if selection == nil {
            pixelDimensions = nil
        }
        needsDisplay = true
        updateToolbar()
        if notify {
            onSelectionChanged?(selection)
        }
    }

    func setPixelDimensions(_ rect: PixelRect?) {
        pixelDimensions = rect.map { ($0.width, $0.height) }
        updateToolbar()
    }

    func setAnnotations(_ annotations: [ScreenshotAnnotation], selectedID: UUID?) {
        self.annotations = annotations
        selectedAnnotationID = selectedID
        updateDisplayedStyle()
        updateToolbar()
        needsDisplay = true
    }

    func setTool(_ tool: ScreenshotEditorTool) {
        commitActiveTextEditing()
        let changed = activeTool != tool
        activeTool = tool
        toolbar.selectedTool = tool
        outputToolbar.selectedTool = tool
        updateDisplayedStyle()
        if selectedAnnotationID != nil, (changed && tool == .selection) || tool.annotationKind != nil {
            selectedAnnotationID = nil
            onAnnotationSelected?(nil)
            updateDisplayedStyle()
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
        updateToolbar()
    }

    func setDefaultStyle(_ style: ScreenshotAnnotationStyle, for kind: ScreenshotAnnotationKind) {
        drawingStyles[kind] = style.validated(for: kind)
        if selectedAnnotationID == nil, activeTool.annotationKind == kind {
            updateDisplayedStyle()
        }
    }

    func setDisplayedStyle(_ style: ScreenshotAnnotationStyle) {
        if let kind = activeTool.annotationKind {
            currentStyle = style.validated(for: kind)
            drawingStyles[kind] = currentStyle
        } else if let selectedAnnotationID,
                  let annotation = annotations.first(where: { $0.id == selectedAnnotationID }) {
            currentStyle = style.validated(for: annotation.kind)
        } else {
            currentStyle = style.validated()
        }
        toolbar.style = currentStyle
    }

    private func updateDisplayedStyle() {
        let kind: ScreenshotAnnotationKind?
        if let selectedAnnotationID,
           let annotation = annotations.first(where: { $0.id == selectedAnnotationID }) {
            kind = annotation.kind
            currentStyle = annotation.style.validated(for: annotation.kind)
        } else if let activeKind = activeTool.annotationKind {
            kind = activeKind
            currentStyle = drawingStyles[activeKind] ?? .defaultStyle(for: activeKind)
        } else {
            kind = nil
        }
        toolbar.styleKind = kind
        toolbar.style = currentStyle
    }

    private func styleEdited(_ style: ScreenshotAnnotationStyle) {
        let kind = selectedAnnotationID.flatMap { selectedID in
            annotations.first(where: { $0.id == selectedID })?.kind
        } ?? activeTool.annotationKind
        let validated = kind.map { style.validated(for: $0) } ?? style.validated()
        currentStyle = validated
        if let selectedAnnotationID,
           let index = annotations.firstIndex(where: { $0.id == selectedAnnotationID }) {
            annotations[index].style = validated
            if annotations[index].kind == .arrow,
               validated.arrowOptions?.pathStyle == .straight {
                annotations[index].arrowAnchors = nil
            }
        } else if let kind {
            drawingStyles[kind] = validated
        }
        toolbar.style = validated
        needsDisplay = true
        onStyleChanged?(validated)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if showsSelectionChrome, let activeRect = selection ?? highlightedTargetRect {
            let dimming = NSBezierPath(rect: bounds)
            dimming.append(NSBezierPath(rect: activeRect))
            dimming.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.24).setFill()
            dimming.fill()
        }

        if let highlightedTargetRect {
            NSColor.black.withAlphaComponent(0.42).setStroke()
            let shadow = NSBezierPath(
                roundedRect: highlightedTargetRect.insetBy(dx: 1.5, dy: 1.5),
                xRadius: 6,
                yRadius: 6
            )
            shadow.lineWidth = highlightedTargetIsWindow ? 7 : 5.5
            shadow.stroke()

            NylaiTheme.accent.setStroke()
            let highlight = NSBezierPath(
                roundedRect: highlightedTargetRect.insetBy(dx: 1, dy: 1),
                xRadius: 5,
                yRadius: 5
            )
            highlight.lineWidth = highlightedTargetIsWindow ? 4 : 3
            highlight.stroke()

            if let highlightedTargetLabel {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                    .foregroundColor: NSColor.white,
                ]
                let textSize = highlightedTargetLabel.size(withAttributes: attributes)
                let pill = CGRect(
                    x: highlightedTargetRect.minX + 8,
                    y: highlightedTargetRect.minY + 8,
                    width: textSize.width + 14,
                    height: textSize.height + 8
                )
                NSColor.black.withAlphaComponent(0.68).setFill()
                NSBezierPath(
                    roundedRect: pill,
                    xRadius: pill.height / 2,
                    yRadius: pill.height / 2
                ).fill()
                highlightedTargetLabel.draw(
                    at: CGPoint(x: pill.minX + 7, y: pill.minY + 4),
                    withAttributes: attributes
                )
            }
        }

        if showsColorInspector,
           selection == nil,
           let pointer = currentPointerLocation {
            drawColorInspector(at: pointer)
        }

        guard let selection else { return }
        drawAnnotations(clippedTo: selection)
        drawAppearancePreview(in: selection)
        drawSelectionSizeBadge(in: selection)
        guard showsSelectionChrome else { return }

        let edge = selection.insetBy(dx: 1.25, dy: 1.25)
        let border = NSBezierPath()
        func marks(from start: CGPoint, to end: CGPoint) {
            let length = hypot(end.x - start.x, end.y - start.y)
            guard length > 0 else { return }
            let span = min(15, length * 0.18) / length
            func point(_ fraction: CGFloat) -> CGPoint {
                CGPoint(x: start.x + (end.x - start.x) * fraction,
                        y: start.y + (end.y - start.y) * fraction)
            }
            for (first, last) in [(CGFloat.zero, span), (0.5 - span / 2, 0.5 + span / 2), (1 - span, 1)] {
                border.move(to: point(first))
                border.line(to: point(last))
            }
        }
        let corners = [
            CGPoint(x: edge.minX, y: edge.minY), CGPoint(x: edge.maxX, y: edge.minY),
            CGPoint(x: edge.maxX, y: edge.maxY), CGPoint(x: edge.minX, y: edge.maxY),
        ]
        for index in corners.indices {
            marks(from: corners[index], to: corners[(index + 1) % corners.count])
        }
        border.lineCapStyle = .round
        NSColor.black.withAlphaComponent(0.42).setStroke()
        border.lineWidth = 4
        border.stroke()
        NylaiTheme.accent.setStroke()
        border.lineWidth = 2.5
        border.stroke()
        drawCornerRadiusControl(in: selection)

    }

    private func drawSelectionSizeBadge(in selection: CGRect) {
        guard let pixelDimensions else { return }
        let text = "\(pixelDimensions.width) × \(pixelDimensions.height)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        let badgeSize = CGSize(width: textSize.width + 16, height: 24)
        var origin = CGPoint(x: selection.minX + 8, y: selection.minY + 8)
        if badgeSize.width > selection.width - 16
            || badgeSize.height > selection.height - 16 {
            origin = CGPoint(
                x: min(max(selection.minX, bounds.minX + 8), bounds.maxX - badgeSize.width - 8),
                y: max(bounds.minY + 8, selection.minY - badgeSize.height - 8)
            )
        }
        let badge = CGRect(origin: origin, size: badgeSize)
        NylaiTheme.accent.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6).fill()
        text.draw(
            at: CGPoint(
                x: badge.midX - textSize.width / 2,
                y: badge.midY - textSize.height / 2
            ),
            withAttributes: attributes
        )
    }

    private func drawColorInspector(at point: CGPoint) {
        guard let sourceImage,
              let viewport = annotationViewport else {
            return
        }
        let panel = ScreenshotMagnifierLayout.panel(for: point, in: bounds)
        let appearance = NSApp.effectiveAppearance

        NSGraphicsContext.saveGraphicsState()
        let panelPath = NSBezierPath(roundedRect: panel, xRadius: 12, yRadius: 12)
        NylaiTheme.panelBackground(for: appearance).setFill()
        panelPath.fill()
        NylaiTheme.border(for: appearance).setStroke()
        panelPath.lineWidth = 1
        panelPath.stroke()

        let imageRect = ScreenshotMagnifierLayout.imageRect(in: panel)
        NylaiTheme.imageBackground(for: appearance).setFill()
        NSBezierPath(roundedRect: imageRect, xRadius: 7, yRadius: 7).fill()

        let pixelPoint = viewport.pixelPoint(from: point)
        let sampleRadius = 8
        let sampleSide = min(
            sampleRadius * 2 + 1,
            sourceImage.width,
            sourceImage.height
        )
        let sampleWidth = sampleSide
        let sampleHeight = sampleSide
        let sampleRect = CGRect(
            x: min(max(pixelPoint.x - sampleRadius, 0), sourceImage.width - sampleWidth),
            y: min(max(pixelPoint.y - sampleRadius, 0), sourceImage.height - sampleHeight),
            width: sampleWidth,
            height: sampleHeight
        )
        if let magnified = sourceImage.cropping(to: sampleRect) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: imageRect, xRadius: 7, yRadius: 7).addClip()
            NSGraphicsContext.current?.imageInterpolation = .none
            NSImage(cgImage: magnified, size: imageRect.size).draw(
                in: imageRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.none]
            )
            NylaiTheme.accent.withAlphaComponent(0.8).setStroke()
            let crosshair = NSBezierPath()
            crosshair.move(to: CGPoint(x: imageRect.midX, y: imageRect.minY))
            crosshair.line(to: CGPoint(x: imageRect.midX, y: imageRect.maxY))
            crosshair.move(to: CGPoint(x: imageRect.minX, y: imageRect.midY))
            crosshair.line(to: CGPoint(x: imageRect.maxX, y: imageRect.midY))
            crosshair.lineWidth = 1
            crosshair.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }

        let color = ScreenshotColorSampler.color(
            in: sourceImage,
            at: pixelPoint
        )
        let sampleX = min(max(pixelPoint.x, 0), max(0, sourceImage.width - 1))
        let sampleY = min(max(pixelPoint.y, 0), max(0, sourceImage.height - 1))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NylaiTheme.primaryText(for: appearance),
        ]
        let secondaryAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NylaiTheme.secondaryText(for: appearance),
        ]
        ("X \(sampleX)   Y \(sampleY)" as NSString).draw(
            in: CGRect(
                x: panel.minX + ScreenshotMagnifierLayout.inset,
                y: imageRect.maxY + 6,
                width: panel.width - ScreenshotMagnifierLayout.inset * 2,
                height: 15
            ),
            withAttributes: attributes
        )
        if let color {
            let swatch = CGRect(
                x: panel.minX + ScreenshotMagnifierLayout.inset,
                y: imageRect.maxY + 28,
                width: 14,
                height: 14
            )
            NSColor(
                srgbRed: CGFloat(color.red) / 255,
                green: CGFloat(color.green) / 255,
                blue: CGFloat(color.blue) / 255,
                alpha: 1
            ).setFill()
            NSBezierPath(roundedRect: swatch, xRadius: 3, yRadius: 3).fill()
            NylaiTheme.border(for: appearance).setStroke()
            NSBezierPath(roundedRect: swatch, xRadius: 3, yRadius: 3).stroke()
            (color.hexText as NSString).draw(
                in: CGRect(
                    x: swatch.maxX + 7,
                    y: swatch.minY - 1,
                    width: panel.maxX - swatch.maxX - 15,
                    height: 16
                ),
                withAttributes: attributes
            )
            (color.rgbText as NSString).draw(
                in: CGRect(
                    x: panel.minX + ScreenshotMagnifierLayout.inset,
                    y: swatch.maxY + 7,
                    width: panel.width - ScreenshotMagnifierLayout.inset * 2,
                    height: 16
                ),
                withAttributes: secondaryAttributes
            )
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawCornerRadiusControl(in selection: CGRect) {
        guard activeTool == .selection, selectedAnnotationID == nil else { return }
        let center = SelectionCornerRadiusGeometry.handleCenter(
            in: selection,
            radius: outputAppearance.cornerRadius
        )
        let outer = CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12)
        NSColor.black.withAlphaComponent(0.32).setFill()
        NSBezierPath(ovalIn: outer.insetBy(dx: -1.5, dy: -1.5)).fill()
        NylaiPalette.terracotta.setFill()
        NSBezierPath(ovalIn: outer).fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let outline = NSBezierPath(ovalIn: outer.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1.5
        outline.stroke()
    }

    private func drawAppearancePreview(in selection: CGRect) {
        let appearance = outputAppearance.validated()
        guard appearance.isEnabled else { return }
        let radius = min(
            CGFloat(appearance.cornerRadius),
            min(selection.width, selection.height) / 2
        )
        if appearance.roundedCornersEnabled {
            let outside = NSBezierPath(rect: selection)
            outside.append(NSBezierPath(
                roundedRect: selection,
                xRadius: radius,
                yRadius: radius
            ))
            outside.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.28).setFill()
            outside.fill()
        }
        if appearance.shadowEnabled {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(
                CGFloat(appearance.shadowOpacity) / 100
            )
            shadow.shadowBlurRadius = CGFloat(appearance.shadowRadius)
            shadow.shadowOffset = CGSize(
                width: 0,
                height: -CGFloat(appearance.shadowOffset)
            )
            shadow.set()
            NSColor.black.withAlphaComponent(0.35).setStroke()
            let outline = NSBezierPath(
                roundedRect: selection.insetBy(dx: 2, dy: 2),
                xRadius: radius,
                yRadius: radius
            )
            outline.lineWidth = 1
            outline.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawAnnotations(clippedTo selection: CGRect) {
        guard let viewport = annotationViewport else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: selection).addClip()

        for annotation in annotations {
            let rect = viewport.viewRect(for: annotation.rect)
            guard rect.intersects(selection) else { continue }
            if annotation.id != editingTextAnnotationID {
                drawAnnotationBorder(annotation, in: rect, viewport: viewport)
            }
        }
        if let draftAnnotation {
            drawAnnotationBorder(
                draftAnnotation,
                in: viewport.viewRect(for: draftAnnotation.rect),
                viewport: viewport
            )
        }

        if let selectedAnnotationID,
           let annotation = annotations.first(where: { $0.id == selectedAnnotationID }) {
            let rect = viewport.viewRect(for: annotation.rect)
            guard rect.intersects(selection) else {
                NSGraphicsContext.restoreGraphicsState()
                return
            }
            if annotation.id != editingTextAnnotationID {
                drawAnnotationSelection(annotation, in: rect)
            }
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawAnnotationBorder(
        _ annotation: ScreenshotAnnotation,
        in rect: CGRect,
        viewport: ScreenshotAnnotationViewport
    ) {
        if annotation.kind == .mosaic {
            if let sourceImage,
               let processed = ScreenshotPixelProcessor.processedImage(
                   source: sourceImage,
                   rect: annotation.rect,
                   kind: annotation.kind,
                   intensity: annotation.style.lineWidth
               ) {
                NSGraphicsContext.current?.imageInterpolation = .none
                NSImage(cgImage: processed, size: rect.size).draw(
                    in: rect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: nil
                )
            }
            NSColor.white.withAlphaComponent(0.8).setStroke()
            let outline = NSBezierPath(rect: rect.insetBy(dx: 0.75, dy: 0.75))
            outline.lineWidth = 1.5
            outline.setLineDash([5, 3], count: 2, phase: 0)
            outline.stroke()
            return
        }
        if annotation.kind == .text {
            ScreenshotTextLayout.draw(annotation, in: rect, scale: viewport.scaleY)
            return
        }
        if annotation.kind == .step {
            drawStepAnnotation(annotation, in: rect)
            return
        }
        let scale = min(viewport.scaleX, viewport.scaleY)
        let path = ScreenshotAnnotationPath.cgPath(for: annotation, in: rect, strokeScale: scale)
        NSColor.black.withAlphaComponent(0.32).setStroke()
        let shadow = NSBezierPath(cgPath: path)
        shadow.lineWidth = CGFloat(annotation.style.lineWidth) * scale + 2
        shadow.stroke()

        annotation.style.color.nsColor.setStroke()
        let border = NSBezierPath(cgPath: path)
        if let fill = ScreenshotAnnotationPath.fillPath(for: annotation, in: rect, strokeScale: scale) {
            annotation.style.color.nsColor.setFill()
            NSBezierPath(cgPath: fill).fill()
        }
        guard !annotation.isTaperedArrow else { return }
        border.lineWidth = CGFloat(annotation.style.lineWidth) * scale
        border.lineCapStyle = .round
        border.lineJoinStyle = .round
        if annotation.style.lineStyle == .dashed {
            let width = border.lineWidth
            border.setLineDash([width * 3, width * 2], count: 2, phase: 0)
        }
        border.stroke()
    }

    private func drawStepAnnotation(_ annotation: ScreenshotAnnotation, in rect: CGRect) {
        guard let stepNumber = annotation.stepNumber else { return }
        annotation.style.color.nsColor.setFill()
        NSBezierPath(ovalIn: rect).fill()
        let fontSize = rect.height * 0.56
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let text = "\(stepNumber)" as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(
                x: rect.midX - size.width / 2,
                y: rect.midY - size.height / 2
            ),
            withAttributes: attributes
        )
    }

    private func drawAnnotationSelection(_ annotation: ScreenshotAnnotation, in rect: CGRect) {
        if annotation.kind == .arrow {
            let handles = ScreenshotAnnotationPath.arrowHandles(for: annotation, in: rect)
            for (index, point) in handles.enumerated() {
                let endpoint = index == 0 || index == handles.count - 1
                let size: CGFloat = endpoint ? 8 : 9
                let frame = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
                let marker = endpoint ? NSBezierPath(roundedRect: frame, xRadius: 1, yRadius: 1)
                    : NSBezierPath(ovalIn: frame)
                NSColor.white.setFill()
                marker.fill()
                NylaiTheme.accent.setStroke()
                marker.lineWidth = 1.5
                marker.stroke()
            }
            return
        }
        let points = SelectionGeometry.handlePoints(in: rect)
        let handles = annotation.kind == .text ? [points.left, points.right] : annotation.kind == .step
            ? [points.topLeft, points.topRight, points.bottomLeft, points.bottomRight]
            : [
                points.topLeft, points.top, points.topRight,
                points.left, points.right,
                points.bottomLeft, points.bottom, points.bottomRight,
            ]
        for point in handles {
            let handleRect = CGRect(
                x: point.x - 4,
                y: point.y - 4,
                width: 8,
                height: 8
            )
            NSColor.white.setFill()
            NSBezierPath(roundedRect: handleRect, xRadius: 1.5, yRadius: 1.5).fill()
            NylaiTheme.accent.setStroke()
            let outline = NSBezierPath(roundedRect: handleRect, xRadius: 1.5, yRadius: 1.5)
            outline.lineWidth = 1
            outline.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        setHoverHint(nil, anchor: .zero)
        guard !isOutputting else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let textEditor {
            if textEditor.frame.contains(point) {
                return
            }
            commitActiveTextEditing()
            return
        }
        window?.makeFirstResponder(self)
        if toolbar.superview != nil, toolbar.frame.contains(point) {
            return
        }
        if outputToolbar.superview != nil, outputToolbar.frame.contains(point) {
            return
        }
        switch activeTool {
        case .selection:
            if showsSelectionChrome {
                beginSelectionMouseDown(at: point)
            } else {
                beginObjectMouseDown(at: point, allowsCreation: false, clickCount: event.clickCount)
            }
        case .objectSelection:
            beginObjectMouseDown(at: point, allowsCreation: false, clickCount: event.clickCount)
        case .rectangle, .ellipse, .line, .arrow, .brush, .text, .step, .mosaic:
            beginObjectMouseDown(at: point, allowsCreation: true, clickCount: event.clickCount)
        }
    }

    private func beginSelectionMouseDown(at point: CGPoint) {
        if let selection {
            if activeTool == .selection,
               selectedAnnotationID == nil,
               SelectionCornerRadiusGeometry.hitTest(
                   point,
                   selection: selection,
                   radius: outputAppearance.cornerRadius
               ) {
                beginSelectionDrag(
                    .adjustingCornerRadius(
                        startRadius: outputAppearance.cornerRadius,
                        start: point
                    ),
                    at: point
                )
                return
            }
            if let handle = SelectionGeometry.handle(at: point, in: selection) {
                beginSelectionDrag(
                    .resizingSelection(handle: handle, startRect: selection, start: point),
                    at: point
                )
                return
            }
            if selection.contains(point) {
                beginSelectionDrag(
                    .movingSelection(origin: selection, start: point),
                    at: point
                )
                return
            }
        }
        beginSelectionDrag(.creatingSelection(start: point), at: point)
        self.selection = nil
        highlightedTargetRect = nil
        highlightedTargetLabel = nil
        needsDisplay = true
    }

    private func beginSelectionDrag(_ state: DragState, at point: CGPoint) {
        if selection == nil {
            onTargetHover?(point)
        }
        selectionBeforeDrag = selection
        if case .adjustingCornerRadius = state {
            appearanceBeforeDrag = outputAppearance
        }
        mouseDownPoint = point
        onInteractionBegan?()
        dragState = state
    }

    private func beginObjectMouseDown(
        at point: CGPoint,
        allowsCreation: Bool,
        clickCount: Int
    ) {
        guard let selection else {
            onAnnotationSelected?(nil)
            return
        }
        if selection.contains(point),
           let selectedAnnotationID,
           let annotation = annotations.first(where: { $0.id == selectedAnnotationID }),
           let viewport = annotationViewport {
            let rect = viewport.viewRect(for: annotation.rect)
            if annotation.kind == .arrow, let handle = arrowHandle(at: point, annotation: annotation, rect: rect) {
                beginAnnotationDrag(.adjustingArrow(id: annotation.id, handle: handle), at: point)
                return
            }
            if annotation.kind == .text, clickCount >= 2, rect.contains(point) {
                beginTextEditing(annotation.id)
                return
            }
            if annotation.kind != .arrow, let handle = AnnotationSelectionGeometry.handle(
                at: point,
                in: rect,
                hitSize: 18,
                proportional: annotation.kind == .step
            ), annotation.kind != .text || handle == .left || handle == .right {
                beginAnnotationDrag(
                    .resizingAnnotation(
                        id: annotation.id,
                        handle: handle,
                        viewStartRect: rect,
                        start: point,
                        originalStyle: annotation.style
                    ),
                    at: point
                )
                return
            }
        }

        if let viewport = annotationViewport,
           let id = ScreenshotAnnotationViewport.hitTest(
               point,
               annotations: annotations,
               viewport: viewport,
               visibleIn: selection
           ) {
            selectedAnnotationID = id
            needsDisplay = true
            onAnnotationSelected?(id)
            guard let annotation = annotations.first(where: { $0.id == id }) else { return }
            if clickCount >= 2, annotation.kind == .text {
                beginTextEditing(id)
                return
            }
            beginAnnotationDrag(
                .movingAnnotation(
                    id: id,
                    viewOrigin: viewport.viewRect(for: annotation.rect),
                    start: point
                ),
                at: point
            )
            return
        }

        onAnnotationSelected?(nil)
        guard allowsCreation, selection.contains(point) else { return }
        mouseDownPoint = point
        draftBrushPoints = []
        onAnnotationInteractionBegan?(nil)
        dragState = .creatingAnnotation(start: point)
    }

    private func beginAnnotationDrag(_ state: DragState, at point: CGPoint) {
        let id: UUID
        switch state {
        case .movingAnnotation(let annotationID, _, _),
             .resizingAnnotation(let annotationID, _, _, _, _),
             .adjustingArrow(let annotationID, _):
            id = annotationID
        default:
            return
        }
        mouseDownPoint = point
        onAnnotationInteractionBegan?(id)
        dragState = state
    }

    private func arrowHandle(at point: CGPoint, annotation: ScreenshotAnnotation, rect: CGRect) -> Int? {
        let handles = ScreenshotAnnotationPath.arrowHandles(for: annotation, in: rect)
        return handles.indices.filter { hypot(handles[$0].x - point.x, handles[$0].y - point.y) <= 9 }
            .min { hypot(handles[$0].x - point.x, handles[$0].y - point.y)
                < hypot(handles[$1].x - point.x, handles[$1].y - point.y) }
    }

    private func adjustArrow(_ id: UUID, handle: Int, at point: CGPoint) {
        guard let viewport = annotationViewport,
              let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        var annotation = annotations[index]
        let handles = ScreenshotAnnotationPath.arrowHandles(
            for: annotation,
            in: viewport.viewRect(for: annotation.rect)
        )
        if handle == 0 || handle == handles.count - 1 {
            var pixel = viewport.pixelPoint(from: point)
            pixel.x = min(pixel.x, viewport.pixelSize.width - 1)
            pixel.y = min(pixel.y, viewport.pixelSize.height - 1)
            if handle == 0 {
                annotation.start = pixel
            } else {
                annotation.end = pixel
            }
        } else {
            guard let start = handles.first, let end = handles.last,
                  hypot(end.x - start.x, end.y - start.y) > 2 else { return }
            var anchors = ScreenshotArrowAnchors.resolved(for: annotation)
            var relative = ScreenshotArrowAnchors.relative(point, start: start, end: end)
            relative.y = min(1.5, max(-1.5, relative.y))
            if handle == 1 {
                relative.x = min(anchors.second.x - 0.04, max(0.04, relative.x))
                anchors.first = relative
            } else {
                relative.x = max(anchors.first.x + 0.04, min(0.96, relative.x))
                anchors.second = relative
            }
            annotation.arrowAnchors = anchors
        }
        guard annotation != annotations[index] else { return }
        annotations[index] = annotation
        onArrowGeometryChanged?(annotation)
        needsDisplay = true
    }

    private func updateAnnotation(
        _ id: UUID,
        viewRect: CGRect,
        viewport: ScreenshotAnnotationViewport,
        style: ScreenshotAnnotationStyle? = nil
    ) {
        guard let pixelRect = viewport.pixelRect(from: viewRect),
              let index = annotations.firstIndex(where: { $0.id == id }) else {
            return
        }
        if let style {
            annotations[index].style = style.validated(for: annotations[index].kind)
        }
        annotations[index].rect = pixelRect
        needsDisplay = true
        onAnnotationChanged?(id, pixelRect, style)
    }

    private func annotationEndpoint(
        from start: PixelPoint, to end: PixelPoint, kind: ScreenshotAnnotationKind,
        modifiers: NSEvent.ModifierFlags
    ) -> PixelPoint {
        guard kind.supportsFill, modifiers.contains(.control) else { return end }
        let horizontal = end.x - start.x
        let vertical = end.y - start.y
        let side = min(abs(horizontal), abs(vertical))
        return PixelPoint(x: start.x + (horizontal < 0 ? -side : side),
                          y: start.y + (vertical < 0 ? -side : side))
    }

    override func mouseDragged(with event: NSEvent) {
        setHoverHint(nil, anchor: .zero)
        let point = convert(event.locationInWindow, from: nil)
        switch dragState {
        case .none:
            break
        case .creatingSelection(let start):
            let rect = SelectionGeometry.normalizedSelection(from: start, to: point)
            if rect.width > 0 || rect.height > 0 {
                clearTargetPreview()
            }
            setSelection(rect.intersection(bounds))
        case .movingSelection(let origin, let start):
            let rect = SelectionGeometry.moved(
                origin,
                by: CGPoint(x: point.x - start.x, y: point.y - start.y),
                constrainedTo: bounds
            )
            setSelection(rect)
        case .resizingSelection(let handle, let startRect, let start):
            let rect = SelectionGeometry.resized(
                startRect,
                handle: handle,
                by: CGPoint(x: point.x - start.x, y: point.y - start.y),
                constrainedTo: bounds,
                minimumSize: CGSize(
                    width: minimumSelectionSize,
                    height: minimumSelectionSize
                )
            )
            setSelection(rect)
        case .adjustingCornerRadius(let startRadius, let start):
            let radius = SelectionCornerRadiusGeometry.radius(
                startRadius: startRadius,
                dragDelta: CGPoint(x: point.x - start.x, y: point.y - start.y)
            )
            var appearance = outputAppearance
            appearance.cornerRadius = radius
            appearance.roundedCornersEnabled = radius > 0
            outputAppearance = appearance.validated()
            onOutputAppearanceChanged?(outputAppearance)
        case .creatingAnnotation(let start):
            drawingCursor().set()
            guard let viewport = annotationViewport,
                  let kind = activeTool.annotationKind else { break }
            let startPixel = viewport.pixelPoint(from: start)
            let endPixel = annotationEndpoint(
                from: startPixel, to: viewport.pixelPoint(from: point),
                kind: kind, modifiers: event.modifierFlags
            )
            if kind == .brush {
                if draftBrushPoints.isEmpty {
                    draftBrushPoints = [startPixel]
                }
                if draftBrushPoints.last != endPixel {
                    draftBrushPoints.append(endPixel)
                }
                draftAnnotation = ScreenshotAnnotation(
                    brushPoints: draftBrushPoints,
                    style: currentStyle
                )
            } else {
                guard startPixel != endPixel else { break }
                draftAnnotation = ScreenshotAnnotation(
                    kind: kind,
                    start: startPixel,
                    end: endPixel,
                    style: currentStyle
                )
            }
            needsDisplay = true
        case .movingAnnotation(let id, let viewOrigin, let start):
            guard let viewport = annotationViewport else { break }
            let rect = SelectionGeometry.moved(
                viewOrigin,
                by: CGPoint(x: point.x - start.x, y: point.y - start.y),
                constrainedTo: bounds
            )
            updateAnnotation(id, viewRect: rect, viewport: viewport)
        case .adjustingArrow(let id, let handle):
            adjustArrow(id, handle: handle, at: point)
        case .resizingAnnotation(
            let id,
            let handle,
            let viewStartRect,
            let start,
            let originalStyle
        ):
            guard let viewport = annotationViewport,
                  let annotation = annotations.first(where: { $0.id == id }) else { break }
            var rect = AnnotationSelectionGeometry.resized(
                viewStartRect,
                handle: handle,
                by: CGPoint(x: point.x - start.x, y: point.y - start.y),
                constrainedTo: bounds,
                minimumSize: CGSize(
                    width: annotation.kind == .text
                        ? CGFloat(originalStyle.lineWidth + 8) * viewport.scaleX : viewport.scaleX,
                    height: viewport.scaleY
                ),
                proportional: annotation.kind == .step
            )
            if annotation.kind == .text {
                rect.size.height = ScreenshotTextLayout.size(
                    annotation.text, style: originalStyle, width: rect.width, scale: viewport.scaleY
                ).height
            }
            updateAnnotation(id, viewRect: rect, viewport: viewport)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let downPoint = mouseDownPoint
        mouseDownPoint = nil
        appearanceBeforeDrag = nil
        let completedDrag = dragState
        dragState = .none
        draftAnnotation = nil
        needsDisplay = true
        defer { window?.invalidateCursorRects(for: self) }

        switch completedDrag {
        case .none:
            return
        case .movingSelection, .resizingSelection:
            onSelectionCommitted?(selection)
            onInteractionEnded?()
        case .adjustingCornerRadius:
            onInteractionEnded?()
        case .creatingSelection:
            if let downPoint, hypot(point.x - downPoint.x, point.y - downPoint.y) < 3 {
                selection = nil
                needsDisplay = true
                onSelectionCommitted?(nil)
                onInteractionEnded?()
                onTargetPick?(point)
                return
            }
            guard let selection,
                  selection.width >= minimumSelectionSize,
                  selection.height >= minimumSelectionSize else {
                self.selection = nil
                needsDisplay = true
                onSelectionCommitted?(nil)
                onInteractionEnded?()
                return
            }
            onSelectionCommitted?(selection)
            onInteractionEnded?()
        case .adjustingArrow(let id, let handle):
            adjustArrow(id, handle: handle, at: point)
            onInteractionEnded?()
        case .movingAnnotation, .resizingAnnotation:
            onInteractionEnded?()
        case .creatingAnnotation:
            guard let downPoint,
                  let viewport = annotationViewport,
                  let kind = activeTool.annotationKind else {
                onInteractionEnded?()
                return
            }
            let start = viewport.pixelPoint(from: downPoint)
            let end = annotationEndpoint(
                from: start, to: viewport.pixelPoint(from: point),
                kind: kind, modifiers: event.modifierFlags
            )
            if kind == .brush {
                if draftBrushPoints.isEmpty {
                    draftBrushPoints = [start]
                }
                if draftBrushPoints.last != end {
                    draftBrushPoints.append(end)
                }
                onAnnotationCreated?(ScreenshotAnnotation(
                    brushPoints: draftBrushPoints,
                    style: currentStyle
                ))
            } else if kind == .text || kind == .step {
                let isClick = hypot(point.x - downPoint.x, point.y - downPoint.y) < 3
                let rect = (isClick || kind == .text)
                    ? defaultAnnotationRect(for: kind, at: start, viewport: viewport)
                    : SelectionGeometry.normalizedSelection(from: downPoint, to: point)
                let pixelRect = viewport.pixelRect(from: rect) ?? PixelRect(
                    x: start.x,
                    y: start.y,
                    width: 1,
                    height: 1
                )
                onAnnotationCreated?(ScreenshotAnnotation(
                    kind: kind,
                    start: PixelPoint(x: pixelRect.minX, y: pixelRect.minY),
                    end: PixelPoint(x: pixelRect.maxX, y: pixelRect.maxY),
                    style: currentStyle
                ))
            } else {
                guard hypot(point.x - downPoint.x, point.y - downPoint.y) >= 3,
                      start != end else {
                    onInteractionEnded?()
                    return
                }
                onAnnotationCreated?(ScreenshotAnnotation(
                    kind: kind,
                    start: start,
                    end: end,
                    style: currentStyle
                ))
            }
            draftBrushPoints = []
            onInteractionEnded?()
        }
    }

    private func defaultAnnotationRect(
        for kind: ScreenshotAnnotationKind,
        at pixelPoint: PixelPoint,
        viewport: ScreenshotAnnotationViewport
    ) -> CGRect {
        let pixelSize = viewport.pixelSize
        let stepSize = min(
            max(currentStyle.lineWidth, ScreenshotAnnotationStyle.minimumStepSize),
            ScreenshotAnnotationStyle.maximumStepSize
        )
        let width = min(kind == .step ? stepSize : currentStyle.lineWidth * 2 + 8,
                        max(1, pixelSize.width - pixelPoint.x))
        let height = min(kind == .step ? stepSize : currentStyle.lineWidth + 10,
                         max(1, pixelSize.height - pixelPoint.y))
        var rect = CGRect(
            x: CGFloat(pixelPoint.x) * viewport.scaleX,
            y: CGFloat(pixelPoint.y) * viewport.scaleY,
            width: CGFloat(width) * viewport.scaleX,
            height: CGFloat(height) * viewport.scaleY
        )
        if kind == .text, let selection {
            rect.size.width = min(CGFloat(currentStyle.lineWidth * 2 + 8) * viewport.scaleX, selection.width)
            rect.size.height = min(CGFloat(currentStyle.lineWidth + 10) * viewport.scaleY, selection.height)
            rect.origin.x = min(rect.minX, selection.maxX - rect.width)
            rect.origin.y = min(rect.minY, selection.maxY - rect.height)
        }
        return rect
    }

    func beginTextEditing(_ id: UUID) {
        commitActiveTextEditing()
        guard let annotation = annotations.first(where: { $0.id == id }),
              annotation.kind == .text,
              let viewport = annotationViewport else {
            return
        }
        let frame = viewport.viewRect(for: annotation.rect)
        let editor = AnnotationTextEditorView(frame: frame)
        editor.originalText = annotation.text
        editor.string = annotation.text
        editor.font = .systemFont(
            ofSize: CGFloat(annotation.style.lineWidth) * viewport.scaleY,
            weight: .semibold
        )
        editor.textColor = annotation.style.textColor
        editor.textContainerInset = NSSize(width: 4 * viewport.scaleY, height: 3 * viewport.scaleY)
        if annotation.style.fillsTextBackground == true {
            editor.backgroundColor = annotation.style.color.nsColor
            editor.drawsBackground = true
        }
        let available = (selection ?? bounds).intersection(bounds)
        let maximumWidth = annotation.text.isEmpty
            ? max(1, available.maxX - frame.minX)
            : frame.width
        editor.onTextChanged = { [weak self, weak editor] text in
            guard let self, let editor,
                  let index = annotations.firstIndex(where: { $0.id == id }) else { return }
            annotations[index].text = text
            let natural = ScreenshotTextLayout.size(
                text, style: annotation.style, width: .greatestFiniteMagnitude, scale: viewport.scaleY
            )
            let width = min(max(frame.width, natural.width), maximumWidth)
            let height = ScreenshotTextLayout.size(
                text, style: annotation.style, width: width, scale: viewport.scaleY
            ).height
            editor.setFrameSize(CGSize(width: width, height: min(height, max(1, available.maxY - frame.minY))))
            needsDisplay = true
        }
        editor.onCommit = { [weak self] in self?.finishTextEditing(commit: true) }
        editor.onCancel = { [weak self] in self?.finishTextEditing(commit: false) }
        addSubview(editor)
        textEditor = editor
        editingTextAnnotationID = id
        window?.makeFirstResponder(editor)
    }

    func commitActiveTextEditing() {
        guard textEditor != nil else { return }
        finishTextEditing(commit: true)
    }

    private func finishTextEditing(commit: Bool) {
        guard let editor = textEditor, let id = editingTextAnnotationID else { return }
        let text = editor.string
        let committedRect = commit && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? annotationViewport?.pixelRect(from: editor.frame) : nil
        if !commit,
           let index = annotations.firstIndex(where: { $0.id == id }) {
            annotations[index].text = editor.originalText
        }
        editor.removeFromSuperview()
        textEditor = nil
        editingTextAnnotationID = nil
        needsDisplay = true
        window?.makeFirstResponder(self)
        if let committedRect,
           let index = annotations.firstIndex(where: { $0.id == id }),
           committedRect != annotations[index].rect {
            onAnnotationInteractionBegan?(id)
            annotations[index].rect = committedRect
            onAnnotationChanged?(id, committedRect, nil)
            onTextEditingEnded?(id, text, true)
            onInteractionEnded?()
            return
        }
        onTextEditingEnded?(id, commit ? text : editor.originalText, commit)
    }

    private func updateToolbar() {
        guard let selection else {
            externalToolbarPanels.forEach { $0.orderOut(nil) }
            toolbar.removeFromSuperview()
            outputToolbar.removeFromSuperview()
            return
        }
        if !usesExternalToolbars, toolbar.superview == nil {
            addSubview(toolbar)
        }
        if !usesExternalToolbars, outputToolbar.superview == nil {
            addSubview(outputToolbar)
        }
        toolbar.selectedTool = activeTool
        toolbar.styleControlsEnabled = selectedAnnotationID != nil || activeTool.annotationKind != nil
        outputToolbar.canUndo = canUndo
        outputToolbar.canRedo = canRedo
        outputToolbar.canDelete = canDelete
        outputToolbar.selectedTool = activeTool
        outputToolbar.showsReselectButton = showsReselectAction
        outputToolbar.isOutputting = isOutputting
        let editingSize = toolbar.preferredContentSize
        let outputSize = outputToolbar.preferredContentSize
        if usesExternalToolbars, let window {
            if externalToolbarPanels.isEmpty {
                for content in [toolbar as NSView, outputToolbar as NSView] {
                    let panel = ScreenshotToolbarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                    panel.isReleasedWhenClosed = false
                    panel.isOpaque = false
                    panel.backgroundColor = .clear
                    panel.hasShadow = true
                    panel.hidesOnDeactivate = false
                    panel.level = .floating
                    panel.contentView = content
                    window.addChildWindow(panel, ordered: .above)
                    externalToolbarPanels.append(panel)
                }
            }
            let anchor = window.convertToScreen(convert(toolbarAnchorRect ?? selection, to: nil))
            let screen = window.screen?.visibleFrame ?? anchor.insetBy(dx: -400, dy: -300)
            func flipped(_ rect: CGRect) -> CGRect {
                CGRect(x: rect.minX, y: -rect.maxY, width: rect.width, height: rect.height)
            }
            let layout = ScreenshotToolbarLayout.layout(selection: flipped(anchor), bounds: flipped(screen), editingSize: editingSize, outputSize: outputSize)
            for (panel, frame) in zip(externalToolbarPanels, [layout.editingFrame, layout.outputFrame]) {
                panel.setFrame(flipped(frame), display: true)
                if window.isVisible { panel.orderFrontRegardless() }
            }
            return
        }
        let layoutBounds = toolbarAnchorRect ?? bounds
        guard editingSize.width <= layoutBounds.width - 16,
              editingSize.height <= layoutBounds.height - 16,
              outputSize.width <= layoutBounds.width - 16,
              outputSize.height <= layoutBounds.height - 16 else {
            toolbar.removeFromSuperview()
            outputToolbar.removeFromSuperview()
            return
        }
        let toolbarSelection = toolbarAnchorRect ?? selection
        let layout = ScreenshotToolbarLayout.layout(
            selection: toolbarSelection,
            bounds: layoutBounds,
            editingSize: editingSize,
            outputSize: outputSize,
            forceInside: toolbarAnchorRect != nil
        )
        toolbar.frame = layout.editingFrame
        outputToolbar.frame = layout.outputFrame
    }

    @discardableResult
    func cancelCurrentDrag() -> Bool {
        guard dragState != .none else { return false }
        let cancelledDrag = dragState
        dragState = .none
        mouseDownPoint = nil
        draftAnnotation = nil
        draftBrushPoints = []
        switch cancelledDrag {
        case .creatingSelection, .movingSelection, .resizingSelection:
            selection = selectionBeforeDrag
        case .adjustingCornerRadius:
            if let appearanceBeforeDrag {
                outputAppearance = appearanceBeforeDrag
                onOutputAppearanceChanged?(appearanceBeforeDrag)
            }
        case .none, .creatingAnnotation, .movingAnnotation, .resizingAnnotation, .adjustingArrow:
            break
        }
        appearanceBeforeDrag = nil
        needsDisplay = true
        onInteractionCancelled?()
        return true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updatePointerLocation(point)
        updateCursor(for: point)
        updateHoverHint(at: point)
        if selection == nil, dragState == .none {
            onTargetHover?(point)
        }
    }

    override func mouseExited(with event: NSEvent) {
        setHoverHint(nil, anchor: .zero)
        updatePointerLocation(nil)
        onTargetHover?(nil)
    }

    func updatePointerLocation(_ point: CGPoint?) {
        guard pointerLocation != point else { return }
        let previousLocation = pointerLocation
        pointerLocation = point
        updateCrosshairGuide()
        guard selection == nil, showsColorInspector else { return }

        var dirtyRect = CGRect.null
        if let previousLocation {
            dirtyRect = dirtyRect.union(
                ScreenshotMagnifierLayout.panel(for: previousLocation, in: bounds)
                    .insetBy(dx: -2, dy: -2)
            )
        }
        if let point {
            dirtyRect = dirtyRect.union(
                ScreenshotMagnifierLayout.panel(for: point, in: bounds)
                    .insetBy(dx: -2, dy: -2)
            )
        }
        guard !dirtyRect.isNull else { return }
        setNeedsDisplay(dirtyRect.intersection(bounds))
    }

    private var currentPointerLocation: CGPoint? {
        guard let window else { return pointerLocation }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(point) ? point : nil
    }

    private func installCrosshairGuideIfNeeded() {
        guard crosshairGuide.superview == nil else {
            crosshairGuide.frame = bounds
            return
        }
        crosshairGuide.frame = bounds
        crosshairGuide.autoresizingMask = [.width, .height]
        addSubview(crosshairGuide, positioned: .below, relativeTo: nil)
        updateCrosshairGuide()
    }

    private func updateCrosshairGuide() {
        installCrosshairGuideIfNeeded()
        crosshairGuide.setPoint(
            showsColorInspector && selection == nil ? pointerLocation : nil
        )
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    private var hoverHintTask: Task<Void, Never>?
    private var hoverHintText: String?
    private var hoverHintAnchor: CGRect = .zero
    private var hoverHintView: NSView?

    func dismissHoverHint() {
        setHoverHint(nil, anchor: .zero)
    }

    func updateHoverHint(at point: CGPoint) {
        if let selection, activeTool == .selection, selectedAnnotationID == nil,
           SelectionCornerRadiusGeometry.hitTest(point, selection: selection,
                                                 radius: outputAppearance.cornerRadius) {
            let center = SelectionCornerRadiusGeometry.handleCenter(
                in: selection, radius: outputAppearance.cornerRadius
            )
            setHoverHint("拖动调整圆角", anchor: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12))
            return
        }
        for surface in [toolbar as NSView, outputToolbar as NSView] where surface.superview != nil && surface.frame.contains(point) {
            var hit = surface.hitTest(point)
            while let view = hit, view !== surface {
                if let hint = view.toolTip, !hint.isEmpty {
                    setHoverHint(hint, anchor: convert(view.bounds, from: view))
                    return
                }
                hit = view.superview
            }
        }
        setHoverHint(nil, anchor: .zero)
    }

    private func setHoverHint(_ text: String?, anchor: CGRect) {
        guard hoverHintText != text || hoverHintAnchor != anchor else { return }
        hoverHintTask?.cancel()
        hoverHintView?.removeFromSuperview()
        hoverHintView = nil
        hoverHintText = text
        hoverHintAnchor = anchor
        guard let text else { return }
        hoverHintTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(360))
            guard !Task.isCancelled, let self, self.window?.isVisible == true else { return }
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 11.5, weight: .medium)
            label.textColor = NylaiTheme.primaryText(for: self.effectiveAppearance)
            let size = CGSize(width: label.fittingSize.width + 16, height: label.fittingSize.height + 10)
            let left = min(max(anchor.midX - size.width / 2, 5), max(5, self.bounds.width - size.width - 5))
            let top = anchor.minY - size.height - 6
            let originY = top >= 5 ? top : min(anchor.maxY + 6, self.bounds.height - size.height - 5)
            let bubble = ScreenshotHoverHintView(frame: CGRect(origin: CGPoint(x: left, y: originY), size: size))
            bubble.wantsLayer = true
            bubble.layer?.zPosition = 50
            bubble.layer?.cornerRadius = 6
            bubble.layer?.backgroundColor = NylaiTheme.panelBackground(for: self.effectiveAppearance).cgColor
            bubble.layer?.borderColor = NylaiTheme.border(for: self.effectiveAppearance).cgColor
            bubble.layer?.borderWidth = 1
            label.frame = bubble.bounds.insetBy(dx: 8, dy: 5)
            bubble.addSubview(label)
            self.addSubview(bubble, positioned: .above, relativeTo: nil)
            self.hoverHintView = bubble
        }
    }

    private var strokeCursor: (diameter: CGFloat, color: ScreenshotAnnotationColor, cursor: NSCursor)?

    private func drawingCursor() -> NSCursor {
        guard let kind = activeTool.annotationKind, kind.supportsLineStyleControl,
              let viewport = annotationViewport else { return .crosshair }
        let diameter = max(1, CGFloat(currentStyle.lineWidth) * min(viewport.scaleX, viewport.scaleY))
        let color = currentStyle.color
        if let strokeCursor, strokeCursor.diameter == diameter, strokeCursor.color == color {
            return strokeCursor.cursor
        }
        let size = NSSize(width: max(17, diameter + 8), height: max(17, diameter + 8))
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let image = NSImage(size: size, flipped: false) { _ in
            let circle = NSBezierPath(ovalIn: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                                                     width: diameter, height: diameter))
            NSColor.white.withAlphaComponent(0.80).setStroke()
            circle.lineWidth = 1
            circle.stroke()
            color.nsColor.withAlphaComponent(0.90).setFill()
            circle.fill()
            let crosshair = NSBezierPath()
            let arm = max(5, diameter / 2 + 2)
            crosshair.move(to: CGPoint(x: center.x - arm, y: center.y))
            crosshair.line(to: CGPoint(x: center.x + arm, y: center.y))
            crosshair.move(to: CGPoint(x: center.x, y: center.y - arm))
            crosshair.line(to: CGPoint(x: center.x, y: center.y + arm))
            NSColor.black.withAlphaComponent(0.82).setStroke()
            crosshair.lineWidth = 2.5
            crosshair.stroke()
            NSColor.white.setStroke()
            crosshair.lineWidth = 1
            crosshair.stroke()
            return true
        }
        let cursor = NSCursor(image: image, hotSpot: center)
        strokeCursor = (diameter, color, cursor)
        return cursor
    }

    private func updateCursor(for point: CGPoint) {
        let overEditing = toolbar.superview != nil && toolbar.frame.contains(point)
        let overOutput = outputToolbar.superview != nil && outputToolbar.frame.contains(point)
        if overEditing || overOutput {
            NSCursor.arrow.set()
            return
        }
        guard let selection else {
            NSCursor.crosshair.set()
            return
        }
        if activeTool != .selection, let selectedAnnotationID,
           let annotation = annotations.first(where: { $0.id == selectedAnnotationID }),
           annotation.kind == .arrow, let viewport = annotationViewport,
           arrowHandle(at: point, annotation: annotation, rect: viewport.viewRect(for: annotation.rect)) != nil {
            NSCursor.openHand.set()
            return
        }
        if activeTool != .selection,
           selection.contains(point),
           let selectedAnnotationID,
           let annotation = annotations.first(where: { $0.id == selectedAnnotationID }),
           annotation.kind != .arrow,
           let viewport = annotationViewport,
           let handle = AnnotationSelectionGeometry.handle(
               at: point,
               in: viewport.viewRect(for: annotation.rect),
               hitSize: 18,
               proportional: annotation.kind == .step
           ), annotation.kind != .text || handle == .left || handle == .right {
            handle.cursor.set()
            return
        }
        if activeTool == .selection {
            if selectedAnnotationID == nil,
               SelectionCornerRadiusGeometry.hitTest(
                   point,
                   selection: selection,
                   radius: outputAppearance.cornerRadius
               ) {
                NSCursor.arrow.set()
                return
            }
            if let handle = SelectionGeometry.handle(at: point, in: selection) {
                handle.cursor.set()
            } else if selection.contains(point) {
                NSCursor.openHand.set()
            } else {
                NSCursor.arrow.set()
            }
            return
        }
        if let viewport = annotationViewport,
           ScreenshotAnnotationViewport.hitTest(
               point,
               annotations: annotations,
               viewport: viewport,
               visibleIn: selection
           ) != nil {
            NSCursor.openHand.set()
        } else if activeTool.annotationKind != nil, selection.contains(point) {
            drawingCursor().set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            if textEditor != nil {
                super.keyDown(with: event)
                return
            }
            onCancel()
            return
        }
        if !isOutputting,
           selection != nil,
           event.modifierFlags.contains(.command),
           event.modifierFlags.contains(.control),
           event.charactersIgnoringModifiers?.lowercased() == "r" {
            onScrollCapture?()
            return
        }
        if event.modifierFlags.contains(.command),
           let characters = event.charactersIgnoringModifiers?.lowercased(),
           characters == "z" {
            if event.modifierFlags.contains(.shift) {
                onRedo?()
            } else {
                onUndo?()
            }
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            if canDelete {
                onDelete?()
            }
            return
        }
        if !isOutputting, event.keyCode == 36 || event.keyCode == 76 {
            onCopy?()
            return
        }
        if !isOutputting, event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "s" {
            onSave?()
            return
        }
        super.keyDown(with: event)
    }

    func clearTargetPreview() {
        highlightedTargetRect = nil
        highlightedTargetLabel = nil
        highlightedTargetIsWindow = false
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }

    @objc func undoAction(_ sender: Any?) {
        guard canUndo else { return }
        onUndo?()
    }

    @objc func redoAction(_ sender: Any?) {
        guard canRedo else { return }
        onRedo?()
    }
}

@MainActor
private final class ScreenshotHoverHintView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class AnnotationTextEditorView: NSTextView {
    var originalText = ""
    var onTextChanged: ((String) -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    private func configure() {
        isRichText = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        allowsUndo = false
        drawsBackground = true
        backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94)
        textContainerInset = NSSize(width: 7, height: 6)
        isHorizontallyResizable = false
        isVerticallyResizable = false
        textContainer?.widthTracksTextView = true
        textContainer?.lineFragmentPadding = 0
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        layer?.borderColor = NylaiTheme.accent.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从归档创建文字编辑器")
    }

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        if (event.keyCode == 36 || event.keyCode == 76),
           event.modifierFlags.contains(.command) {
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        onTextChanged?(string)
    }
}
