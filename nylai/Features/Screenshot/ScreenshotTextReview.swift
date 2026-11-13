import AppKit

struct RecognizedTextLine: Identifiable, Equatable, Sendable {
    var id = UUID()
    let text: String
    let box: CGRect
}

struct RecognizedTextDocument {
    let lines: [RecognizedTextLine]
    let text: String
    let ranges: [NSRange]

    init(lines: [RecognizedTextLine], layout: RecognizedTextLayout) {
        self.lines = lines
        let separator = layout == .lines ? "\n" : " "
        var result = ""
        var ranges: [NSRange] = []
        for line in lines {
            if !result.isEmpty { result += separator }
            ranges.append(NSRange(location: (result as NSString).length, length: (line.text as NSString).length))
            result += line.text
        }
        text = result
        self.ranges = ranges
    }

    func indexes(intersecting selection: NSRange) -> Set<Int> {
        guard selection.location != NSNotFound, selection.length > 0 else { return [] }
        return Set(ranges.indices.filter { NSIntersectionRange(ranges[$0], selection).length > 0 })
    }

    func range(for indexes: Set<Int>) -> NSRange? {
        let ranges = indexes.sorted().compactMap { self.ranges.indices.contains($0) ? self.ranges[$0] : nil }
        guard let first = ranges.first, let last = ranges.last else { return nil }
        return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    }
}

@MainActor
final class ScreenshotTextReviewManager {
    static let shared = ScreenshotTextReviewManager()
    private var controllers: [UUID: ScreenshotTextReviewController] = [:]

    func present(image: CGImage, lines: [RecognizedTextLine], layout: RecognizedTextLayout) {
        let id = UUID()
        let controller = ScreenshotTextReviewController(image: image, lines: lines, layout: layout)
        controller.onClose = { [weak self] in self?.controllers[id] = nil }
        controllers[id] = controller
        controller.present()
    }
}

@MainActor
final class ScreenshotTextReviewController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    var onClose: () -> Void = {}
    private let imageView: RecognizedImageView
    private let textView = NSTextView()
    private var recognizedDocument: RecognizedTextDocument
    private let format = NSSegmentedControl(labels: [], trackingMode: .selectOne, target: nil, action: nil)
    private let copySelection = NSButton()

    init(image: CGImage, lines: [RecognizedTextLine], layout: RecognizedTextLayout) {
        imageView = RecognizedImageView(image: image, lines: lines)
        recognizedDocument = RecognizedTextDocument(lines: lines, layout: layout)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let size = CGSize(width: min(1000, screen.width - 24), height: min(700, screen.height - 24))
        let panel = TextReviewPanel(contentRect: CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height),
                                    styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = L10n.shared.string("提取文字")
        panel.identifier = NSUserInterfaceItemIdentifier("nylai.text-review")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.minSize = CGSize(width: min(680, size.width), height: min(400, size.height))
        super.init(window: panel)
        panel.delegate = self
        build()
        format.selectedSegment = layout == .lines ? 0 : 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不支持归档文字提取窗口") }

    func present() {
        window?.contentView?.layoutSubtreeIfNeeded()
        if let split = window?.contentView?.subviews.first as? NSSplitView {
            split.setPosition((window?.contentView?.bounds.width ?? 1000) * 0.56, ofDividerAt: 0)
        }
        window?.orderFrontRegardless()
        window?.makeKey()
        window?.makeFirstResponder(textView)
    }

    private func build() {
        guard let root = window?.contentView else { return }
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor), split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: root.topAnchor), split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        split.addArrangedSubview(imageView)
        let right = NSView()
        split.addArrangedSubview(right)
        imageView.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        right.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = textView
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = CGSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = CGSize(width: 14, height: 14)
        textView.font = .systemFont(ofSize: 14)
        textView.string = recognizedDocument.text
        textView.setAccessibilityLabel(L10n.shared.string("识别结果"))
        textView.delegate = self
        format.segmentCount = 2
        for (index, layout) in RecognizedTextLayout.allCases.enumerated() { format.setLabel(layout.title, forSegment: index) }
        format.selectedSegment = recognizedDocument.text.contains("\n") ? 0 : 1
        format.target = self
        format.action = #selector(formatChanged)
        copySelection.title = L10n.shared.string("复制选中")
        copySelection.target = self
        copySelection.action = #selector(copySelected)
        copySelection.bezelStyle = .rounded
        copySelection.isEnabled = false
        let copyAll = NSButton(title: L10n.shared.string("复制全部"), target: self, action: #selector(copyEverything))
        copyAll.bezelStyle = .rounded
        let actions = NSStackView(views: [format, NSView()])
        actions.orientation = .horizontal
        actions.spacing = 10
        let footer = NSStackView(views: [NSView(), copySelection, copyAll])
        footer.orientation = .horizontal
        footer.spacing = 10
        for view in [actions, scroll, footer] { view.translatesAutoresizingMaskIntoConstraints = false; right.addSubview(view) }
        NSLayoutConstraint.activate([
            actions.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 12), actions.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -12),
            actions.topAnchor.constraint(equalTo: right.topAnchor, constant: 12), actions.heightAnchor.constraint(equalToConstant: 30),
            scroll.leadingAnchor.constraint(equalTo: right.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 8), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 12), footer.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: right.bottomAnchor, constant: -12), footer.heightAnchor.constraint(equalToConstant: 30),
        ])
        split.setPosition(520, ofDividerAt: 0)
        imageView.onSelect = { [weak self] indexes in
            guard let self, let range = recognizedDocument.range(for: indexes) else { return }
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            copySelection.isEnabled = range.length > 0
            imageView.selectedIndexes = recognizedDocument.indexes(intersecting: range)
            window?.makeFirstResponder(textView)
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        imageView.selectedIndexes = recognizedDocument.indexes(intersecting: textView.selectedRange())
        copySelection.isEnabled = textView.selectedRange().length > 0
    }

    @objc private func formatChanged() {
        recognizedDocument = RecognizedTextDocument(lines: recognizedDocument.lines, layout: format.selectedSegment == 0 ? .lines : .paragraph)
        textView.string = recognizedDocument.text
        imageView.selectedIndexes = []
        copySelection.isEnabled = false
    }

    @objc private func copySelected() {
        let range = textView.selectedRange()
        guard range.length > 0, NSMaxRange(range) <= (recognizedDocument.text as NSString).length else { return }
        copy((recognizedDocument.text as NSString).substring(with: range))
    }

    @objc private func copyEverything() { copy(recognizedDocument.text) }
    private func copy(_ text: String) {
        do { try SystemClipboardPasteboard().write(.text(text), sourceBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.noname4me.nylai") }
        catch { ScreenshotErrorPresenter.show(error) }
    }
    func windowWillClose(_ notification: Notification) { onClose() }
}

@MainActor
private final class TextReviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class RecognizedImageView: NSView {
    let image: CGImage
    let lines: [RecognizedTextLine]
    var selectedIndexes: Set<Int> = [] { didSet { needsDisplay = true } }
    var onSelect: (Set<Int>) -> Void = { _ in }
    private var dragStart: CGPoint?
    private var accessibleLines: [RecognizedLineElement] = []
    init(image: CGImage, lines: [RecognizedTextLine]) {
        self.image = image
        self.lines = lines
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.shared.string("图片文字区域"))
        accessibleLines = lines.indices.map { index in
            let element = RecognizedLineElement()
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(lines[index].text)
            element.setAccessibilityParent(self)
            element.onPress = { [weak self] in self?.onSelect([index]) }
            return element
        }
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不支持归档图片文字区域") }
    private var imageFrame: CGRect {
        ScrollPreviewImageFit.rect(imageSize: CGSize(width: image.width, height: image.height), in: bounds.insetBy(dx: 16, dy: 16))
    }
    private func frame(for line: RecognizedTextLine) -> CGRect {
        let fit = imageFrame
        return CGRect(x: fit.minX + line.box.minX * fit.width, y: fit.minY + line.box.minY * fit.height,
                      width: line.box.width * fit.width, height: line.box.height * fit.height)
    }
    override func accessibilityChildren() -> [Any]? {
        for (index, element) in accessibleLines.enumerated() {
            if let window { element.setAccessibilityFrame(window.convertToScreen(convert(frame(for: lines[index]), to: nil))) }
        }
        return accessibleLines
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSImage(cgImage: image, size: imageFrame.size).draw(in: imageFrame)
        for (index, line) in lines.enumerated() {
            let box = frame(for: line).insetBy(dx: -2, dy: -2)
            if selectedIndexes.contains(index) {
                NylaiTheme.accent.withAlphaComponent(0.25).setFill()
                box.fill()
            }
            NylaiTheme.accent.withAlphaComponent(selectedIndexes.contains(index) ? 0.9 : 0.25).setStroke()
            NSBezierPath(rect: box).stroke()
        }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        if let index = lines.indices.first(where: { frame(for: lines[$0]).insetBy(dx: -4, dy: -4).contains(point) }) {
            onSelect([index])
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let end = convert(event.locationInWindow, from: nil)
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x - end.x), height: abs(start.y - end.y))
        onSelect(Set(lines.indices.filter { frame(for: lines[$0]).intersects(rect) }))
    }
    override func mouseUp(with event: NSEvent) { dragStart = nil }
}

@MainActor
private final class RecognizedLineElement: NSAccessibilityElement {
    var onPress: () -> Void = {}
    override func accessibilityPerformPress() -> Bool { onPress(); return true }
}
