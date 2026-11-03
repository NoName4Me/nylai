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

final class GesturePathRecorderView: NSView {
    var path = GesturePath() {
        didSet { needsDisplay = true }
    }
    var onChange: (GesturePath) -> Void = { _ in }
    private var recognizer = GesturePathRecognizer()
    private var isTracking = false
    private var previewPoints: [CGPoint] = []

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 260, height: 112) }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        NSColor.labelColor.withAlphaComponent(0.035).setFill()
        shape.fill()
        (isTracking ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        shape.lineWidth = isTracking ? 1.5 : 1
        shape.stroke()

        if previewPoints.isEmpty {
            let text = path.isEmpty ? "在这里按住拖动，录制手势路径" : path.display as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: path.isEmpty
                    ? NSFont.systemFont(ofSize: 11.5)
                    : NSFont.monospacedSystemFont(ofSize: 21, weight: .semibold),
                .foregroundColor: path.isEmpty ? NSColor.secondaryLabelColor : NSColor.labelColor,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(
                at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                withAttributes: attributes
            )
            return
        }
        let line = NSBezierPath()
        line.move(to: previewPoints[0])
        for point in previewPoints.dropFirst() {
            line.line(to: point)
        }
        NSColor.controlAccentColor.setStroke()
        line.lineWidth = 4
        line.lineCapStyle = .round
        line.lineJoinStyle = .round
        line.stroke()

        if let current = recognizer.recognizedPath() {
            let text = current.display as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            text.draw(at: CGPoint(x: 12, y: 10), withAttributes: attributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        recognizer.begin(at: point)
        previewPoints = [point]
        isTracking = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTracking else { return }
        let point = convert(event.locationInWindow, from: nil)
        _ = recognizer.move(to: point)
        previewPoints.append(point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isTracking else { return }
        let point = convert(event.locationInWindow, from: nil)
        _ = recognizer.move(to: point)
        isTracking = false
        if let recognized = recognizer.recognizedPath() {
            path = recognized
            onChange(recognized)
        }
        previewPoints = []
        recognizer.reset()
        needsDisplay = true
    }

    func resetRecording() {
        recognizer.reset()
        previewPoints = []
        isTracking = false
        needsDisplay = true
    }
}

private enum GestureEditorActionKind: String, CaseIterable, Identifiable {
    case nylai
    case application
    case shortcut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nylai: "nylai 功能"
        case .application: "启动 / 切换应用"
        case .shortcut: "发送组合键"
        }
    }
}

struct GestureRuleEditorView: View {
    @Environment(\.dismiss) private var dismiss
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isNew ? "添加鼠标手势" : "编辑鼠标手势")
                        .font(.system(size: 18, weight: .semibold))
                    Text("按住右键绘制路径；保存配置时不会执行绑定动作。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !draft.path.isEmpty {
                    Text(draft.path.display)
                        .font(.system(size: 20, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                }
            }

            GesturePathRecorder(path: draft.path) { path in
                draft.path = path
                errorMessage = nil
            }
            .frame(height: 112)

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
        .frame(width: 620)
        .onChange(of: actionKind) {
            if actionKind != .shortcut {
                finishShortcutRecording()
            }
        }
        .onDisappear {
            finishShortcutRecording()
        }
    }

    @ViewBuilder
    private var actionEditor: some View {
        GroupBox {
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
                    Text("发送一次组合键，目标为手势开始时所在应用。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(6)
            if let shortcutMessage {
                Text(shortcutMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
        }
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
        panel.prompt = "选择"
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
            errorMessage = "请选择要启动或切换的应用。"
            return
        }
        if actionKind == .shortcut, let shortcutDraft {
            draft.action = .sendShortcut(shortcutDraft)
        } else if actionKind == .shortcut {
            errorMessage = "请录入要发送的组合键。"
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
