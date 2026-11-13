import AppKit
import Observation
import ScreenCaptureKit

@MainActor
protocol ScrollRegionSelectionSession: AnyObject {
    var isVisible: Bool { get }
    func show()
    func close()
}

@MainActor
protocol ScrollRegionSelecting: AnyObject {
    func present(
        screenFrame: CGRect,
        image: CGImage,
        onSelection: @escaping (CGRect) -> Void,
        onCancel: @escaping () -> Void
    ) throws -> any ScrollRegionSelectionSession
}

struct ScrollCaptureDisplayTarget: Equatable {
    let displayID: CGDirectDisplayID
    let frame: CGRect
}

struct ScrollCaptureSelection: Equatable {
    let pixelRect: PixelRect
    let pointPixelScale: CGFloat
}

struct ScrollCaptureStartRequest {
    let displayID: CGDirectDisplayID
    let displayFrame: CGRect
    let selectionGlobalRect: CGRect
    let pointPixelScale: CGFloat
    let targetApplication: NSRunningApplication?
}

enum ScrollPreviewPosition: Equatable {
    case right
    case left
    case above
    case below
    case inside
}

struct ScrollPreviewLayout: Equatable {
    let frame: CGRect
    let position: ScrollPreviewPosition
}

enum ScrollPreviewImageFit {
    static func rect(imageSize: CGSize, in container: CGRect) -> CGRect {
        guard imageSize.width > 0,
              imageSize.height > 0,
              container.width > 0,
              container.height > 0 else {
            return .zero
        }
        let scale = min(
            container.width / imageSize.width,
            container.height / imageSize.height
        )
        let size = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        return CGRect(
            x: container.midX - size.width / 2,
            y: container.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

enum ScrollPreviewLayoutSolver {
    static let preferredSize = CGSize(width: 216, height: 318)
    static let minimumSize = CGSize(width: 132, height: 178)
    static let margin: CGFloat = 12
    static let gap: CGFloat = 12
    static let insideInset: CGFloat = 12

    static func layout(
        selection: CGRect,
        screenFrame: CGRect,
        preferredSize: CGSize = preferredSize,
        avoiding avoidedRect: CGRect? = nil,
        reserving reservedRect: CGRect? = nil
    ) -> ScrollPreviewLayout {
        let safeScreen = screenFrame.insetBy(dx: margin, dy: margin)
        let areas: [(ScrollPreviewPosition, CGRect)] = [
            (.left, CGRect(x: safeScreen.minX, y: safeScreen.minY,
                           width: max(0, selection.minX - gap - safeScreen.minX), height: safeScreen.height)),
            (.right, CGRect(x: selection.maxX + gap, y: safeScreen.minY,
                            width: max(0, safeScreen.maxX - selection.maxX - gap), height: safeScreen.height)),
            (.below, CGRect(x: safeScreen.minX, y: safeScreen.minY, width: safeScreen.width,
                            height: max(0, selection.minY - gap - safeScreen.minY))),
            (.above, CGRect(x: safeScreen.minX, y: selection.maxY + gap, width: safeScreen.width,
                            height: max(0, safeScreen.maxY - selection.maxY - gap))),
        ]
        func excluding(_ obstacle: CGRect?, from area: CGRect) -> [CGRect] {
            guard let obstacle else { return [area] }
            let overlap = area.intersection(obstacle.insetBy(dx: -gap / 2, dy: -gap / 2))
            guard !overlap.isNull, !overlap.isEmpty else { return [area] }
            return [
                CGRect(x: area.minX, y: area.minY, width: overlap.minX - area.minX, height: area.height),
                CGRect(x: overlap.maxX, y: area.minY, width: area.maxX - overlap.maxX, height: area.height),
                CGRect(x: area.minX, y: area.minY, width: area.width, height: overlap.minY - area.minY),
                CGRect(x: area.minX, y: overlap.maxY, width: area.width, height: area.maxY - overlap.maxY),
            ]
        }

        for avoidTarget in [false, true] {
            for (position, area) in areas {
                let rooms = excluding(reservedRect, from: area).flatMap {
                    excluding(avoidTarget ? avoidedRect : nil, from: $0)
                }
                let frames = rooms.compactMap { room -> CGRect? in
                    let width = min(preferredSize.width, room.width)
                    let height = min(preferredSize.height, room.height)
                    guard width >= minimumSize.width, height >= minimumSize.height else { return nil }
                    let idealX = position == .right ? room.minX
                        : position == .left ? room.maxX - width : selection.midX - width / 2
                    let idealY = position == .above ? room.minY
                        : position == .below ? room.maxY - height : selection.midY - height / 2
                    return CGRect(x: min(max(idealX, room.minX), room.maxX - width),
                                  y: min(max(idealY, room.minY), room.maxY - height),
                                  width: width, height: height)
                }
                if let frame = frames.max(by: { $0.width * $0.height < $1.width * $1.height }) {
                    return ScrollPreviewLayout(frame: frame, position: position)
                }
            }
        }

        let available = selection.insetBy(dx: insideInset, dy: insideInset)
        let width = max(1, min(preferredSize.width, available.width))
        let height = max(1, min(preferredSize.height, available.height))
        let frame = CGRect(
            x: reservedRect == nil ? selection.maxX - insideInset - width : selection.minX + insideInset,
            y: selection.maxY - insideInset - height,
            width: width,
            height: height
        )
        return ScrollPreviewLayout(frame: frame, position: .inside)
    }
}

@MainActor
@Observable
final class ScrollCaptureController {
    enum Phase: Equatable {
        case idle
        case selecting
        case preparing
        case ready
        case running
        case paused
        case finished
    }

    private let displayCapturer: any ScreenCapturing
    private let displayTarget: @MainActor (CGPoint) -> ScrollCaptureDisplayTarget?
    private let regionSelector: any ScrollRegionSelecting
    private let openEditor: @MainActor (CGImage, CGFloat, CGRect?) -> Void
    private let presentError: @MainActor (Error) -> Void
    private let paster: any ScreenshotPasting
    private let saver: any ScreenshotSaving
    private enum Output: Equatable { case edit, copy, save }
    private var selectionSession: (any ScrollRegionSelectionSession)?
    private var selectionCancellationTask: Task<Void, Never>?
    private var completionWindow: ScrollCaptureCompletionWindow?
    private var frameTask: Task<Void, Never>?
    private var targetApplication: NSRunningApplication?
    private var displayID: CGDirectDisplayID?
    private var displayFrame = CGRect.zero
    private var selectionPixelRect: PixelRect?
    private var selectionGlobalRect: CGRect?
    private var pixelScale: CGFloat = 1
    private var stitcher: ScrollCaptureStitcher?
    private var selectionOutlineWindow: ScrollCaptureHUDWindow?
    private var captureWindowFrame: CGRect?
    private var isClosing = false
    private var consecutiveUnmatchedFrames = 0
    private var captureInFlight = false
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?

    private(set) var phase = Phase.idle
    private(set) var selection: ScrollCaptureSelection?
    private(set) var previewImage: CGImage?
    private(set) var previewRevision = 0
    private(set) var frameCount = 0
    private(set) var outputHeight = 0
    private(set) var statusText = ""
    private(set) var lastFailure: String?

    var isActive: Bool {
        phase != .idle && phase != .finished
    }

    init(
        displayCapturer: any ScreenCapturing = ScreenCaptureService(),
        displayTarget: @escaping @MainActor (CGPoint) -> ScrollCaptureDisplayTarget? = { _ in
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                    ?? NSScreen.main,
                  let displayID = ScrollCaptureController.displayID(for: screen) else {
                return nil
            }
            return ScrollCaptureDisplayTarget(displayID: displayID, frame: screen.frame)
        },
        regionSelector: any ScrollRegionSelecting = ScrollRegionSelectionPresenter.shared,
        openEditor: @escaping @MainActor (CGImage, CGFloat, CGRect?) -> Void,
        paster: any ScreenshotPasting = PasteboardScreenshotPaster(),
        saver: any ScreenshotSaving = PNGScreenshotSaver(),
        presentError: @escaping @MainActor (Error) -> Void = ScreenshotErrorPresenter.show
    ) {
        self.displayCapturer = displayCapturer
        self.displayTarget = displayTarget
        self.regionSelector = regionSelector
        self.openEditor = openEditor
        self.paster = paster
        self.saver = saver
        self.presentError = presentError
    }

    func begin() async {
        guard phase == .idle else { return }
        targetApplication = NSWorkspace.shared.frontmostApplication
        guard let target = displayTarget(NSEvent.mouseLocation) else {
            presentError(ScreenshotError.displayUnavailable)
            return
        }

        phase = .selecting
        statusText = L10n.shared.string("拖动选择要滚动的内容区域")
        do {
            let image = try await displayCapturer.captureDisplayExcludingOwnApplication(
                target.displayID
            )
            try Task.checkCancellation()
            guard phase == .selecting else { return }
            let scale = CGFloat(image.width) / target.frame.width
            let session = try regionSelector.present(
                screenFrame: target.frame,
                image: image,
                onSelection: { [weak self] localRect in
                    self?.selectRegion(localRect)
                },
                onCancel: { [weak self] in
                    self?.cancel()
                }
            )
            selectionSession = session
            session.show()
            selectionCancellationTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled, let self else { return }
                    guard self.phase == .selecting else {
                        self.selectionCancellationTask = nil
                        return
                    }
                    if !session.isVisible {
                        self.cancel()
                        return
                    }
                }
            }
            self.displayID = target.displayID
            displayFrame = target.frame
            pixelScale = scale
        } catch is CancellationError {
            cancel()
        } catch {
            cancel()
            presentError(error)
        }
    }

    func begin(
        with request: ScrollCaptureStartRequest,
        automaticCapture: Bool = true
    ) {
        guard phase == .idle else { return }
        phase = .preparing
        statusText = L10n.shared.string("准备滚动截图…")
        targetApplication = request.targetApplication
        displayID = request.displayID
        displayFrame = request.displayFrame
        pixelScale = request.pointPixelScale
        selectionGlobalRect = request.selectionGlobalRect

        do {
            let selection = try ScreenshotCoordinateMapper(
                geometry: try ScreenshotSourceGeometry(
                    kind: .display(request.displayID),
                    globalFrame: request.displayFrame,
                    pointPixelScale: request.pointPixelScale,
                    pixelSize: try PixelSize(
                        width: max(1, Int((request.displayFrame.width * request.pointPixelScale).rounded())),
                        height: max(1, Int((request.displayFrame.height * request.pointPixelScale).rounded()))
                    )
                )
            ).pixelRect(fromGlobalScreenRect: request.selectionGlobalRect)
            selectionPixelRect = selection
            self.selection = ScrollCaptureSelection(
                pixelRect: selection,
                pointPixelScale: request.pointPixelScale
            )
            stitcher = ScrollCaptureStitcher()
            frameCount = 0
            outputHeight = 0
            consecutiveUnmatchedFrames = 0
            previewImage = nil
            previewRevision = 0
            captureWindowFrame = targetWindowFrame(request)
            let previewLayout = ScrollPreviewLayoutSolver.layout(
                selection: request.selectionGlobalRect,
                screenFrame: request.displayFrame,
                avoiding: captureWindowFrame,
                reserving: ScrollCaptureCompletionWindow.placement(
                    selection: request.selectionGlobalRect, screen: request.displayFrame
                )
            )
            showHUD(
                selectionGlobalRect: request.selectionGlobalRect,
                screenFrame: request.displayFrame,
                previewLayout: previewLayout
            )
            showCompletionControl(
                selectionGlobalRect: request.selectionGlobalRect,
                screenFrame: request.displayFrame
            )
            restoreTargetApplication()
            phase = .ready
            statusText = L10n.shared.string("请缓慢滚动画面的内容")
            updateStatus()
            startOrResume(automaticCapture: automaticCapture)
        } catch {
            cancel()
            presentError(error)
        }
    }

    func startOrResume(automaticCapture: Bool = true) {
        guard phase == .ready || phase == .paused else { return }
        lastFailure = nil
        consecutiveUnmatchedFrames = 0
        phase = .running
        statusText = L10n.shared.string("正在等待页面滚动…")
        updateStatus()
        if automaticCapture {
            captureNextFrameSoon()
        }
    }

    @discardableResult
    func captureFrameNow() async -> ScrollFrameAppend? {
        guard phase == .running else { return nil }
        return await captureNextFrame()
    }

    func stopAndOpenEditor() async {
        await finishCapture(.edit)
    }

    private func finishCapture(_ output: Output) async {
        guard phase == .running || phase == .paused else { return }
        frameTask?.cancel()
        frameTask = nil
        phase = .preparing
        updateStatus()
        do {
            guard let result = try await stitcher?.finish() else {
                throw ScrollCaptureError.noFrames
            }
            guard phase == .preparing else { return }
            switch output {
            case .edit: break
            case .copy: try paster.copy(result.image)
            case .save:
                completionWindow?.orderOut(nil)
                selectionOutlineWindow?.orderOut(nil)
                guard try await saver.save(result.image) != nil else {
                    guard phase == .preparing else { return }
                    phase = .paused
                    statusText = L10n.shared.string("已暂停")
                    selectionOutlineWindow?.orderFrontRegardless()
                    completionWindow?.orderFrontRegardless()
                    updateStatus()
                    return
                }
            }
            guard phase == .preparing else { return }
            let scale = pixelScale
            let selectionRect = selectionGlobalRect
            closeWindows()
            targetApplication = nil
            phase = .finished
            if output == .edit { openEditor(result.image, scale, selectionRect) }
            phase = .idle
        } catch {
            guard phase == .preparing else { return }
            lastFailure = error.localizedDescription
            statusText = error.localizedDescription
            phase = .paused
            selectionOutlineWindow?.orderFrontRegardless()
            completionWindow?.orderFrontRegardless()
            updateStatus()
            presentError(error)
        }
    }

    func cancel() {
        guard !isClosing else { return }
        isClosing = true
        frameTask?.cancel()
        frameTask = nil
        selectionCancellationTask?.cancel()
        selectionCancellationTask = nil
        closeWindows()
        restoreTargetApplication()
        targetApplication = nil
        selectionPixelRect = nil
        selection = nil
        stitcher = nil
        displayID = nil
        selectionGlobalRect = nil
        captureWindowFrame = nil
        previewImage = nil
        previewRevision = 0
        frameCount = 0
        outputHeight = 0
        consecutiveUnmatchedFrames = 0
        statusText = ""
        lastFailure = nil
        phase = .idle
        isClosing = false
    }

    func close() {
        cancel()
    }

    func selectRegion(_ localRect: CGRect) {
        guard phase == .selecting,
              let displayID,
              let selection = try? ScreenshotCoordinateMapper(
                  geometry: try ScreenshotSourceGeometry(
                      kind: .display(displayID),
                      globalFrame: displayFrame,
                      pointPixelScale: pixelScale,
                      pixelSize: try PixelSize(
                          width: max(1, Int((displayFrame.width * pixelScale).rounded())),
                          height: max(1, Int((displayFrame.height * pixelScale).rounded()))
                      )
                  )
              ).pixelRect(fromGlobalScreenRect: CGRect(
                  x: displayFrame.minX + localRect.minX,
                  y: displayFrame.minY + localRect.minY,
                  width: localRect.width,
                  height: localRect.height
              )) else {
            presentError(ScreenshotGeometryError.emptySelection)
            return
        }
        discardSelectionSession()
        selectionPixelRect = selection
        let globalRect = CGRect(
            x: displayFrame.minX + localRect.minX,
            y: displayFrame.minY + localRect.minY,
            width: localRect.width,
            height: localRect.height
        )
        selectionGlobalRect = globalRect
        self.selection = ScrollCaptureSelection(
            pixelRect: selection,
            pointPixelScale: pixelScale
        )
        stitcher = ScrollCaptureStitcher()
        frameCount = 0
        outputHeight = 0
        phase = .ready
        statusText = L10n.shared.string(
            "已选择 %@ × %@",
            String(selection.width),
            String(selection.height)
        )
        showCompletionControl(
            selectionGlobalRect: globalRect,
            screenFrame: displayFrame
        )
    }

    private func showCompletionControl(
        selectionGlobalRect: CGRect,
        screenFrame: CGRect
    ) {
        let window = ScrollCaptureCompletionWindow(
            selectionGlobalRect: selectionGlobalRect,
            screenFrame: screenFrame,
            onComplete: { [weak self] in
                guard let self else { return }
                Task { await self.stopAndOpenEditor() }
            },
            onCopy: { [weak self] in
                Task { await self?.finishCapture(.copy) }
            },
            onSave: { [weak self] in
                Task { await self?.finishCapture(.save) }
            },
            onCancel: { [weak self] in
                self?.cancel()
            }
        )
        completionWindow = window
        window.orderFrontRegardless()
        installKeyMonitors()
    }

    private func installKeyMonitors() {
        removeKeyMonitors()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self else { return event }
            let handled = self.handleScrollCaptureKey(event)
            return handled ? nil : event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            Task { @MainActor in
                _ = self?.handleScrollCaptureKey(event)
            }
        }
    }

    private func handleScrollCaptureKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:
            cancel()
            return true
        case 36, 76:
            guard frameCount > 0,
                  phase == .running || phase == .paused else {
                return false
            }
            Task { await stopAndOpenEditor() }
            return true
        default:
            return false
        }
    }

    private func removeKeyMonitors() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
    }

    private func showHUD(
        selectionGlobalRect: CGRect,
        screenFrame: CGRect,
        previewLayout: ScrollPreviewLayout
    ) {
        let window = ScrollCaptureHUDWindow(
            screenFrame: screenFrame,
            selectionRect: selectionGlobalRect,
            previewLayout: previewLayout
        )
        selectionOutlineWindow = window
        window.orderFrontRegardless()
    }

    private func targetWindowFrame(
        _ request: ScrollCaptureStartRequest
    ) -> CGRect? {
        guard let application = request.targetApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let windowInfo = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID
              ) as? [[String: Any]] else {
            return nil
        }
        let matchingWindows = windowInfo.compactMap { info -> CGRect? in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
                  ownerPID.int32Value == application.processIdentifier,
                  let layer = info[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
                return nil
            }
            return ScreenCaptureService.appKitWindowFrame(
                fromCoreGraphicsFrame: frame,
                displaySpaces: ScreenCaptureService.displayCoordinateSpaces()
            )
        }
        return matchingWindows.max {
            $0.width * $0.height < $1.width * $1.height
        }
    }

    private func captureNextFrameSoon() {
        frameTask?.cancel()
        frameTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(240))
            guard !Task.isCancelled, self.phase == .running else { return }
            _ = await self.captureNextFrame()
            guard !Task.isCancelled, self.phase == .running else { return }
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled, self.phase == .running else { return }
            self.captureNextFrameSoon()
        }
    }

    private func captureNextFrame() async -> ScrollFrameAppend? {
        guard phase == .running,
              !captureInFlight,
              let displayID,
              let selectionPixelRect,
              let stitcher else {
            return nil
        }
        captureInFlight = true
        defer { captureInFlight = false }
        do {
            let image = try await displayCapturer.captureDisplayExcludingOwnApplication(
                displayID
            )
            try Task.checkCancellation()
            guard phase == .running else { return nil }
            guard let cropped = image.cropping(to: selectionPixelRect.cgRect) else {
                throw ScreenshotGeometryError.emptySelection
            }
            let result = await stitcher.append(cropped)
            guard !Task.isCancelled, phase == .running else { return nil }
            async let acceptedFrames = stitcher.currentFrameCount
            async let stitchedSize = stitcher.currentPixelSize
            frameCount = await acceptedFrames
            outputHeight = await stitchedSize?.height ?? cropped.height
            switch result {
            case .accepted(let advance, _, _, _):
                consecutiveUnmatchedFrames = 0
                statusText = advance == 0
                    ? L10n.shared.string("已采集首帧，请缓慢滚动")
                    : L10n.shared.string(
                        "已采集 %@ 帧 · %@ × %@",
                        String(frameCount),
                        String(selectionPixelRect.width),
                        String(outputHeight)
                    )
                await updatePreview()
            case .prepended(let advance, _, _, _):
                consecutiveUnmatchedFrames = 0
                statusText = L10n.shared.string(
                    "已向上拼接 %@ px · %@ 帧",
                    String(advance),
                    String(frameCount)
                )
                await updatePreview()
            case .duplicate:
                consecutiveUnmatchedFrames = 0
                statusText = L10n.shared.string("等待页面滚动…")
                updateStatus()
            case .insufficientOverlap, .ambiguous, .changed, .mismatchedSize:
                consecutiveUnmatchedFrames += 1
                statusText = L10n.shared.string("等待稳定画面…")
                updateStatus()
            case .frameLimitReached:
                await finishAtLimit(reason: L10n.shared.string("已达到 100 帧上限。"))
            case .pixelLimitReached:
                await finishAtLimit(reason: L10n.shared.string("已达到 4000 万像素上限。"))
            }
            return result
        } catch is CancellationError {
            return nil
        } catch {
            pause(reason: error.localizedDescription)
            return nil
        }
    }

    private func pause(reason: String) {
        guard phase == .running else { return }
        frameTask?.cancel()
        frameTask = nil
        phase = .paused
        lastFailure = reason
        statusText = reason
        updateStatus()
    }

    private func updatePreview() async {
        previewImage = await stitcher?.currentImage()
        previewRevision &+= 1
        updateStatus()
    }

    private func updateStatus() {
        selectionOutlineWindow?.updatePreview(
            image: previewImage,
            frameCount: frameCount,
            outputHeight: outputHeight,
            status: statusText
        )
        completionWindow?.setEnabled(frameCount > 0
            && (phase == .running || phase == .paused))
    }

    private func finishAtLimit(reason: String) async {
        frameTask?.cancel()
        frameTask = nil
        statusText = reason
        await stopAndOpenEditor()
    }

    private func restoreTargetApplication() {
        guard let targetApplication,
              targetApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }
        targetApplication.activate()
    }

    private func closeWindows() {
        removeKeyMonitors()
        selectionCancellationTask?.cancel()
        selectionCancellationTask = nil
        discardSelectionSession()
        selectionOutlineWindow?.orderOut(nil)
        selectionOutlineWindow = nil
        completionWindow?.orderOut(nil)
        completionWindow = nil
    }

    // 不在选区窗口自己的事件处理里销毁它，避免 AppKit 结束窗口动画时崩溃。
    private func discardSelectionSession() {
        let session = selectionSession
        selectionSession = nil
        DispatchQueue.main.async { session?.close() }
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber).map {
            CGDirectDisplayID($0.uint32Value)
        }
    }
}

@MainActor
private final class ScrollRegionSelectionWindow: NSWindow, ScrollRegionSelectionSession {
    var onCancel: () -> Void = {}

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(contentRect: CGRect, image: CGImage) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hasShadow = false
        isOpaque = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        backgroundColor = .black
        setFrame(contentRect, display: false)
        let view = ScrollRegionSelectionView(
            frame: CGRect(origin: .zero, size: contentRect.size)
        )
        view.image = image
        view.onSelection = { [weak self] rect in self?.onSelection?(rect) }
        view.onCancel = { [weak self] in self?.onCancel() }
        contentView = view
    }

    var onSelection: ((CGRect) -> Void)? {
        get { (contentView as? ScrollRegionSelectionView)?.onSelection }
        set { (contentView as? ScrollRegionSelectionView)?.onSelection = newValue }
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

    func show() {
        makeKeyAndOrderFront(nil)
        makeFirstResponder(contentView)
    }
}

@MainActor
private final class ScrollRegionSelectionView: NSView {
    var image: CGImage?
    var onSelection: ((CGRect) -> Void)?
    var onCancel: () -> Void = {}
    private var startPoint: CGPoint?
    private var selection: CGRect?

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if let image {
            NSImage(cgImage: image, size: bounds.size).draw(
                in: bounds,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: false,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        } else {
            NSColor.black.setFill()
            bounds.fill()
        }

        if let selection {
            let dimming = NSBezierPath(rect: bounds)
            dimming.append(NSBezierPath(rect: selection))
            dimming.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.42).setFill()
            dimming.fill()

            NSColor.black.withAlphaComponent(0.5).setStroke()
            let shadow = NSBezierPath(rect: selection.insetBy(dx: 1.5, dy: 1.5))
            shadow.lineWidth = 5
            shadow.stroke()

            NylaiTheme.accent.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: 1.5, dy: 1.5))
            border.lineWidth = 3
            border.stroke()

            let label = "\(Int(selection.width)) × \(Int(selection.height))" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let size = label.size(withAttributes: attributes)
            let labelRect = CGRect(
                x: selection.minX,
                y: max(bounds.minY + 8, selection.minY - size.height - 10),
                width: size.width + 14,
                height: size.height + 7
            )
            NSColor.black.withAlphaComponent(0.72).setFill()
            NSBezierPath(roundedRect: labelRect, xRadius: 5, yRadius: 5).fill()
            label.draw(
                at: CGPoint(x: labelRect.minX + 7, y: labelRect.minY + 3.5),
                withAttributes: attributes
            )
        } else {
            let instruction = L10n.shared.string("拖动选择滚动内容区域 · Esc 取消") as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let size = instruction.size(withAttributes: attributes)
            let pill = CGRect(
                x: bounds.midX - size.width / 2 - 12,
                y: bounds.maxY - size.height - 38,
                width: size.width + 24,
                height: size.height + 12
            )
            NSColor.black.withAlphaComponent(0.72).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            instruction.draw(
                at: CGPoint(x: pill.minX + 12, y: pill.minY + 6),
                withAttributes: attributes
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = SelectionGeometry.normalizedSelection(from: startPoint, to: point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let selection, selection.width >= 8, selection.height >= 8 else {
            startPoint = nil
            self.selection = nil
            needsDisplay = true
            return
        }
        startPoint = nil
        onSelection?(selection)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel()
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
private final class ScrollCaptureHUDWindow: NSWindow {
    private let hudView: ScrollCaptureHUDView

    init(
        screenFrame: CGRect,
        selectionRect: CGRect,
        previewLayout: ScrollPreviewLayout
    ) {
        hudView = ScrollCaptureHUDView(
            frame: CGRect(origin: .zero, size: screenFrame.size),
            selectionRect: selectionRect.offsetBy(
                dx: -screenFrame.minX,
                dy: -screenFrame.minY
            ),
            previewRect: previewLayout.frame.offsetBy(
                dx: -screenFrame.minX,
                dy: -screenFrame.minY
            )
        )
        super.init(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = hudView
        setFrame(screenFrame, display: false)
    }

    func updatePreview(image: CGImage?, frameCount: Int, outputHeight: Int, status: String) {
        hudView.update(
            image: image,
            frameCount: frameCount,
            outputHeight: outputHeight,
            status: status
        )
    }
}

@MainActor
private final class ScrollCaptureHUDView: NSView {
    private let selectionRect: CGRect
    private let previewRect: CGRect
    private var previewImage: CGImage?
    private var frameCount = 0
    private var outputHeight = 0
    private var status = ""

    init(frame frameRect: NSRect, selectionRect: CGRect, previewRect: CGRect) {
        self.selectionRect = selectionRect
        self.previewRect = previewRect
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从归档创建滚动截图预览")
    }

    func update(image: CGImage?, frameCount: Int, outputHeight: Int, status: String) {
        previewImage = image
        self.frameCount = frameCount
        self.outputHeight = outputHeight
        self.status = status
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.52).setStroke()
        let shadow = NSBezierPath(rect: selectionRect.insetBy(dx: 1.5, dy: 1.5))
        shadow.lineWidth = 7
        shadow.stroke()

        NylaiTheme.accent.setStroke()
        let border = NSBezierPath(rect: selectionRect.insetBy(dx: 1.5, dy: 1.5))
        border.lineWidth = 3.5
        border.stroke()

        drawScrollPrompt()
        drawPreview()
    }

    private func drawScrollPrompt() {
        let text = L10n.shared.string("缓慢滚动 · 可向上或向下") as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ]
        let size = text.size(withAttributes: attributes)
        let x = selectionRect.minX + 102
        let pill = CGRect(
            x: x,
            y: selectionRect.minY + 11,
            width: size.width + 18,
            height: 28
        )
        guard pill.maxX <= selectionRect.maxX - 10 else { return }
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()
        text.draw(
            at: CGPoint(x: pill.minX + 9, y: pill.minY + 6),
            withAttributes: attributes
        )
    }

    private func drawPreview() {
        guard previewRect.width >= 2, previewRect.height >= 2 else { return }
        let panel = NSBezierPath(
            roundedRect: previewRect,
            xRadius: 11,
            yRadius: 11
        )
        NSColor.black.withAlphaComponent(0.82).setFill()
        panel.fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        panel.lineWidth = 1
        panel.stroke()

        let headerHeight: CGFloat = 28
        let footerHeight: CGFloat = 42
        let inset: CGFloat = 9
        let imageRect = CGRect(
            x: previewRect.minX + inset,
            y: previewRect.minY + footerHeight,
            width: max(1, previewRect.width - inset * 2),
            height: max(1, previewRect.height - headerHeight - footerHeight)
        )

        let header = L10n.shared.string("滚动结果") as NSString
        header.draw(
            at: CGPoint(x: previewRect.minX + inset, y: previewRect.maxY - 21),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            ]
        )

        NSColor.white.withAlphaComponent(0.68).setStroke()
        let imageBorder = NSBezierPath(
            roundedRect: imageRect,
            xRadius: 6,
            yRadius: 6
        )
        imageBorder.lineWidth = 1
        imageBorder.stroke()

        if let previewImage {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: imageRect, xRadius: 6, yRadius: 6).addClip()
            let fitted = ScrollPreviewImageFit.rect(
                imageSize: CGSize(
                    width: previewImage.width,
                    height: previewImage.height
                ),
                in: imageRect
            )
            NSImage(cgImage: previewImage, size: fitted.size).draw(
                in: fitted,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: false,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            NSGraphicsContext.restoreGraphicsState()
        } else {
            let placeholder = L10n.shared.string("正在采集首帧…") as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.white.withAlphaComponent(0.52),
            ]
            let size = placeholder.size(withAttributes: attributes)
            placeholder.draw(
                at: CGPoint(
                    x: imageRect.midX - size.width / 2,
                    y: imageRect.midY - size.height / 2
                ),
                withAttributes: attributes
            )
        }

        let count = L10n.shared.string(
            "%@ 帧 · %@ px",
            String(frameCount),
            String(outputHeight)
        ) as NSString
        count.draw(
            at: CGPoint(x: previewRect.minX + inset, y: previewRect.minY + 25),
            withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.78),
            ]
        )
        let statusText = status as NSString
        let statusAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5),
            .foregroundColor: NSColor.white.withAlphaComponent(0.62),
        ]
        statusText.draw(
            in: CGRect(
                x: previewRect.minX + inset,
                y: previewRect.minY + 8,
                width: previewRect.width - inset * 2,
                height: 16
            ),
            withAttributes: statusAttributes
        )
    }

}

@MainActor
final class ScrollCaptureCompletionWindow: NSPanel {
    private var outputButtons: [NSButton] = []
    private let onComplete: () -> Void
    private let onCopy: () -> Void
    private let onSave: () -> Void
    private let onCancel: () -> Void

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    static func placement(selection: CGRect, screen: CGRect) -> CGRect {
        let safe = screen.insetBy(dx: 8, dy: 8)
        let size = CGSize(width: 132, height: 36)
        let outside = selection.minY - 8 - size.height
        let y = outside >= safe.minY ? outside : selection.minY + 8
        return CGRect(x: min(max(selection.maxX - size.width, safe.minX), safe.maxX - size.width),
                      y: min(max(y, safe.minY), safe.maxY - size.height),
                      width: size.width, height: size.height)
    }

    init(selectionGlobalRect: CGRect, screenFrame: CGRect,
         onComplete: @escaping () -> Void, onCopy: @escaping () -> Void,
         onSave: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onComplete = onComplete
        self.onCopy = onCopy
        self.onSave = onSave
        self.onCancel = onCancel
        let rect = Self.placement(selection: selectionGlobalRect, screen: screenFrame)
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        identifier = NSUserInterfaceItemIdentifier("nylai.scroll-capture-completion")
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        backgroundColor = .clear
        isOpaque = false

        let surface = FloatingToolbarSurfaceView(frame: CGRect(origin: .zero, size: rect.size))
        let actions: [(String, String, Selector)] = [
            ("编辑", "edit", #selector(completeAction)),
            ("复制", "doc.on.doc", #selector(copyAction)),
            ("保存", "square.and.arrow.down", #selector(saveAction)),
            ("取消", "xmark", #selector(cancelAction)),
        ]
        for (index, entry) in actions.enumerated() {
            let button = ToolbarIconButton(frame: CGRect(x: 6 + index * 31, y: 5, width: 27, height: 26))
            button.image = entry.1 == "edit"
                ? NylaiIcon.edit.image(pointSize: 15)
                : NSImage(systemSymbolName: entry.1, accessibilityDescription: L10n.shared.string(entry.0))
            button.imagePosition = .imageOnly
            button.toolTip = L10n.shared.string(entry.0)
            button.setAccessibilityLabel(L10n.shared.string(entry.0))
            button.isBordered = false
            button.layer?.cornerRadius = 5
            button.target = self
            button.action = entry.2
            surface.addSubview(button)
            if index < 3 { outputButtons.append(button) }
        }
        contentView = surface
        setEnabled(false)
    }

    func setEnabled(_ enabled: Bool) { outputButtons.forEach { $0.isEnabled = enabled } }
    @objc private func completeAction() { onComplete() }
    @objc private func copyAction() { onCopy() }
    @objc private func saveAction() { onSave() }
    @objc private func cancelAction() { onCancel() }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel()
        case 36, 76:
            if outputButtons.first?.isEnabled == true { onComplete() }
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
private final class ScrollRegionSelectionPresenter: ScrollRegionSelecting {
    static let shared = ScrollRegionSelectionPresenter()

    func present(
        screenFrame: CGRect,
        image: CGImage,
        onSelection: @escaping (CGRect) -> Void,
        onCancel: @escaping () -> Void
    ) throws -> any ScrollRegionSelectionSession {
        let window = ScrollRegionSelectionWindow(
            contentRect: screenFrame,
            image: image
        )
        window.onSelection = onSelection
        window.onCancel = onCancel
        return window
    }
}
