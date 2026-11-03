import AppKit

enum PinnedImageLayout {
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
            1,
            min(maximumWidth / imageSize.width, maximumHeight / imageSize.height)
        )
        return CGSize(
            width: max(220, imageSize.width * scale),
            height: max(120, imageSize.height * scale)
        )
    }

    static func proportionalHeight(forWidth width: CGFloat, aspectRatio: CGFloat) -> CGFloat {
        max(80, width / max(aspectRatio, 0.01))
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

    func pin(_ image: CGImage) {
        let id = UUID()
        let controller = PinnedImageWindowController(
            image: image,
            saver: saver,
            presentError: presentError,
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
    private let onClose: () -> Void

    init(
        image: CGImage,
        saver: any ScreenshotSaving,
        presentError: @escaping @MainActor (Error) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.image = image
        self.saver = saver
        self.presentError = presentError
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
        window.minSize = CGSize(width: 220, height: 100)
        window.contentView = content
        super.init(window: window)
        window.delegate = content
        content.onClose = { [weak self] in self?.requestClose() }
        content.onCopy = { [weak self] in self?.copy() }
        content.onSave = { [weak self] in self?.save() }
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
    private let resizeHandle = PinnedResizeHandleView(frame: .zero)
    private var dragStartMouse: CGPoint?
    private var dragStartOrigin: CGPoint?
    private var resizeStartFrame: CGRect?
    private var resizeStartMouse: CGPoint?

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
        opacitySlider.widthAnchor.constraint(equalToConstant: 60).isActive = true
        opacityLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        opacityLabel.alignment = .right
        opacityLabel.widthAnchor.constraint(equalToConstant: 30).isActive = true

        let stack = NSStackView(views: [
            closeButton, opacitySlider, opacityLabel, copyButton, saveButton,
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

        resizeHandle.onResizeBegan = { [weak self] event in
            guard let self, let window else { return }
            resizeStartFrame = window.frame
            resizeStartMouse = NSEvent.mouseLocation
        }
        resizeHandle.onResizeDragged = { [weak self] event in
            self?.resizeWindow(with: event)
        }
        resizeHandle.onResizeEnded = { [weak self] in
            self?.resizeStartFrame = nil
            self?.resizeStartMouse = nil
        }
        addSubview(resizeHandle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从归档创建置顶图片内容")
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        chrome.frame = CGRect(x: 8, y: 8, width: min(300, bounds.width - 16), height: 34)
        resizeHandle.frame = CGRect(
            x: bounds.width - 24,
            y: bounds.height - 24,
            width: 20,
            height: 20
        )
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
    }

    override func mouseUp(with event: NSEvent) {
        dragStartMouse = nil
        dragStartOrigin = nil
    }

    func windowDidResize(_ notification: Notification) {
        needsLayout = true
    }

    private func resizeWindow(with event: NSEvent) {
        guard let window,
              let resizeStartFrame,
              let resizeStartMouse else { return }
        let mouse = NSEvent.mouseLocation
        let width = max(window.minSize.width, resizeStartFrame.width + mouse.x - resizeStartMouse.x)
        let aspect = resizeStartFrame.width / max(resizeStartFrame.height, 1)
        let height = PinnedImageLayout.proportionalHeight(
            forWidth: width,
            aspectRatio: aspect
        )
        window.setFrame(
            CGRect(
                x: resizeStartFrame.minX,
                y: resizeStartFrame.maxY - height,
                width: width,
                height: height
            ),
            display: true
        )
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

// The image is a passive surface; mouse events must reach the window content
// view so the whole image remains draggable.
@MainActor
private final class PinnedImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
private final class PinnedResizeHandleView: NSView {
    var onResizeBegan: ((NSEvent) -> Void)?
    var onResizeDragged: ((NSEvent) -> Void)?
    var onResizeEnded: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        for inset in [5.0, 9.0, 13.0] {
            path.move(to: CGPoint(x: bounds.maxX - inset, y: bounds.minY + 3))
            path.line(to: CGPoint(x: bounds.maxX - 3, y: bounds.minY + inset))
        }
        path.stroke()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        onResizeBegan?(event)
    }

    override func mouseDragged(with event: NSEvent) {
        onResizeDragged?(event)
    }

    override func mouseUp(with event: NSEvent) {
        onResizeEnded?()
    }
}
