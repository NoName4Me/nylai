import AppKit
import SwiftUI

struct GesturePathRecorder: NSViewRepresentable {
    var path: GesturePath
    var onChange: (GesturePath) -> Void

    func makeNSView(context: Context) -> GesturePathRecorderView {
        let view = GesturePathRecorderView()
        view.path = path
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: GesturePathRecorderView, context: Context) {
        view.path = path
        view.onChange = onChange
    }
}

@MainActor
final class GesturePathRecorderView: NSView {
    var path = GesturePath() {
        didSet { needsDisplay = true }
    }
    var onChange: (GesturePath) -> Void = { _ in }
    private var recognizer = GesturePathRecognizer()
    private var isTracking = false
    private var previewPoints: [CGPoint] = []
    private var needsRedrawHint = false
    nonisolated(unsafe) private var rightMouseLocalMonitor: Any?

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 260, height: 196) }

    deinit {
        if let rightMouseLocalMonitor {
            NSEvent.removeMonitor(rightMouseLocalMonitor)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installRightMouseEventMonitorIfNeeded()
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        NSColor.labelColor.withAlphaComponent(0.035).setFill()
        shape.fill()
        (isTracking ? NylaiTheme.accent : NSColor.separatorColor).setStroke()
        shape.lineWidth = isTracking ? 1.5 : 1
        shape.stroke()

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if isTracking {
            GestureStroke.draw(previewPoints, in: context, lineWidth: 3)
            if let current = recognizer.recognizedPath() {
                GestureStroke.draw(current, in: context,
                                   bounds: CGRect(x: bounds.maxX - 92, y: 10, width: 80, height: 50))
            }
        } else if !path.isEmpty {
            GestureStroke.draw(path, in: context, bounds: bounds.insetBy(dx: 36, dy: 25))
        }

        if needsRedrawHint || (!isTracking && path.isEmpty) {
            let hint = needsRedrawHint
                ? L10n.shared.string("未识别到手势，请重画")
                : L10n.shared.string("按住鼠标右键绘制手势")
            let text = hint as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: bounds.midX - size.width / 2,
                                  y: path.isEmpty ? bounds.midY - size.height / 2 : 8),
                      withAttributes: attributes)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        beginTracking(at: convert(event.locationInWindow, from: nil))
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard isTracking else { return }
        continueTracking(at: convert(event.locationInWindow, from: nil))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard isTracking else { return }
        endTracking(at: convert(event.locationInWindow, from: nil))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        nil
    }

    private func beginTracking(at point: CGPoint) {
        needsRedrawHint = false
        recognizer.begin(at: point)
        previewPoints = [point]
        isTracking = true
        needsDisplay = true
    }

    private func continueTracking(at point: CGPoint) {
        _ = recognizer.move(to: point)
        previewPoints.append(point)
        needsDisplay = true
    }

    private func endTracking(at point: CGPoint) {
        _ = recognizer.move(to: point)
        isTracking = false
        if let recognized = recognizer.recognizedPath() {
            path = recognized
            onChange(recognized)
        } else {
            needsRedrawHint = recognizer.hasEnteredGesture
        }
        previewPoints = []
        recognizer.reset()
        needsDisplay = true
    }

    private func installRightMouseEventMonitorIfNeeded() {
        if let rightMouseLocalMonitor {
            NSEvent.removeMonitor(rightMouseLocalMonitor)
            self.rightMouseLocalMonitor = nil
        }
        resetRecording()
        guard window != nil else { return }
        rightMouseLocalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.rightMouseDown, .rightMouseDragged, .rightMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handleMonitoredRightMouseEvent(event) ? nil : event
        }
    }

    private func handleMonitoredRightMouseEvent(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else {
            return false
        }
        let point = convert(event.locationInWindow, from: nil)
        switch event.type {
        case .rightMouseDown:
            guard bounds.contains(point) else { return false }
            window.makeFirstResponder(self)
            beginTracking(at: point)
        case .rightMouseDragged where isTracking:
            continueTracking(at: point)
        case .rightMouseUp where isTracking:
            endTracking(at: point)
        default:
            return false
        }
        return true
    }

    func resetRecording() {
        recognizer.reset()
        previewPoints = []
        isTracking = false
        needsDisplay = true
    }
}

struct GesturePathThumbnail: View {
    let path: GesturePath

    var body: some View {
        Canvas { context, size in
            context.withCGContext { graphics in
                graphics.translateBy(x: 0, y: size.height)
                graphics.scaleBy(x: 1, y: -1)
                GestureStroke.draw(path, in: graphics,
                                   bounds: CGRect(origin: .zero, size: size).insetBy(dx: 7, dy: 6))
            }
        }
        .accessibilityLabel(path.display)
    }
}

private enum GestureStroke {
    static func draw(_ path: GesturePath, in context: CGContext, bounds: CGRect) {
        var points = [CGPoint.zero]
        if let circle = path.circle {
            let direction: CGFloat = circle == .clockwise ? -1 : 1
            points = (0...48).map { index in
                let angle = .pi / 2 + direction * .pi * 1.88 * CGFloat(index) / 48
                return CGPoint(x: cos(angle), y: sin(angle))
            }
        } else {
            for direction in path.directions {
                let last = points[points.count - 1]
                let offset = direction.offset
                points.append(CGPoint(x: last.x + offset.x, y: last.y + offset.y))
            }
        }
        guard points.count > 1 else { return }
        let extent = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        let scale = min(bounds.width, bounds.height) * 0.72 / max(max(extent.width, extent.height), 1)
        let fitted = points.map {
            CGPoint(x: bounds.midX + ($0.x - extent.midX) * scale,
                    y: bounds.midY + ($0.y - extent.midY) * scale)
        }
        draw(fitted, in: context, lineWidth: bounds.height > 80 ? 3.5 : 2)
    }

    static func draw(_ points: [CGPoint], in context: CGContext, lineWidth: CGFloat) {
        guard let start = points.first, let end = points.last else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(NylaiPalette.accentNSColor.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addLines(between: points)
        if let previous = points.dropLast().reversed().first(where: {
            hypot(end.x - $0.x, end.y - $0.y) >= lineWidth
        }) {
            let angle = atan2(end.y - previous.y, end.x - previous.x)
            for wing in [-CGFloat.pi / 5, CGFloat.pi / 5] {
                context.move(to: end)
                context.addLine(to: CGPoint(
                    x: end.x - cos(angle + wing) * lineWidth * 2.7,
                    y: end.y - sin(angle + wing) * lineWidth * 2.7
                ))
            }
        }
        context.strokePath()
        let radius = lineWidth * 1.25
        context.setFillColor(NSColor(srgbRed: 0.89, green: 0.32, blue: 0.52, alpha: 1).cgColor)
        context.fillEllipse(in: CGRect(x: start.x - radius, y: start.y - radius,
                                       width: radius * 2, height: radius * 2))
    }
}

private enum GestureEditorActionKind: String, CaseIterable, Identifiable {
    case nylai
    case application
    case shortcut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nylai: L10n.shared.string("%@ 功能", AppName.current)
        case .application: L10n.shared.string("打开 / 切换应用")
        case .shortcut: L10n.shared.string("发送组合键")
        }
    }
}

struct GestureRuleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    private let isNew: Bool
    private let onSave: (MouseGestureRule) throws -> Void
    private let onBeginShortcutRecording: () -> Bool
    private let onEndShortcutRecording: () -> Void
    @State private var draft: MouseGestureRule
    @State private var actionKind: GestureEditorActionKind
    @State private var shortcutDraft: ShortcutKey?
    @State private var isRecordingShortcut = false
    @State private var shortcutMessage: String?
    @State private var errorMessage: String?

    private static let nylaiActions: [ShortcutAction] = [
        .openSettings,
        .captureInteractive,
        .screenshotHistory,
        .openCollage,
        .clipboardHistory,
    ]

    init(
        rule: MouseGestureRule,
        isNew: Bool,
        onBeginShortcutRecording: @escaping () -> Bool = { true },
        onEndShortcutRecording: @escaping () -> Void = {},
        onSave: @escaping (MouseGestureRule) throws -> Void
    ) {
        _draft = State(initialValue: rule)
        self.isNew = isNew
        self.onBeginShortcutRecording = onBeginShortcutRecording
        self.onEndShortcutRecording = onEndShortcutRecording
        self.onSave = onSave
        if isNew || rule.path.isEmpty {
            _actionKind = State(initialValue: .shortcut)
            _shortcutDraft = State(initialValue: nil)
        } else {
            switch rule.action {
            case .nylai:
                _actionKind = State(initialValue: .nylai)
                _shortcutDraft = State(initialValue: nil)
            case .application:
                _actionKind = State(initialValue: .application)
                _shortcutDraft = State(initialValue: nil)
            case .sendShortcut:
                _actionKind = State(initialValue: .shortcut)
                _shortcutDraft = State(initialValue: rule.action.shortcut)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isAdding ? "添加鼠标手势" : "编辑鼠标手势")
                        .font(.system(size: 18, weight: .semibold))
                    Text("按住右键绘制路径；保存配置时不会执行绑定动作。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()

            }

            GesturePathRecorder(path: draft.path) { path in
                draft.path = path
                errorMessage = nil
            }
            .frame(height: 196)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("作用域")
                        .font(.system(size: 11.5, weight: .medium))
                    HStack(spacing: 8) {
                        Button(draft.scopeBundleIdentifier == nil ? "所有应用" : applicationName(draft.scopeBundleIdentifier)) {
                            chooseScopeApplication()
                        }
                        if draft.scopeBundleIdentifier != nil {
                            Button("改为所有应用") {
                                draft.scopeBundleIdentifier = nil
                            }
                        }
                    }
                }
                Spacer()
                Picker("动作", selection: $actionKind) {
                    ForEach(GestureEditorActionKind.allCases) {
                        Text($0.title).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 330)
                .onChange(of: actionKind) {
                    applyDefaultAction()
                }
            }

            actionEditor

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(22)
        .frame(width: 640)
        .background(theme.page)
        .tint(NylaiPalette.accent)
        .onChange(of: actionKind) {
            if actionKind != .shortcut {
                finishShortcutRecording()
            }
        }
        .onDisappear {
            finishShortcutRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            finishShortcutRecording()
        }
    }

    @ViewBuilder
    private var actionEditor: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("动作")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            SettingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                switch actionKind {
                case .nylai:
                    Picker("功能", selection: nylaiActionIndexBinding) {
                        ForEach(Self.nylaiActions.indices, id: \.self) { index in
                            Text(ShortcutBindingRuntime.title(for: Self.nylaiActions[index]))
                                .tag(index)
                        }
                    }
                    .frame(maxWidth: 260)
                    Spacer()
                case .application:
                    VStack(alignment: .leading, spacing: 4) {
                        Text(applicationName(currentApplicationTarget?.bundleIdentifier))
                            .font(.system(size: 12.5, weight: .medium))
                        Text(currentApplicationTarget?.path ?? "尚未选择应用")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Button("选择应用…") { chooseActionApplication() }
                    Spacer()
                    Toggle(
                        "前台再次触发时隐藏",
                        isOn: Binding(
                            get: { currentApplicationTarget?.hidesOnRepeatTrigger ?? true },
                            set: { value in
                                guard var target = currentApplicationTarget else { return }
                                target.hidesOnRepeatTrigger = value
                                draft.action = .application(target)
                            }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                case .shortcut:
                    ShortcutRecorder(
                        shortcut: shortcutDraft,
                        isRecording: isRecordingShortcut,
                        onBegin: {
                            guard onBeginShortcutRecording() else { return false }
                            isRecordingShortcut = true
                            shortcutMessage = nil
                            return true
                        },
                        onCapture: { shortcut in
                            shortcutDraft = shortcut
                            draft.action = .sendShortcut(shortcut)
                            finishShortcutRecording()
                        },
                        onCancel: {
                            finishShortcutRecording()
                            shortcutMessage = nil
                        },
                        onClear: {
                            shortcutDraft = nil
                            finishShortcutRecording()
                        },
                        onMessage: { shortcutMessage = $0 }
                    )
                    .frame(width: 150, height: 28)
                    Text("发送组合键，支持系统快捷键。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                    }
                    .padding(14)
                    if let shortcutMessage {
                        Text(shortcutMessage)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 12)
                    }
                }
            }
        }
    }

    private var theme: SettingsTheme {
        SettingsTheme(colorScheme: colorScheme)
    }

    private var isAdding: Bool {
        isNew || draft.path.isEmpty
    }

    private func finishShortcutRecording() {
        guard isRecordingShortcut else { return }
        isRecordingShortcut = false
        onEndShortcutRecording()
    }

    private var nylaiActionIndexBinding: Binding<Int> {
        Binding(
            get: {
                guard case .nylai(let action) = draft.action,
                      let index = Self.nylaiActions.firstIndex(of: action) else {
                    return 0
                }
                return index
            },
            set: { index in
                guard Self.nylaiActions.indices.contains(index) else { return }
                draft.action = .nylai(Self.nylaiActions[index])
            }
        )
    }

    private var currentApplicationTarget: ApplicationShortcutTarget? {
        if case .application(let target) = draft.action { return target }
        return nil
    }

    private func applyDefaultAction() {
        switch actionKind {
        case .nylai:
            if case .nylai = draft.action { return }
            draft.action = .nylai(.openSettings)
        case .application:
            if case .application = draft.action { return }
            chooseActionApplication()
        case .shortcut:
            if let shortcutDraft {
                draft.action = .sendShortcut(shortcutDraft)
            }
        }
    }

    private func chooseScopeApplication() {
        guard let bundleIdentifier = chooseApplication() else { return }
        draft.scopeBundleIdentifier = bundleIdentifier
    }

    private func chooseActionApplication() {
        guard let url = chooseApplicationURL(),
              let bundleIdentifier = Bundle(url: url)?.bundleIdentifier else {
            return
        }
        draft.action = .application(ApplicationShortcutTarget(
            bundleIdentifier: bundleIdentifier,
            path: url.path(percentEncoded: false),
            hidesOnRepeatTrigger: true
        ))
    }

    private func chooseApplication() -> String? {
        guard let url = chooseApplicationURL() else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    private func chooseApplicationURL() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = L10n.shared.string("选择")
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func applicationName(_ bundleIdentifier: String?) -> String {
        guard let bundleIdentifier else { return "所有应用" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        return bundleIdentifier
    }

    private func save() {
        guard !draft.path.isEmpty else {
            errorMessage = MouseGestureConfigurationError.emptyPath.localizedDescription
            return
        }
        if actionKind == .application, currentApplicationTarget == nil {
            errorMessage = L10n.shared.string("请选择要启动或切换的应用。")
            return
        }
        if actionKind == .shortcut, let shortcutDraft {
            draft.action = .sendShortcut(shortcutDraft)
        } else if actionKind == .shortcut {
            errorMessage = L10n.shared.string("请录入要发送的组合键。")
            return
        }
        do {
            try onSave(draft)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var canSave: Bool {
        guard !draft.path.isEmpty else { return false }
        switch actionKind {
        case .nylai:
            return true
        case .application:
            return currentApplicationTarget != nil
        case .shortcut:
            return shortcutDraft != nil
        }
    }
}

private extension GestureAction {
    var shortcut: ShortcutKey? {
        guard case .sendShortcut(let shortcut) = self else { return nil }
        return shortcut
    }
}
