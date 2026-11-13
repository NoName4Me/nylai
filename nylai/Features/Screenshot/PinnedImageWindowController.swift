import AppKit

enum PinnedImageLayout {
    static func visibleContentBounds(of image: CGImage) -> CGRect {
        let fullImage = CGRect(x: 0, y: 0, width: 1, height: 1)
        let scale = min(1, 1024 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return fullImage }
        var maximumAlpha: UInt8 = 0
        for offset in stride(from: 3, to: pixels.count, by: 4) { maximumAlpha = max(maximumAlpha, pixels[offset]) }
        guard maximumAlpha > 0 else { return fullImage }
        let threshold = max(1, Int(Double(maximumAlpha) * 0.9))
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width where Int(pixels[(y * width + x) * 4 + 3]) >= threshold {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return fullImage }
        return CGRect(x: CGFloat(minX) / CGFloat(width), y: CGFloat(minY) / CGFloat(height),
                      width: CGFloat(maxX - minX + 1) / CGFloat(width), height: CGFloat(maxY - minY + 1) / CGFloat(height))
    }
    static func zoomedFrame(_ frame: CGRect, factor: CGFloat, anchor: CGPoint, imageSize: CGSize, visibleFrame: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, factor.isFinite, factor > 0 else { return frame }
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return frame }
        let maximum = min(4, min(visibleFrame.width / imageSize.width, visibleFrame.height / imageSize.height))
        let minimum = min(maximum * 0.25, max(0.1, max(80 / imageSize.width, 80 / imageSize.height)))
        let scale = min(max(frame.width / imageSize.width * factor, minimum), maximum)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let relativeX = (anchor.x - frame.minX) / max(frame.width, 1)
        let relativeY = (anchor.y - frame.minY) / max(frame.height, 1)
        return CGRect(x: min(max(anchor.x - size.width * relativeX, visibleFrame.minX), visibleFrame.maxX - size.width),
                      y: min(max(anchor.y - size.height * relativeY, visibleFrame.minY), visibleFrame.maxY - size.height),
                      width: size.width, height: size.height)
    }
    static func initialSize(
        imageSize: CGSize,
        visibleFrame: CGRect,
        maximumFraction: CGFloat = 0.68
    ) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGSize(width: 240, height: 160)
        }
        let maximumWidth = visibleFrame.width * maximumFraction
        let maximumHeight = visibleFrame.height * maximumFraction
        let scale = min(
            max(1, max(220 / imageSize.width, 120 / imageSize.height)),
            min(maximumWidth / imageSize.width, maximumHeight / imageSize.height)
        )
        return CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
    }

    static func proportionalHeight(forWidth width: CGFloat, aspectRatio: CGFloat) -> CGFloat {
        max(80, width / max(aspectRatio, 0.01))
    }

    static func controlsFrame(
        imageFrame: CGRect,
        controlsSize: CGSize,
        visibleFrame: CGRect
    ) -> CGRect {
        let gap: CGFloat = 6
        let margin: CGFloat = 8
        let above = imageFrame.maxY + gap
        let below = imageFrame.minY - gap - controlsSize.height
        let preferredY = above + controlsSize.height <= visibleFrame.maxY - margin
            ? above
            : below
        let y = min(
            max(preferredY, visibleFrame.minY + margin),
            visibleFrame.maxY - controlsSize.height - margin
        )
        let x = min(
            max(imageFrame.minX, visibleFrame.minX + margin),
            visibleFrame.maxX - controlsSize.width - margin
        )
        return CGRect(origin: CGPoint(x: x, y: y), size: controlsSize)
    }
}

@MainActor
final class PinnedImageManager {
    private let saver: any ScreenshotSaving
    private let presentError: @MainActor (Error) -> Void
    private(set) var controllers: [UUID: PinnedImageWindowController] = [:]

    init(
        saver: any ScreenshotSaving = PNGScreenshotSaver(),
        presentError: @escaping @MainActor (Error) -> Void = ScreenshotErrorPresenter.show
    ) {
        self.saver = saver
        self.presentError = presentError
    }

    var windowCount: Int { controllers.count }

    func pin(_ image: CGImage, restoreApplication: NSRunningApplication? = nil) {
        let id = UUID()
        let controller = PinnedImageWindowController(
            image: image,
            saver: saver,
            presentError: presentError,
            restoreApplication: restoreApplication,
            onClose: { [weak self] in
                self?.controllers.removeValue(forKey: id)
            }
        )
        controllers[id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func closeAll() {
        for controller in controllers.values {
            controller.close()
        }
        controllers.removeAll()
    }
}

@MainActor
final class PinnedImageWindowController: NSWindowController {
    private let image: CGImage
    private let saver: any ScreenshotSaving
    private let presentError: @MainActor (Error) -> Void
    private let content: PinnedImageContentView
    private let restoreApplication: NSRunningApplication?
    private let onClose: () -> Void

    init(
        image: CGImage,
        saver: any ScreenshotSaving,
        presentError: @escaping @MainActor (Error) -> Void,
        restoreApplication: NSRunningApplication? = nil,
        onClose: @escaping () -> Void
    ) {
        self.image = image
        self.saver = saver
        self.presentError = presentError
        self.restoreApplication = restoreApplication
        self.onClose = onClose
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = PinnedImageLayout.initialSize(
            imageSize: CGSize(width: image.width, height: image.height),
            visibleFrame: visibleFrame
        )
        let frame = CGRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        content = PinnedImageContentView(image: image, frame: CGRect(origin: .zero, size: size))
        let window = PinnedImageWindow(
            contentRect: frame,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Narrow long screenshots must remain proportional and fit the display.
        window.minSize = CGSize(width: 1, height: 1)
        window.contentView = content
        super.init(window: window)
        window.delegate = content
        content.onClose = { [weak self] in self?.requestClose() }
        content.onCopy = { [weak self] in self?.copy() }
        content.onSave = { [weak self] in self?.save() }
        content.attachControls()
        window.makeFirstResponder(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从归档创建置顶图片")
    }

    var imageOpacity: CGFloat {
        get { content.imageOpacity }
        set { content.imageOpacity = min(max(newValue, 0.1), 1) }
    }

    var controlsOpacity: CGFloat {
        content.controlsOpacity
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !pasteboard.writeObjects([NSImage(cgImage: image, size: .zero)]) {
            presentError(ScreenshotOutputError.clipboardWriteFailed)
        }
    }

    private func requestClose() {
        close()
        onClose()
        restoreApplication?.activate(options: [.activateAllWindows])
    }

    private func save() {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await saver.save(image)
            } catch {
                presentError(error)
            }
        }
    }
}

@MainActor
private final class PinnedImageWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class PinnedImageContentView: NSView, NSWindowDelegate {
    var onClose: () -> Void = {}
    var onCopy: () -> Void = {}
    var onSave: () -> Void = {}

    private let imageView = PinnedImageView()
    private let chrome = NSVisualEffectView()
    private let opacitySlider = NSSlider(value: 1, minValue: 0.1, maxValue: 1, target: nil, action: nil)
    private let opacityLabel = NSTextField(labelWithString: "100%")
    private let zoomLabel = NSTextField(labelWithString: "")
    private let originalSize: CGSize
    private let imageContentBounds: CGRect
    private var floatingControls: PinnedControlsPanel?
    private var dragStartMouse: CGPoint?
    private var dragStartOrigin: CGPoint?

    var imageOpacity: CGFloat {
        get { imageView.alphaValue }
        set {
            let clamped = min(max(newValue, 0.1), 1)
            imageView.alphaValue = clamped
            opacitySlider.doubleValue = clamped
            opacityLabel.stringValue = "\(Int((clamped * 100).rounded()))%"
        }
    }

    var controlsOpacity: CGFloat {
        chrome.alphaValue
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(image: CGImage, frame: NSRect) {
        originalSize = CGSize(width: image.width, height: image.height)
        imageContentBounds = PinnedImageLayout.visibleContentBounds(of: image)
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        imageView.image = NSImage(cgImage: image, size: frame.size)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)

        chrome.material = .hudWindow
        chrome.blendingMode = .withinWindow
        chrome.state = .active
        chrome.wantsLayer = true
        chrome.layer?.cornerRadius = 9
        chrome.frame = CGRect(
            x: 8,
            y: 8,
            width: min(300, frame.width - 16),
            height: 34
        )
        addSubview(chrome)

        let closeButton = makeIconButton(
            symbol: "xmark",
            label: "关闭",
            action: #selector(closeClicked)
        )
        let copyButton = makeIconButton(
            symbol: "doc.on.doc",
            label: "复制",
            action: #selector(copyClicked)
        )
        let saveButton = makeIconButton(
            symbol: "square.and.arrow.down",
            label: "保存",
            action: #selector(saveClicked)
        )
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged)
        opacitySlider.controlSize = .mini
        opacitySlider.widthAnchor.constraint(equalToConstant: 44).isActive = true
        opacitySlider.toolTip = L10n.shared.string("透明度")
        opacityLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        opacityLabel.alignment = .right
        opacityLabel.widthAnchor.constraint(equalToConstant: 30).isActive = true

        let opacityIcon = NSImageView(image: NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: L10n.shared.string("透明度")) ?? NSImage())
        let zoomIcon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: L10n.shared.string("缩放比例")) ?? NSImage())
        for icon in [opacityIcon, zoomIcon] {
            icon.widthAnchor.constraint(equalToConstant: 12).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 12).isActive = true
        }
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        zoomLabel.alignment = .right
        zoomLabel.widthAnchor.constraint(equalToConstant: 37).isActive = true
        zoomLabel.toolTip = L10n.shared.string("滚轮缩放")
        zoomLabel.setAccessibilityLabel(L10n.shared.string("缩放比例"))
        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let stack = NSStackView(views: [
            closeButton, opacityIcon, opacitySlider, opacityLabel, separator, zoomIcon, zoomLabel, copyButton, saveButton,
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: chrome.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: chrome.bottomAnchor, constant: -5),
        ])

    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从归档创建置顶图片内容")
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        zoomLabel.stringValue = "\(Int((bounds.width / originalSize.width * 100).rounded()))%"
        layoutControls()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragStartMouse, let dragStartOrigin else { return }
        let mouse = NSEvent.mouseLocation
        window.setFrameOrigin(CGPoint(
            x: dragStartOrigin.x + mouse.x - dragStartMouse.x,
            y: dragStartOrigin.y + mouse.y - dragStartMouse.y
        ))
        layoutControls()
    }

    override func mouseUp(with event: NSEvent) {
        dragStartMouse = nil
        dragStartOrigin = nil
    }

    override func cancelOperation(_ sender: Any?) { onClose() }

    override func scrollWheel(with event: NSEvent) {
        guard let window, event.scrollingDeltaY != 0 else { return }
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.008 : 0.06)
        let frame = PinnedImageLayout.zoomedFrame(window.frame, factor: exp(min(max(delta, -0.5), 0.5)),
                                                anchor: window.convertPoint(toScreen: event.locationInWindow),
                                                imageSize: originalSize,
                                                visibleFrame: window.screen?.visibleFrame ?? window.frame)
        window.setFrame(frame, display: true)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func windowDidResize(_ notification: Notification) {
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func windowDidMove(_ notification: Notification) { layoutControls() }
    func windowDidBecomeKey(_ notification: Notification) { needsLayout = true }

    func windowWillClose(_ notification: Notification) {
        if let panel = floatingControls { panel.parent?.removeChildWindow(panel) }
        floatingControls?.orderOut(nil)
        floatingControls = nil
    }

    func attachControls() {
        guard let window else { return }
        let panel = PinnedControlsPanel(
            contentRect: CGRect(x: 0, y: 0, width: 310, height: 34),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        chrome.removeFromSuperview()
        panel.contentView = chrome
        window.addChildWindow(panel, ordered: .above)
        floatingControls = panel
        layoutControls()
    }

    private func layoutControls() {
        guard let window else { return }
        let visibleImage = CGRect(x: bounds.minX + bounds.width * imageContentBounds.minX,
                                  y: bounds.minY + bounds.height * imageContentBounds.minY,
                                  width: bounds.width * imageContentBounds.width,
                                  height: bounds.height * imageContentBounds.height)
        let imageFrame = window.convertToScreen(convert(visibleImage, to: nil))
        let controlsSize = CGSize(width: 310, height: 34)
        let visibleFrame = window.screen?.visibleFrame
            ?? window.frame.insetBy(dx: -controlsSize.width, dy: -controlsSize.height)
        let frame = PinnedImageLayout.controlsFrame(
            imageFrame: imageFrame,
            controlsSize: controlsSize,
            visibleFrame: visibleFrame
        )
        floatingControls?.setFrame(frame, display: true)
        if window.isVisible {
            floatingControls?.orderFrontRegardless()
        }
    }

    private func makeIconButton(
        symbol: String,
        label: String,
        action: Selector
    ) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.controlSize = .small
        button.toolTip = label
        button.target = self
        button.action = action
        return button
    }

    @objc private func opacityChanged() {
        imageView.alphaValue = opacitySlider.doubleValue
        opacityLabel.stringValue = "\(Int((opacitySlider.doubleValue * 100).rounded()))%"
    }

    @objc private func closeClicked() {
        onClose()
    }

    @objc private func copyClicked() {
        onCopy()
    }

    @objc private func saveClicked() {
        onSave()
    }
}

@MainActor
private final class PinnedControlsPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func makeKey() {}
    override func makeKeyAndOrderFront(_ sender: Any?) {
        orderFrontRegardless()
    }
}
// The image is a passive surface; mouse events must reach the window content
// view so the whole image remains draggable.
@MainActor
private final class PinnedImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
