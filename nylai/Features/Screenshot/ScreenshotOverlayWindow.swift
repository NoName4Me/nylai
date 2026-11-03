import AppKit
import CoreGraphics

@MainActor
final class ScreenshotOverlayWindow: NSWindow {
    var onCancel: () -> Void = {}

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

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
final class ScreenshotOverlayView: NSView {
    enum DragState: Equatable {
        case none
        case creatingSelection(start: CGPoint)
        case movingSelection(origin: CGRect, start: CGPoint)
        case resizingSelection(handle: SelectionResizeHandle, startRect: CGRect, start: CGPoint)
        case adjustingCornerRadius(startRadius: Int, start: CGPoint)
        case creatingAnnotation(start: CGPoint)
        case movingAnnotation(id: UUID, viewOrigin: CGRect, start: CGPoint)
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
    var onSave: (() -> Void)?
    var onPin: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onFitWidth: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onDelete: (() -> Void)?
    var onCancel: () -> Void = {}

    private(set) var selection: CGRect?
    private(set) var dragState = DragState.none
    private(set) var annotations: [ScreenshotAnnotation] = []
    private(set) var selectedAnnotationID: UUID?
    private(set) var activeTool = ScreenshotEditorTool.selection
    var highlightedTargetRect: CGRect? {
        didSet { needsDisplay = true }
    }
    var highlightedTargetLabel: String? {
        didSet { needsDisplay = true }
    }
    var highlightedTargetIsWindow = false {
        didSet { needsDisplay = true }
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
        didSet { needsDisplay = true }
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
        needsDisplay = true
    }

    func setTool(_ tool: ScreenshotEditorTool) {
        commitActiveTextEditing()
        let changed = activeTool != tool
        activeTool = tool
        toolbar.selectedTool = tool
        outputToolbar.selectedTool = tool
        updateDisplayedStyle()
        if changed, tool == .selection {
            onAnnotationSelected?(nil)
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
           let pointerLocation {
            drawColorInspector(at: pointerLocation)
        }

        guard let selection else { return }
        drawAnnotations(clippedTo: selection)
        drawAppearancePreview(in: selection)
        drawSelectionSizeBadge(in: selection)
        guard showsSelectionChrome else { return }

        NSColor.black.withAlphaComponent(0.38).setStroke()
        let borderShadow = NSBezierPath(rect: selection.insetBy(dx: 1.25, dy: 1.25))
        borderShadow.lineWidth = 4.5
        borderShadow.stroke()

        NylaiTheme.accent.setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: 1.25, dy: 1.25))
        border.lineWidth = 2.5
        border.stroke()

        let points = SelectionGeometry.handlePoints(in: selection)
        for point in [
            points.topLeft, points.top, points.topRight,
            points.left, points.right,
            points.bottomLeft, points.bottom, points.bottomRight,
        ] {
            let handleRect = CGRect(
                x: point.x - SelectionGeometry.handleSize / 2,
                y: point.y - SelectionGeometry.handleSize / 2,
                width: SelectionGeometry.handleSize,
                height: SelectionGeometry.handleSize
            )
            NSColor.white.setFill()
            NSBezierPath(roundedRect: handleRect, xRadius: 1.5, yRadius: 1.5).fill()
            NylaiTheme.accent.setStroke()
            let outline = NSBezierPath(roundedRect: handleRect, xRadius: 1.5, yRadius: 1.5)
            outline.lineWidth = 1
            outline.stroke()
        }
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
        let shadow = NSBezierPath()
        shadow.move(to: CGPoint(x: bounds.minX, y: point.y))
        shadow.line(to: CGPoint(x: bounds.maxX, y: point.y))
        shadow.move(to: CGPoint(x: point.x, y: bounds.minY))
        shadow.line(to: CGPoint(x: point.x, y: bounds.maxY))
        NSColor.black.withAlphaComponent(0.42).setStroke()
        shadow.lineWidth = 1.5
        shadow.stroke()

        let guides = NSBezierPath()
        guides.move(to: CGPoint(x: bounds.minX, y: point.y))
        guides.line(to: CGPoint(x: bounds.maxX, y: point.y))
        guides.move(to: CGPoint(x: point.x, y: bounds.minY))
        guides.line(to: CGPoint(x: point.x, y: bounds.maxY))
        NylaiTheme.accent.withAlphaComponent(0.92).setStroke()
        guides.lineWidth = 0.75
        guides.stroke()

        let center = NSBezierPath()
        center.move(to: CGPoint(x: point.x - 6, y: point.y))
        center.line(to: CGPoint(x: point.x + 6, y: point.y))
        center.move(to: CGPoint(x: point.x, y: point.y - 6))
        center.line(to: CGPoint(x: point.x, y: point.y + 6))
        NSColor.black.withAlphaComponent(0.48).setStroke()
        center.lineWidth = 3
        center.stroke()
        NylaiTheme.accent.setStroke()
        center.lineWidth = 1.25
        center.stroke()

        guard let sourceImage,
              let viewport = annotationViewport else {
            return
        }
        let size = ScreenshotMagnifierLayout.panelSize
        var origin = CGPoint(x: point.x + 22, y: point.y + 22)
        if origin.x + size.width > bounds.maxX - 12 {
            origin.x = point.x - 22 - size.width
        }
        if origin.y + size.height > bounds.maxY - 12 {
            origin.y = point.y - 22 - size.height
        }
        origin.x = min(max(origin.x, bounds.minX + 12), bounds.maxX - size.width - 12)
        origin.y = min(max(origin.y, bounds.minY + 12), bounds.maxY - size.height - 12)
        let panel = CGRect(origin: origin, size: size)
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
        NSColor.white.setFill()
        NSBezierPath(ovalIn: outer).fill()
        NylaiTheme.accent.setStroke()
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
            drawAnnotationBorder(annotation, in: rect, viewport: viewport)
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
            drawAnnotationSelection(annotation, in: rect)
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
            drawTextAnnotation(annotation, in: rect)
            return
        }
        if annotation.kind == .step {
            drawStepAnnotation(annotation, in: rect)
            return
        }
        NSColor.black.withAlphaComponent(0.32).setStroke()
        let shadow = NSBezierPath(cgPath: ScreenshotAnnotationPath.cgPath(for: annotation, in: rect))
        shadow.lineWidth = CGFloat(annotation.style.lineWidth) / min(viewport.scaleX, viewport.scaleY) + 2
        shadow.stroke()

        annotation.style.color.nsColor.setStroke()
        let border = NSBezierPath(cgPath: ScreenshotAnnotationPath.cgPath(for: annotation, in: rect))
        border.lineWidth = CGFloat(annotation.style.lineWidth) / min(viewport.scaleX, viewport.scaleY)
        border.lineCapStyle = .round
        border.lineJoinStyle = .round
        if annotation.style.lineStyle == .dashed {
            let width = border.lineWidth
            border.setLineDash([width * 3, width * 2], count: 2, phase: 0)
        }
        border.stroke()
    }

    private func drawTextAnnotation(_ annotation: ScreenshotAnnotation, in rect: CGRect) {
        guard !annotation.text.isEmpty else {
            NSColor.secondaryLabelColor.setStroke()
            let placeholder = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            placeholder.lineWidth = 1
            placeholder.setLineDash([4, 3], count: 2, phase: 0)
            placeholder.stroke()
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(
                ofSize: max(CGFloat(annotation.style.lineWidth), 8),
                weight: .semibold
            ),
            .foregroundColor: annotation.style.color.nsColor,
        ]
        NSAttributedString(string: annotation.text, attributes: attributes)
            .draw(in: rect.insetBy(dx: 1, dy: 1))
    }

    private func drawStepAnnotation(_ annotation: ScreenshotAnnotation, in rect: CGRect) {
        guard let stepNumber = annotation.stepNumber else { return }
        annotation.style.color.nsColor.setFill()
        NSBezierPath(ovalIn: rect).fill()
        let fontSize = max(9, min(rect.height * 0.56, 20))
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
        let points = SelectionGeometry.handlePoints(in: rect)
        let handles = annotation.kind == .step
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
        guard !isOutputting else { return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let textEditor {
            if textEditor.frame.contains(point) {
                return
            }
            commitActiveTextEditing()
        }
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
            if let handle = AnnotationSelectionGeometry.handle(
                at: point,
                in: rect,
                hitSize: 18,
                proportional: annotation.kind == .step
            ) {
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
             .resizingAnnotation(let annotationID, _, _, _, _):
            id = annotationID
        default:
            return
        }
        mouseDownPoint = point
        onAnnotationInteractionBegan?(id)
        dragState = state
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

    override func mouseDragged(with event: NSEvent) {
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
            guard let viewport = annotationViewport,
                  let kind = activeTool.annotationKind else { break }
            let startPixel = viewport.pixelPoint(from: start)
            let endPixel = viewport.pixelPoint(from: point)
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
        case .resizingAnnotation(
            let id,
            let handle,
            let viewStartRect,
            let start,
            let originalStyle
        ):
            guard let viewport = annotationViewport else { break }
            let rect = AnnotationSelectionGeometry.resized(
                viewStartRect,
                handle: handle,
                by: CGPoint(x: point.x - start.x, y: point.y - start.y),
                constrainedTo: bounds,
                minimumSize: CGSize(width: viewport.scaleX, height: viewport.scaleY),
                proportional: annotations.first(where: { $0.id == id })?.kind == .step
            )
            let style = annotations.first(where: { $0.id == id })?.kind == .text
                ? resizedTextStyle(
                    originalStyle,
                    from: viewStartRect,
                    to: rect
                )
                : nil
            updateAnnotation(id, viewRect: rect, viewport: viewport, style: style)
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
            let end = viewport.pixelPoint(from: point)
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
                let rect = isClick
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
        let width = min(kind == .step ? stepSize : 180, max(1, pixelSize.width - pixelPoint.x))
        let height = min(kind == .step ? stepSize : 80, max(1, pixelSize.height - pixelPoint.y))
        return CGRect(
            x: CGFloat(pixelPoint.x) * viewport.scaleX,
            y: CGFloat(pixelPoint.y) * viewport.scaleY,
            width: CGFloat(width) * viewport.scaleX,
            height: CGFloat(height) * viewport.scaleY
        )
    }

    private func resizedTextStyle(
        _ style: ScreenshotAnnotationStyle,
        from originalRect: CGRect,
        to resizedRect: CGRect
    ) -> ScreenshotAnnotationStyle? {
        guard originalRect.height > 0 else { return nil }
        let scale = resizedRect.height / originalRect.height
        var resized = style
        resized.lineWidth = Int((CGFloat(style.lineWidth) * scale).rounded())
        return resized.validated(for: .text)
    }

    func beginTextEditing(_ id: UUID) {
        commitActiveTextEditing()
        guard let annotation = annotations.first(where: { $0.id == id }),
              annotation.kind == .text,
              let viewport = annotationViewport else {
            return
        }
        let frame = viewport.viewRect(for: annotation.rect).insetBy(dx: 1, dy: 1)
        let editor = AnnotationTextEditorView(frame: frame)
        editor.originalText = annotation.text
        editor.string = annotation.text
        editor.font = .systemFont(
            ofSize: max(CGFloat(annotation.style.lineWidth), 8),
            weight: .semibold
        )
        editor.textColor = annotation.style.color.nsColor
        editor.onTextChanged = { [weak self] text in
            guard let self,
                  let index = annotations.firstIndex(where: { $0.id == id }) else { return }
            annotations[index].text = text
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
        if !commit,
           let index = annotations.firstIndex(where: { $0.id == id }) {
            annotations[index].text = editor.originalText
        }
        editor.removeFromSuperview()
        textEditor = nil
        editingTextAnnotationID = nil
        needsDisplay = true
        window?.makeFirstResponder(self)
        onTextEditingEnded?(id, commit ? text : editor.originalText, commit)
    }

    private func updateToolbar() {
        guard let selection else {
            toolbar.removeFromSuperview()
            outputToolbar.removeFromSuperview()
            return
        }
        if toolbar.superview == nil {
            addSubview(toolbar)
        }
        if outputToolbar.superview == nil {
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
        case .none, .creatingAnnotation, .movingAnnotation, .resizingAnnotation:
            break
        }
        appearanceBeforeDrag = nil
        needsDisplay = true
        onInteractionCancelled?()
        return true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pointerLocation = point
        needsDisplay = true
        updateCursor(for: point)
        if selection == nil, dragState == .none {
            onTargetHover?(point)
        } else {
            onTargetHover?(nil)
        }
    }

    override func mouseExited(with event: NSEvent) {
        pointerLocation = nil
        needsDisplay = true
        onTargetHover?(nil)
    }

    func updatePointerLocation(_ point: CGPoint?) {
        pointerLocation = point
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
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
        if activeTool != .selection,
           selection.contains(point),
           let selectedAnnotationID,
           let annotation = annotations.first(where: { $0.id == selectedAnnotationID }),
           let viewport = annotationViewport,
           let handle = AnnotationSelectionGeometry.handle(
               at: point,
               in: viewport.viewRect(for: annotation.rect),
               hitSize: 18,
               proportional: annotation.kind == .step
           ) {
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
                NSCursor.crosshair.set()
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
            NSCursor.crosshair.set()
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
