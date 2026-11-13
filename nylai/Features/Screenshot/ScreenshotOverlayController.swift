import AppKit
import Observation
import ScreenCaptureKit

@MainActor
protocol ScreenshotPasting {
    func copy(_ image: CGImage) throws
}

@MainActor
final class PasteboardScreenshotPaster: ScreenshotPasting {
    func copy(_ image: CGImage) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([NSImage(cgImage: image, size: .zero)]) else {
            throw ScreenshotOutputError.clipboardWriteFailed
        }
    }
}

@MainActor
@Observable
final class ScreenshotOverlayController {
    private let displayCapturer: any ScreenCapturing
    private let windowCapturer: any WindowCapturing
    private let saver: any ScreenshotSaving
    private let paster: any ScreenshotPasting
    private let annotationStyleStore: ScreenshotAnnotationStyleStore
    private let outputAppearanceStore: ScreenshotOutputAppearanceStore
    private let pinnedImageManager: PinnedImageManager
    private let historyStore: ScreenshotHistoryStore?
    private let isHistoryEnabled: @MainActor () -> Bool
    private let startScrollCapture: @MainActor (ScrollCaptureStartRequest) -> Void
    private let presentError: @MainActor (Error) -> Void
    private var overlayWindow: ScreenshotOverlayWindow?
    private var overlayView: ScreenshotOverlayView?
    private var screen: NSScreen?
    private var activeOverlayFrame: CGRect?
    private var backgroundView: NSImageView?
    private var displayImage: CGImage?
    private var displaySource: ScreenshotImageSource?
    private var displayTargets: [ScreenshotCaptureTarget] = []
    private var sourceDisplayID: CGDirectDisplayID?
    private var displayTargetApplication: NSRunningApplication?
    private var targetApplication: NSRunningApplication?
    private var applicationToRestore: NSRunningApplication?
    private var isClosing = false
    private var outputTask: Task<Void, Never>?
    private var windowCaptureTask: Task<Void, Never>?
    private var styleInteractionID: UUID?
    private var styleCommitTask: Task<Void, Never>?
    private var newTextAnnotationIDs: Set<UUID> = []

    private(set) var session = ScreenshotSession()
    private(set) var isCapturing = false

    init(
        displayCapturer: any ScreenCapturing = ScreenCaptureService(),
        windowCapturer: any WindowCapturing = ScreenCaptureService(),
        saver: any ScreenshotSaving = PNGScreenshotSaver(),
        paster: any ScreenshotPasting = PasteboardScreenshotPaster(),
        annotationStyleStore: ScreenshotAnnotationStyleStore = ScreenshotAnnotationStyleStore(),
        outputAppearanceStore: ScreenshotOutputAppearanceStore = ScreenshotOutputAppearanceStore(),
        pinnedImageManager: PinnedImageManager = PinnedImageManager(),
        historyStore: ScreenshotHistoryStore? = nil,
        isHistoryEnabled: @escaping @MainActor () -> Bool = { false },
        startScrollCapture: @escaping @MainActor (ScrollCaptureStartRequest) -> Void = { _ in },
        presentError: @escaping @MainActor (Error) -> Void = ScreenshotErrorPresenter.show
    ) {
        self.displayCapturer = displayCapturer
        self.windowCapturer = windowCapturer
        self.saver = saver
        self.paster = paster
        self.annotationStyleStore = annotationStyleStore
        self.outputAppearanceStore = outputAppearanceStore
        self.pinnedImageManager = pinnedImageManager
        self.historyStore = historyStore
        self.isHistoryEnabled = isHistoryEnabled
        self.startScrollCapture = startScrollCapture
        self.presentError = presentError
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func begin() async {
        if session.isActive {
            NSApp.activate(ignoringOtherApps: true)
            overlayWindow?.makeKeyAndOrderFront(nil)
            return
        }
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }

        do {
            let foregroundApplication = NSWorkspace.shared.frontmostApplication
            let originalTarget = foregroundApplication.flatMap { application in
                application.processIdentifier == ProcessInfo.processInfo.processIdentifier
                    ? nil
                    : application
            }
            applicationToRestore = originalTarget
            displayTargetApplication = originalTarget
            targetApplication = originalTarget
            guard let targetScreen = screen(containing: NSEvent.mouseLocation) else {
                throw ScreenshotError.displayUnavailable
            }
            guard let resolvedDisplayID = displayID(for: targetScreen) else {
                throw ScreenshotError.displayUnavailable
            }
            let image = try await displayCapturer.captureDisplay(resolvedDisplayID)
            try Task.checkCancellation()
            screen = targetScreen
            activeOverlayFrame = targetScreen.frame
            let scale = CGFloat(image.width) / targetScreen.frame.width
            let geometry = try ScreenshotSourceGeometry(
                kind: .display(resolvedDisplayID),
                globalFrame: targetScreen.frame,
                pointPixelScale: scale,
                pixelSize: PixelSize(width: image.width, height: image.height)
            )
            let source = try ScreenshotImageSource(image: image, geometry: geometry)
            session.begin(with: source)
            displayTargets = [
                .display(displayID: resolvedDisplayID, frame: targetScreen.frame),
            ]
            session.setTargets(displayTargets)
            presentOverlay(
                on: targetScreen,
                image: image,
                pixelScale: scale
            )
            displayImage = image
            displaySource = source
            sourceDisplayID = resolvedDisplayID
            let candidates = (try? await windowCapturer.windowCandidates()) ?? []
            let windowTargets: [ScreenshotCaptureTarget] = candidates.filter { candidate in
                targetScreen.frame.contains(candidate.frame)
            }.map(ScreenshotCaptureTarget.window)
            let targets = windowTargets + [
                .display(displayID: resolvedDisplayID, frame: targetScreen.frame),
            ]
            guard session.isActive else { return }
            displayTargets = targets
            session.setTargets(targets)
            refreshTargetAtCurrentPointer()
        } catch is CancellationError {
            close()
        } catch {
            close()
            presentError(error)
        }
    }

    func close() {
        guard session.isActive || overlayWindow != nil else { return }
        outputTask?.cancel()
        outputTask = nil
        styleCommitTask?.cancel()
        styleCommitTask = nil
        styleInteractionID = nil
        windowCaptureTask?.cancel()
        windowCaptureTask = nil
        session.cancel()
        closeOverlay()
        restorePreviousApplication()
    }

    func closePinnedImages() {
        pinnedImageManager.closeAll()
    }

    private func presentOverlay(
        on screen: NSScreen,
        image: CGImage,
        pixelScale: CGFloat
    ) {
        closeOverlay()

        self.screen = screen
        let size = screen.frame.size
        activeOverlayFrame = screen.frame
        let window = ScreenshotOverlayWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isOpaque = false
        window.backgroundColor = .black
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.acceptsMouseMovedEvents = true
        window.setFrame(screen.frame, display: false)
        window.onCancel = { [weak self] in self?.cancelFromKeyboard() }

        let imageView = NSImageView(frame: CGRect(origin: .zero, size: size))
        imageView.image = NSImage(cgImage: image, size: size)
        imageView.imageScaling = .scaleAxesIndependently

        let view = ScreenshotOverlayView(frame: CGRect(origin: .zero, size: size))
        view.onSelectionChanged = { [weak self] rect in self?.handleSelectionChanged(rect) }
        view.onSelectionCommitted = { [weak self] rect in self?.handleSelectionCommitted(rect) }
        view.onInteractionBegan = { [weak self] in
            self?.cancelPendingWindowCapture()
            try? self?.session.beginInteraction(.selectingRegion)
        }
        view.onAnnotationInteractionBegan = { [weak self] annotationID in
            guard let self else { return }
            let interaction = annotationID.map(ScreenshotSession.Interaction.annotation)
                ?? .creatingAnnotation
            try? session.beginInteraction(interaction)
        }
        view.onAnnotationCreated = { [weak self] incomingAnnotation in
            guard let self else { return }
            var annotation = incomingAnnotation
            if annotation.kind == .step {
                annotation.stepNumber = nextStepNumber()
            }
            try? session.addAnnotation(annotation)
            if annotation.kind == .text {
                newTextAnnotationIDs.insert(annotation.id)
            }
            refreshOverlayState()
            if annotation.kind == .text {
                overlayView?.beginTextEditing(annotation.id)
            }
        }
        view.onAnnotationChanged = { [weak self] id, rect, style in
            guard let self else { return }
            try? session.updateAnnotation(id, rect: rect, style: style)
        }
        view.onArrowGeometryChanged = { [weak self] annotation in
            guard let self else { return }
            try? session.updateArrowGeometry(annotation)
            refreshOverlayState()
        }
        view.onAnnotationSelected = { [weak self] id in
            self?.finishStyleInteraction()
            self?.session.selectAnnotation(id)
            self?.refreshOverlayState()
        }
        view.onStyleChanged = { [weak self] style in
            self?.applyAnnotationStyle(style)
        }
        view.onTextEditingEnded = { [weak self] id, text, committed in
            self?.finishTextEditing(id: id, text: text, committed: committed)
        }
        view.onOutputAppearanceChanged = { [weak self] appearance in
            self?.session.setOutputAppearance(appearance)
        }
        view.onInteractionEnded = { [weak self] in
            self?.session.endInteraction()
            self?.refreshOverlayState()
        }
        view.onInteractionCancelled = { [weak self] in
            self?.session.cancelInteraction()
            self?.refreshOverlayState()
        }
        view.onTargetHover = { [weak self] point in self?.highlightTarget(at: point) }
        view.onTargetPick = { [weak self] point in self?.pickTarget(at: point) }
        view.onReselect = { [weak self] in self?.returnToDisplaySelection() }
        view.onScrollCapture = { [weak self] in self?.beginScrollCapture() }
        view.onCopy = { [weak self] in self?.copySelection() }
        view.onRecognizeText = { [weak self] layout in
            self?.runOutput { image in
                try await ScreenshotTextRecognition.review(image, layout: layout)
                return true
            }
        }
        view.onSave = { [weak self] in self?.saveSelection() }
        view.onPin = { [weak self] in self?.pinSelection() }
        view.onUndo = { [weak self] in
            self?.session.undo()
            self?.refreshOverlayState()
        }
        view.onRedo = { [weak self] in
            self?.session.redo()
            self?.refreshOverlayState()
        }
        view.onDelete = { [weak self] in
            self?.session.deleteSelectedAnnotation()
            self?.refreshOverlayState()
        }
        view.onCancel = { [weak self] in self?.cancelFromKeyboard() }
        view.pixelScale = pixelScale
        view.showsColorInspector = true
        view.sourcePixelSize = session.source?.geometry.pixelSize
        view.sourceImage = image
        session.setOutputAppearance(outputAppearanceStore.appearance)
        view.outputAppearance = session.outputAppearance
        for kind in ScreenshotAnnotationKind.allCases {
            view.setDefaultStyle(annotationStyleStore.style(for: kind), for: kind)
        }

        window.contentView = imageView
        imageView.addSubview(view)
        overlayWindow = window
        overlayView = view
        backgroundView = imageView

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        let pointer = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if view.bounds.contains(pointer) {
            view.updatePointerLocation(pointer)
        }
        highlightTarget(at: pointer)
        refreshOverlayState()
    }

    private func highlightTarget(at localPoint: CGPoint?) {
        guard session.phase == .selecting, let localPoint, let screen else {
            overlayView?.updatePointerLocation(nil)
            overlayView?.highlightedTargetRect = nil
            overlayView?.highlightedTargetLabel = nil
            overlayView?.highlightedTargetIsWindow = false
            return
        }
        overlayView?.updatePointerLocation(localPoint)
        let globalPoint = CGPoint(
            x: screen.frame.minX + localPoint.x,
            y: screen.frame.maxY - localPoint.y
        )
        guard session.phase == .selecting else {
            overlayView?.highlightedTargetRect = nil
            overlayView?.highlightedTargetLabel = nil
            overlayView?.highlightedTargetIsWindow = false
            return
        }
        let target = session.target(at: globalPoint)
            ?? session.targets.first { target in
                if case .display = target { return true }
                return false
            }
        guard let target else {
            overlayView?.highlightedTargetRect = nil
            overlayView?.highlightedTargetLabel = nil
            overlayView?.highlightedTargetIsWindow = false
            return
        }
        overlayView?.highlightedTargetRect = CGRect(
            x: target.frame.minX - screen.frame.minX,
            y: screen.frame.maxY - target.frame.maxY,
            width: target.frame.width,
            height: target.frame.height
        )
        overlayView?.highlightedTargetLabel = switch target {
        case .display:
            "整屏"
        case .window(let candidate):
            candidate.applicationName ?? candidate.title ?? "窗口"
        }
        overlayView?.highlightedTargetIsWindow = if case .window = target { true } else { false }
    }

    private func pickTarget(at localPoint: CGPoint) {
        guard let screen, windowCaptureTask == nil else { return }
        guard session.phase == .selecting else { return }
        let globalPoint = CGPoint(
            x: screen.frame.minX + localPoint.x,
            y: screen.frame.maxY - localPoint.y
        )
        guard let target = session.target(at: globalPoint) else {
            return
        }
        guard case .window(let candidate) = target else {
            selectDisplayTarget()
            return
        }
        windowCaptureTask = Task { [weak self] in
            guard let self else { return }
            defer { windowCaptureTask = nil }
            do {
                let image = try await windowCapturer.captureWindow(candidate.windowID)
                try Task.checkCancellation()
                let pointScale = CGFloat(image.width) / candidate.frame.width
                let geometry = try ScreenshotSourceGeometry(
                    kind: .window(candidate.windowID),
                    globalFrame: candidate.frame,
                    pointPixelScale: pointScale,
                    pixelSize: PixelSize(width: image.width, height: image.height)
                )
                let source = try ScreenshotImageSource(image: image, geometry: geometry)
                try session.chooseWindow(candidate.windowID, source: source)
                if let bundleIdentifier = candidate.bundleIdentifier,
                   let target = NSRunningApplication
                       .runningApplications(withBundleIdentifier: bundleIdentifier)
                       .first(where: {
                           $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                       }) {
                    targetApplication = target
                }
                activeOverlayFrame = candidate.frame
                overlayWindow?.setFrame(candidate.frame, display: true)
                backgroundView?.frame = CGRect(origin: .zero, size: candidate.frame.size)
                backgroundView?.image = NSImage(cgImage: image, size: candidate.frame.size)
                backgroundView?.imageScaling = .scaleAxesIndependently
                overlayView?.frame = CGRect(origin: .zero, size: candidate.frame.size)
                overlayView?.pixelScale = pointScale
                overlayView?.sourcePixelSize = source.geometry.pixelSize
                overlayView?.sourceImage = image
                overlayView?.isWindowSource = true
                overlayView?.highlightedTargetRect = nil
                overlayView?.highlightedTargetLabel = nil
                overlayView?.highlightedTargetIsWindow = false
                overlayView?.setAnnotations([], selectedID: nil)
                overlayView?.setTool(.selection)
                overlayView?.setSelection(
                    CGRect(origin: .zero, size: candidate.frame.size),
                    notify: false
                )
                overlayView?.setPixelDimensions(session.selection)
                refreshOverlayState()
                overlayWindow?.makeKeyAndOrderFront(nil)
            } catch is CancellationError {
                return
            } catch {
                presentError(error)
            }
        }
    }

    private func cancelPendingWindowCapture() {
        windowCaptureTask?.cancel()
        windowCaptureTask = nil
    }

    private func applyAnnotationStyle(_ style: ScreenshotAnnotationStyle) {
        if let selected = session.selectedAnnotation {
            let validated = style.validated(for: selected.kind)
            beginStyleInteractionIfNeeded(for: selected.id)
            try? session.updateAnnotationStyle(selected.id, style: validated)
            annotationStyleStore.setStyle(validated, for: selected.kind)
            overlayView?.setDefaultStyle(validated, for: selected.kind)
            refreshOverlayState()
            scheduleStyleCommit()
            return
        }
        guard let kind = overlayView?.activeTool.annotationKind else { return }
        let validated = style.validated(for: kind)
        annotationStyleStore.setStyle(validated, for: kind)
        overlayView?.setDefaultStyle(validated, for: kind)
    }

    private func nextStepNumber() -> Int {
        ScreenshotStepNumbering.next(after: session.annotations)
    }

    private func finishTextEditing(id: UUID, text: String, committed: Bool) {
        let wasNew = newTextAnnotationIDs.remove(id) != nil
        if committed, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? session.updateAnnotationText(id, text: text)
        } else if committed || wasNew {
            session.deleteAnnotation(id)
        }
        refreshOverlayState()
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
        refreshOverlayState()
    }

    private func selectDisplayTarget() {
        guard outputTask == nil,
              windowCaptureTask == nil,
              session.interaction == nil,
              session.phase == .selecting,
              let source = session.source,
              let activeOverlayFrame,
              let overlayView else {
            return
        }
        let fullSelection = PixelRect(
            x: 0,
            y: 0,
            width: source.geometry.pixelSize.width,
            height: source.geometry.pixelSize.height
        )
        do {
            try session.select(pixelRect: fullSelection)
        } catch {
            return
        }
        overlayView.highlightedTargetRect = nil
        overlayView.highlightedTargetLabel = nil
        overlayView.highlightedTargetIsWindow = false
        overlayView.setSelection(
            CGRect(origin: .zero, size: activeOverlayFrame.size),
            notify: false
        )
        overlayView.setPixelDimensions(session.selection)
        refreshOverlayState()
        overlayWindow?.makeFirstResponder(overlayView)
    }

    private func refreshTargetAtCurrentPointer() {
        guard let screen, overlayWindow != nil, session.phase == .selecting else { return }
        let mouse = NSEvent.mouseLocation
        let localPoint = CGPoint(
            x: mouse.x - screen.frame.minX,
            y: screen.frame.maxY - mouse.y
        )
        highlightTarget(at: localPoint)
    }

    private func refreshOverlayState() {
        guard let overlayView else { return }
        overlayView.sourcePixelSize = session.source?.geometry.pixelSize
        overlayView.outputAppearance = session.outputAppearance
        outputAppearanceStore.appearance = session.outputAppearance
        overlayView.setAnnotations(
            session.annotations,
            selectedID: session.selectedAnnotationID
        )
        overlayView.canUndo = session.canUndo
        overlayView.canRedo = session.canRedo
        overlayView.canDelete = session.canDeleteSelectedAnnotation

        guard let selection = session.selection,
              let source = session.source,
              let activeOverlayFrame else {
            overlayView.setTool(.selection)
            overlayView.setSelection(nil, notify: false)
            overlayView.setPixelDimensions(nil)
            return
        }
        let globalRect = source.geometry.mapper.globalScreenRect(fromPixelRect: selection)
        let appKitLocalRect = ScreenshotCoordinateMapper.appKitLocalRect(
            fromGlobalScreenRect: globalRect,
            in: activeOverlayFrame
        )
        let flippedRect = CGRect(
            x: appKitLocalRect.minX,
            y: activeOverlayFrame.height - appKitLocalRect.maxY,
            width: appKitLocalRect.width,
            height: appKitLocalRect.height
        )
        overlayView.setSelection(flippedRect, notify: false)
        overlayView.setPixelDimensions(selection)
    }

    private func returnToDisplaySelection() {
        guard outputTask == nil,
              windowCaptureTask == nil,
              let screen,
              let displayImage,
              let displaySource else {
            return
        }
        session.begin(with: displaySource)
        session.setTargets(displayTargets)
        targetApplication = displayTargetApplication
        activeOverlayFrame = screen.frame
        overlayWindow?.setFrame(screen.frame, display: true)
        backgroundView?.frame = CGRect(origin: .zero, size: screen.frame.size)
        backgroundView?.image = NSImage(cgImage: displayImage, size: screen.frame.size)
        backgroundView?.imageScaling = .scaleAxesIndependently
        overlayView?.frame = CGRect(origin: .zero, size: screen.frame.size)
        overlayView?.pixelScale = displaySource.geometry.pointPixelScale
        overlayView?.sourcePixelSize = displaySource.geometry.pixelSize
        overlayView?.sourceImage = displayImage
        overlayView?.isWindowSource = false
        overlayView?.highlightedTargetRect = nil
        overlayView?.highlightedTargetLabel = nil
        overlayView?.highlightedTargetIsWindow = false
        overlayView?.setTool(.selection)
        overlayView?.setSelection(nil, notify: false)
        refreshOverlayState()
        overlayWindow?.makeKeyAndOrderFront(nil)
        overlayWindow?.makeFirstResponder(overlayView)
    }

    private func copySelection() {
        runOutput { [self] image in
            try paster.copy(image)
            return true
        }
    }

    private func saveSelection() {
        runOutput(lowersOverlay: true) { [self] image in
            let url = try await saver.save(image)
            return url != nil
        }
    }

    private func pinSelection() {
        runOutput { [self] image in
            pinnedImageManager.pin(image, restoreApplication: applicationToRestore)
            restorePreviousApplication()
            return true
        }
    }

    private func beginScrollCapture() {
        guard outputTask == nil,
              windowCaptureTask == nil,
              session.phase == .editing,
              let selection = session.selection,
              let source = session.source,
              let screen,
              let displayID = sourceDisplayID else {
            return
        }
        let selectionGlobalRect = source.geometry.mapper.globalScreenRect(fromPixelRect: selection)
        let visibleSelection = selectionGlobalRect.intersection(screen.frame)
        guard !visibleSelection.isNull, !visibleSelection.isEmpty else {
            return
        }
        let request = ScrollCaptureStartRequest(
            displayID: displayID,
            displayFrame: screen.frame,
            selectionGlobalRect: visibleSelection,
            pointPixelScale: source.geometry.pointPixelScale,
            targetApplication: scrollCaptureTargetApplication(for: visibleSelection)
        )
        close()
        startScrollCapture(request)
    }

    private func scrollCaptureTargetApplication(
        for selectionGlobalRect: CGRect
    ) -> NSRunningApplication? {
        let center = CGPoint(
            x: selectionGlobalRect.midX,
            y: selectionGlobalRect.midY
        )
        if case .window(let candidate) = session.target(at: center),
           let bundleIdentifier = candidate.bundleIdentifier,
           let application = NSRunningApplication
               .runningApplications(withBundleIdentifier: bundleIdentifier)
               .first(where: {
                   $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
               }) {
            return application
        }
        if let targetApplication {
            return targetApplication
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            return frontmost
        }
        return displayTargetApplication
    }

    private func runOutput(
        lowersOverlay: Bool = false,
        _ operation: @escaping @MainActor (CGImage) async throws -> Bool
    ) {
        overlayView?.commitActiveTextEditing()
        guard outputTask == nil, session.phase == .editing, let selection = session.selection,
              let source = session.source else {
            return
        }
        do {
            try session.beginOutput()
        } catch {
            return
        }
        overlayView?.isOutputting = true
        guard let rendered = try? ScreenshotOutputRenderer.render(
            source: source,
            selection: selection,
            annotations: session.annotations,
            appearance: outputAppearanceStore.appearance
        ) else {
            session.outputCancelled()
            overlayView?.isOutputting = false
            presentError(ScreenshotOutputError.imageRenderingFailed)
            return
        }
        if lowersOverlay {
            // 保存面板必须显示在冻结覆盖层之上。
            overlayWindow?.level = NSWindow.Level(
                rawValue: NSWindow.Level.modalPanel.rawValue - 1
            )
        }
        outputTask = Task { [weak self] in
            guard let self else { return }
            defer {
                outputTask = nil
                overlayView?.isOutputting = false
                if lowersOverlay, session.phase != .ended {
                    overlayWindow?.level = .screenSaver
                    overlayWindow?.makeKeyAndOrderFront(nil)
                }
            }
            do {
                guard try await operation(rendered) else {
                    session.outputCancelled()
                    return
                }
                try Task.checkCancellation()
                recordHistory(rendered)
                if session.phase == .outputting {
                    session.outputSucceeded()
                    closeOverlay()
                }
            } catch is CancellationError {
                session.outputCancelled()
            } catch {
                session.outputCancelled()
                presentError(error)
            }
        }
    }

    private func recordHistory(_ image: CGImage) {
        guard isHistoryEnabled(), let historyStore else { return }
        do {
            try historyStore.add(image)
        } catch {
            presentError(error)
        }
    }

    private func handleSelectionChanged(_ localRect: CGRect?) {
        guard session.source != nil, let activeOverlayFrame else { return }
        guard let localRect, !localRect.isEmpty else {
            session.clearSelection()
            overlayView?.setPixelDimensions(nil)
            return
        }
        // 覆盖层使用翻转坐标，几何模型统一使用 AppKit 左下角原点。
        let appKitLocalRect = CGRect(
            x: localRect.minX,
            y: activeOverlayFrame.height - localRect.maxY,
            width: localRect.width,
            height: localRect.height
        )
        let globalRect = ScreenshotCoordinateMapper.globalScreenRect(
            fromAppKitLocalRect: appKitLocalRect,
            in: activeOverlayFrame
        )
        do {
            try session.select(globalScreenRect: globalRect)
            overlayView?.setPixelDimensions(session.selection)
        } catch {
            session.clearSelection()
            overlayView?.setPixelDimensions(nil)
        }
    }

    private func handleSelectionCommitted(_ localRect: CGRect?) {
        handleSelectionChanged(localRect)
    }

    private func cancelFromKeyboard() {
        if overlayView?.cancelCurrentDrag() == true {
            return
        }
        close()
    }

    private func restorePreviousApplication() {
        guard let application = applicationToRestore else { return }
        applicationToRestore = nil
        guard !application.isTerminated,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }
        application.activate(options: [.activateAllWindows])
    }

    @objc private func applicationDidResignActive() {
        close()
    }

    private func closeOverlay() {
        guard !isClosing else { return }
        isClosing = true
        overlayWindow?.orderOut(nil)
        overlayWindow?.contentView = nil
        overlayWindow = nil
        overlayView = nil
        backgroundView = nil
        screen = nil
        activeOverlayFrame = nil
        displayImage = nil
        displaySource = nil
        displayTargets = []
        sourceDisplayID = nil
        displayTargetApplication = nil
        targetApplication = nil
        isClosing = false
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}

enum ScreenshotOutputError: LocalizedError, Equatable {
    case clipboardWriteFailed
    case invalidSelection
    case imageRenderingFailed

    var errorDescription: String? {
        switch self {
        case .clipboardWriteFailed:
            "无法将截图写入剪贴板，请重试。"
        case .invalidSelection:
            "截图选区无效。"
        case .imageRenderingFailed:
            "无法合成截图标注，请重试。"
        }
    }
}
