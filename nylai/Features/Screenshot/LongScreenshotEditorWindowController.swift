import AppKit
import Observation

@MainActor
@Observable
final class LongScreenshotEditorModel {
    let source: ScreenshotImageSource
    let session: ScreenshotSession
    let annotationStyleStore: ScreenshotAnnotationStyleStore
    let outputAppearanceStore: ScreenshotOutputAppearanceStore
    private let paster: any ScreenshotPasting
    private let saver: any ScreenshotSaving
    private let pinImage: @MainActor (CGImage) -> Void
    private let historyStore: ScreenshotHistoryStore?
    private let isHistoryEnabled: @MainActor () -> Bool
    private let presentError: @MainActor (Error) -> Void
    private var styleInteractionID: UUID?
    private var styleCommitTask: Task<Void, Never>?
    private var outputTask: Task<Void, Never>?
    private var newTextAnnotationIDs: Set<UUID> = []
    private var hasRecordedHistory = false
    private var isClosed = false
    private(set) var revision = 0

    init(
        image: CGImage,
        pointPixelScale: CGFloat,
        annotationStyleStore: ScreenshotAnnotationStyleStore = ScreenshotAnnotationStyleStore(),
        outputAppearanceStore: ScreenshotOutputAppearanceStore = ScreenshotOutputAppearanceStore(),
        paster: any ScreenshotPasting = PasteboardScreenshotPaster(),
        saver: any ScreenshotSaving = PNGScreenshotSaver(),
        pinnedImageManager: PinnedImageManager = PinnedImageManager(),
        historyStore: ScreenshotHistoryStore? = nil,
        isHistoryEnabled: @escaping @MainActor () -> Bool = { false },
        presentError: @escaping @MainActor (Error) -> Void = ScreenshotErrorPresenter.show,
        pinImage: (@MainActor (CGImage) -> Void)? = nil
    ) throws {
        let scale = max(pointPixelScale, 0.1)
        let pixelSize = try PixelSize(width: image.width, height: image.height)
        let geometry = try ScreenshotSourceGeometry(
            kind: .window(0),
            globalFrame: CGRect(
                x: 0,
                y: 0,
                width: CGFloat(image.width) / scale,
                height: CGFloat(image.height) / scale
            ),
            pointPixelScale: scale,
            pixelSize: pixelSize
        )
        source = try ScreenshotImageSource(image: image, geometry: geometry)
        session = ScreenshotSession()
        self.annotationStyleStore = annotationStyleStore
        self.outputAppearanceStore = outputAppearanceStore
        self.paster = paster
        self.saver = saver
        self.pinImage = pinImage ?? { pinnedImageManager.pin($0) }
        self.historyStore = historyStore
        self.isHistoryEnabled = isHistoryEnabled
        self.presentError = presentError
        session.begin(with: source)
        session.setOutputAppearance(outputAppearanceStore.appearance)
        try? session.select(pixelRect: PixelRect(
            x: 0,
            y: 0,
            width: image.width,
            height: image.height
        ))
    }

    var image: CGImage { source.image }
    var pixelSize: PixelSize { source.geometry.pixelSize }

    func canvasDidChange() {
        revision &+= 1
    }

    func addAnnotation(_ annotation: ScreenshotAnnotation) {
        var resolved = annotation
        if resolved.kind == .step {
            resolved.stepNumber = ScreenshotStepNumbering.next(after: session.annotations)
        }
        try? session.addAnnotation(resolved)
        if resolved.kind == .text {
            newTextAnnotationIDs.insert(resolved.id)
        }
        canvasDidChange()
    }

    func beginSelectionInteraction() {
        do {
            try session.beginInteraction(.movingSelection)
        } catch {
            return
        }
        canvasDidChange()
    }

    func updateSelection(viewRect: CGRect?, viewSize: CGSize) {
        guard let viewport = ScreenshotAnnotationViewport(
            pixelSize: pixelSize,
            viewSize: viewSize
        ) else {
            return
        }
        guard let viewRect,
              let selection = viewport.pixelRect(from: viewRect) else {
            session.clearSelection()
            canvasDidChange()
            return
        }
        try? session.select(pixelRect: selection)
        canvasDidChange()
    }

    func updateArrowGeometry(_ annotation: ScreenshotAnnotation) {
        try? session.updateArrowGeometry(annotation)
        canvasDidChange()
    }

    func updateAnnotation(
        _ id: UUID,
        rect: PixelRect,
        style: ScreenshotAnnotationStyle? = nil
    ) {
        try? session.updateAnnotation(id, rect: rect, style: style)
        canvasDidChange()
    }

    func textEditingEnded(id: UUID, text: String, committed: Bool) {
        let wasNew = newTextAnnotationIDs.remove(id) != nil
        if committed, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? session.updateAnnotationText(id, text: text)
        } else if committed || wasNew {
            session.deleteAnnotation(id)
        }
        canvasDidChange()
    }

    func beginAnnotationInteraction(id: UUID?) throws {
        try session.beginInteraction(id.map(ScreenshotSession.Interaction.annotation) ?? .creatingAnnotation)
        canvasDidChange()
    }

    func endInteraction() {
        session.endInteraction()
        canvasDidChange()
    }

    func cancelInteraction() {
        session.cancelInteraction()
        canvasDidChange()
    }

    func applyStyle(_ style: ScreenshotAnnotationStyle) {
        if let selected = session.selectedAnnotation {
            let validated = style.validated(for: selected.kind)
            beginStyleInteractionIfNeeded(for: selected.id)
            try? session.updateAnnotationStyle(selected.id, style: validated)
            annotationStyleStore.setStyle(validated, for: selected.kind)
            scheduleStyleCommit()
        } else if let kind = activeStyleKind {
            let validated = style.validated(for: kind)
            annotationStyleStore.setStyle(validated, for: kind)
        }
        canvasDidChange()
    }

    var activeStyleKind: ScreenshotAnnotationKind?

    func defaultStyle(for kind: ScreenshotAnnotationKind) -> ScreenshotAnnotationStyle {
        annotationStyleStore.style(for: kind)
    }

    func undo() {
        session.undo()
        canvasDidChange()
    }

    func redo() {
        session.redo()
        canvasDidChange()
    }

    func deleteSelected() {
        session.deleteSelectedAnnotation()
        canvasDidChange()
    }

    func selectAnnotation(_ id: UUID?) {
        finishStyleInteraction()
        session.selectAnnotation(id)
        canvasDidChange()
    }

    func copy() {
        runOutput { [paster] image in
            try paster.copy(image)
            return true
        }
    }

    func save() {
        runOutput { [saver] image in
            guard try await saver.save(image) != nil else { return false }
            return true
        }
    }

    func pin(onSuccess: @escaping @MainActor () -> Void = {}) {
        runOutput(onSuccess: onSuccess) { [pinImage] image in
            pinImage(image)
            return true
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        styleCommitTask?.cancel()
        styleCommitTask = nil
        outputTask?.cancel()
        outputTask = nil
        session.cancel()
    }

    private func runOutput(
        onSuccess: @escaping @MainActor () -> Void = {},
        _ operation: @escaping @MainActor (CGImage) async throws -> Bool
    ) {
        guard !isClosed,
              outputTask == nil,
              session.phase == .editing,
              let selection = session.selection else {
            return
        }
        do {
            try session.beginOutput()
        } catch {
            return
        }
        guard let rendered = try? ScreenshotOutputRenderer.render(
            source: source,
            selection: selection,
            annotations: session.annotations,
            appearance: session.outputAppearance
        ) else {
            session.outputCancelled()
            presentError(ScreenshotOutputError.imageRenderingFailed)
            return
        }
        outputTask = Task { [weak self] in
            guard let self else { return }
            defer {
                outputTask = nil
                if !isClosed {
                    canvasDidChange()
                }
            }
            do {
                guard try await operation(rendered) else {
                    if !isClosed {
                        session.outputCancelled()
                    }
                    return
                }
                guard !isClosed, !Task.isCancelled else {
                    if !isClosed {
                        session.outputCancelled()
                    }
                    return
                }
                recordHistory(rendered)
                session.outputSucceededKeepingEditorActive()
                onSuccess()
            } catch is CancellationError {
                if !isClosed {
                    session.outputCancelled()
                }
            } catch {
                if !isClosed {
                    session.outputCancelled()
                    presentError(error)
                }
            }
        }
    }

    private func recordHistory(_ image: CGImage) {
        guard !isClosed,
              !hasRecordedHistory,
              isHistoryEnabled(),
              let historyStore else {
            return
        }
        do {
            try historyStore.add(image)
            hasRecordedHistory = true
        } catch {
            presentError(error)
        }
    }

    private func beginStyleInteractionIfNeeded(for id: UUID) {
        guard styleInteractionID != id else { return }
        finishStyleInteraction()
        do {
            try session.beginInteraction(.annotation(id))
            styleInteractionID = id
        } catch {
            styleInteractionID = nil
        }
    }

    private func scheduleStyleCommit() {
        styleCommitTask?.cancel()
        styleCommitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            self?.finishStyleInteraction()
        }
    }

    private func finishStyleInteraction() {
        styleCommitTask?.cancel()
        styleCommitTask = nil
        guard styleInteractionID != nil else { return }
        styleInteractionID = nil
        session.endInteraction()
        canvasDidChange()
    }
}

@MainActor
final class LongScreenshotEditorWindowController: NSWindowController {
    var onClose: (() -> Void)?
    private let model: LongScreenshotEditorModel
    private let scrollView: NSScrollView
    private let canvasHost: LongScreenshotCanvasHostView
    private let overlayView: ScreenshotOverlayView
    private var boundsObserver: NSObjectProtocol?
    private var zoom: CGFloat = 1
    private var basePointSize: CGSize
    private let preferredFrame: CGRect?

    init(
        image: CGImage,
        pointPixelScale: CGFloat,
        preferredFrame: CGRect? = nil,
        annotationStyleStore: ScreenshotAnnotationStyleStore = ScreenshotAnnotationStyleStore(),
        outputAppearanceStore: ScreenshotOutputAppearanceStore = ScreenshotOutputAppearanceStore(),
        pinnedImageManager: PinnedImageManager = PinnedImageManager(),
        historyStore: ScreenshotHistoryStore? = nil,
        isHistoryEnabled: @escaping @MainActor () -> Bool = { false }
    ) throws {
        model = try LongScreenshotEditorModel(
            image: image,
            pointPixelScale: pointPixelScale,
            annotationStyleStore: annotationStyleStore,
            outputAppearanceStore: outputAppearanceStore,
            pinnedImageManager: pinnedImageManager,
            historyStore: historyStore,
            isHistoryEnabled: isHistoryEnabled
        )
        basePointSize = CGSize(
            width: CGFloat(image.width) / max(pointPixelScale, 0.1),
            height: CGFloat(image.height) / max(pointPixelScale, 0.1)
        )
        self.preferredFrame = preferredFrame
        canvasHost = LongScreenshotCanvasHostView(image: image)
        overlayView = ScreenshotOverlayView(frame: .zero)
        scrollView = NSScrollView()
        super.init(window: nil)
        buildWindow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从归档创建长图编辑器")
    }

    func present() {
        guard let window else { return }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(overlayView)
        DispatchQueue.main.async { [weak self] in
            self?.fitWidth(animated: false)
        }
    }

    private func buildWindow() {
        let screen = preferredFrame.flatMap { preferred in
            NSScreen.screens.first(where: { $0.frame.intersects(preferred) })
        } ?? NSScreen.screens.first(where: {
            $0.frame.contains(NSEvent.mouseLocation)
        }) ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1_120, height: 800)
        let preferredSize = preferredFrame?.size ?? CGSize(
            width: min(basePointSize.width, screenFrame.width),
            height: min(basePointSize.height, screenFrame.height)
        )
        let size = CGSize(
            width: min(max(preferredSize.width, 380), screenFrame.width),
            height: min(max(preferredSize.height, 360), screenFrame.height)
        )
        var origin = preferredFrame?.origin ?? CGPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2
        )
        if let selection = preferredFrame {
            origin.y = selection.maxY - size.height
        }
        origin.x = min(max(origin.x, screenFrame.minX), screenFrame.maxX - size.width)
        origin.y = min(max(origin.y, screenFrame.minY), screenFrame.maxY - size.height)
        let frame = CGRect(origin: origin, size: size)
        let window = LongScreenshotEditorWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.shared.string("滚动截图")
        window.identifier = NSUserInterfaceItemIdentifier("nylai.long-screenshot-editor")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1)
        window.isOpaque = true
        window.hasShadow = false
        window.animationBehavior = .none
        window.setFrame(frame, display: false)
        self.window = window

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)

        canvasHost.addSubview(overlayView)
        overlayView.autoresizingMask = [.width, .height]
        scrollView.documentView = canvasHost
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateToolbarAnchor() }
        }
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        configureOverlay()
    }

    private func configureOverlay() {
        overlayView.showsSelectionChrome = false
        overlayView.showsSelectionTool = false
        overlayView.showsScrollCaptureAction = false
        overlayView.showsZoomControls = true
        overlayView.showsColorInspector = false
        overlayView.sourcePixelSize = model.pixelSize
        overlayView.sourceImage = model.image
        overlayView.outputAppearance = model.session.outputAppearance
        for kind in ScreenshotAnnotationKind.allCases {
            overlayView.setDefaultStyle(model.defaultStyle(for: kind), for: kind)
        }
        overlayView.onInteractionBegan = { [weak self] in
            self?.model.beginSelectionInteraction()
        }
        overlayView.onSelectionChanged = { [weak self] rect in
            guard let self else { return }
            model.updateSelection(viewRect: rect, viewSize: overlayView.bounds.size)
            overlayView.setPixelDimensions(model.session.selection)
        }
        overlayView.onSelectionCommitted = { [weak self] rect in
            guard let self else { return }
            model.updateSelection(viewRect: rect, viewSize: overlayView.bounds.size)
            overlayView.setPixelDimensions(model.session.selection)
        }
        overlayView.onAnnotationInteractionBegan = { [weak self] id in
            guard let self else { return }
            try? model.beginAnnotationInteraction(id: id)
        }
        overlayView.onAnnotationCreated = { [weak self] annotation in
            self?.model.addAnnotation(annotation)
            self?.refreshOverlay()
            if annotation.kind == .text {
                self?.overlayView.beginTextEditing(annotation.id)
            }
        }
        overlayView.onAnnotationChanged = { [weak self] id, rect, style in
            self?.model.updateAnnotation(id, rect: rect, style: style)
        }
        overlayView.onArrowGeometryChanged = { [weak self] annotation in
            self?.model.updateArrowGeometry(annotation)
        }
        overlayView.onAnnotationSelected = { [weak self] id in
            self?.model.selectAnnotation(id)
            self?.refreshOverlay()
        }
        overlayView.onStyleChanged = { [weak self] style in
            self?.model.applyStyle(style)
            self?.refreshOverlay()
        }
        overlayView.onTextEditingEnded = { [weak self] id, text, committed in
            self?.model.textEditingEnded(id: id, text: text, committed: committed)
            self?.refreshOverlay()
        }
        overlayView.onOutputAppearanceChanged = { [weak self] appearance in
            self?.model.session.setOutputAppearance(appearance)
        }
        overlayView.onInteractionEnded = { [weak self] in
            self?.model.endInteraction()
            self?.refreshOverlay()
        }
        overlayView.onInteractionCancelled = { [weak self] in
            self?.model.cancelInteraction()
            self?.refreshOverlay()
        }
        overlayView.onCopy = { [weak self] in self?.model.copy() }
        overlayView.onSave = { [weak self] in self?.model.save() }
        overlayView.onPin = { [weak self] in
            self?.model.pin { [weak self] in self?.close() }
        }
        overlayView.onZoomIn = { [weak self] in self?.zoomInAction() }
        overlayView.onZoomOut = { [weak self] in self?.zoomOutAction() }
        overlayView.onFitWidth = { [weak self] in self?.fitWidthAction() }
        overlayView.onUndo = { [weak self] in
            self?.model.undo()
            self?.refreshOverlay()
        }
        overlayView.onRedo = { [weak self] in
            self?.model.redo()
            self?.refreshOverlay()
        }
        overlayView.onDelete = { [weak self] in
            self?.model.deleteSelected()
            self?.refreshOverlay()
        }
        overlayView.onCancel = { [weak self] in self?.window?.close() }
        overlayView.setTool(.objectSelection)
        overlayView.frame = CGRect(origin: .zero, size: canvasHost.frame.size)
        refreshOverlay()
    }

    private func refreshOverlay() {
        overlayView.outputAppearance = model.session.outputAppearance
        model.outputAppearanceStore.appearance = model.session.outputAppearance
        overlayView.setAnnotations(
            model.session.annotations,
            selectedID: model.session.selectedAnnotationID
        )
        overlayView.canUndo = model.session.canUndo
        overlayView.canRedo = model.session.canRedo
        overlayView.canDelete = model.session.canDeleteSelectedAnnotation
        if let activeKind = overlayView.activeTool.annotationKind {
            model.activeStyleKind = activeKind
        } else {
            model.activeStyleKind = nil
        }
        if let selection = model.session.selection,
           let viewport = ScreenshotAnnotationViewport(
               pixelSize: model.pixelSize,
               viewSize: overlayView.bounds.size
           ) {
            overlayView.setSelection(viewport.viewRect(for: selection), notify: false)
            overlayView.setPixelDimensions(selection)
        } else {
            overlayView.setSelection(nil, notify: false)
            overlayView.setPixelDimensions(nil)
        }
        updateToolbarAnchor()
    }

    private func setZoom(_ value: CGFloat, preserveCenter: Bool = true) {
        let documentVisibleRect = scrollView.documentVisibleRect
        let center = CGPoint(
            x: documentVisibleRect.midX / max(canvasHost.bounds.width, 1),
            y: documentVisibleRect.midY / max(canvasHost.bounds.height, 1)
        )
        zoom = min(max(value, 0.1), 3)
        let size = CGSize(
            width: max(1, basePointSize.width * zoom),
            height: max(1, basePointSize.height * zoom)
        )
        canvasHost.frame = CGRect(origin: .zero, size: size)
        canvasHost.setFrameSize(size)
        overlayView.frame = canvasHost.bounds
        overlayView.pixelScale = CGFloat(model.image.width) / size.width
        refreshOverlay()
        if preserveCenter {
            let visibleSize = scrollView.contentView.bounds.size
            let origin = CGPoint(
                x: center.x * size.width - visibleSize.width / 2,
                y: center.y * size.height - visibleSize.height / 2
            )
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func fitWidth(animated: Bool) {
        let available = max(1, scrollView.contentView.bounds.width)
        setZoom(min(1, available / max(basePointSize.width, 1)), preserveCenter: false)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                scrollView.contentView.animator().setBoundsOrigin(.zero)
            }
        } else {
            scrollView.contentView.setBoundsOrigin(.zero)
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func updateToolbarAnchor() {
        let visibleRect = scrollView.documentVisibleRect
        guard visibleRect.height > 0 else { return }
        overlayView.toolbarAnchorRect = CGRect(
            x: visibleRect.minX,
            y: visibleRect.minY,
            width: visibleRect.width,
            height: visibleRect.height
        )
    }

    @objc private func zoomOutAction() {
        setZoom(zoom / 1.2)
    }

    @objc private func zoomInAction() {
        setZoom(zoom * 1.2)
    }

    @objc private func fitWidthAction() {
        fitWidth(animated: true)
    }

    @objc private func copyAction() {
        overlayView.commitActiveTextEditing()
        model.copy()
    }

    @objc private func saveAction() {
        overlayView.commitActiveTextEditing()
        model.save()
    }
}

extension LongScreenshotEditorWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        overlayView.commitActiveTextEditing()
        model.close()
        onClose?()
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
            self.boundsObserver = nil
        }
    }
}

@MainActor
private final class LongScreenshotEditorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class LongScreenshotCanvasHostView: NSView {
    let image: CGImage

    override var isFlipped: Bool { true }

    init(image: CGImage) {
        self.image = image
        super.init(frame: CGRect(
            x: 0,
            y: 0,
            width: image.width,
            height: image.height
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从归档创建长图画布")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSImage(cgImage: image, size: bounds.size).draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }
}
