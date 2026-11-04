import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class ClipboardPanelModel {
    let store: ClipboardHistoryStore
    let pasteboard: any ClipboardPasteboardAccessing
    let targetApplication: NSRunningApplication?
    var searchText = ""
    var selectedID: UUID?
    var errorMessage: String?
    var onClose: () -> Void = {}
    var onCopied: ((UUID) -> Void)?
    var reveal: CGFloat = 0
    var rowFrames: [UUID: CGRect] = [:]
    let openedAt = Date()
    private let timeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    func relativeTime(for date: Date) -> String {
        timeFormatter.localizedString(for: date, relativeTo: openedAt)
    }
    var onPreview: (ClipboardRecord?) -> Void = { _ in }
    var onError: @MainActor (Error) -> Void = { _ in }
    private let directPaster: any ClipboardDirectPasting
    private var textCache: [UUID: String] = [:]

    init(
        store: ClipboardHistoryStore,
        pasteboard: any ClipboardPasteboardAccessing,
        targetApplication: NSRunningApplication?,
        directPaster: any ClipboardDirectPasting = SystemClipboardDirectPaster()
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.targetApplication = targetApplication
        self.directPaster = directPaster
    }

    var pinnedMatches: [ClipboardRecord] {
        store.pinnedRecords.filter(matches)
    }

    var ordinaryMatches: [ClipboardRecord] {
        store.ordinaryRecords.filter(matches)
    }

    var canDirectPaste: Bool {
        targetApplication?.bundleIdentifier != nil
    }

    var visibleRecords: [ClipboardRecord] {
        pinnedMatches + ordinaryMatches
    }

    func selectNext(_ offset: Int) {
        let records = visibleRecords
        guard !records.isEmpty else {
            selectedID = nil
            return
        }
        guard let selectedID,
              let index = records.firstIndex(where: { $0.id == selectedID }) else {
            self.selectedID = offset < 0 ? records.last?.id : records.first?.id
            return
        }
        let next = min(max(index + offset, 0), records.count - 1)
        self.selectedID = records[next].id
    }

    func copySelectedOrFirst() {
        guard let record = visibleRecords.first(where: { $0.id == selectedID })
            ?? visibleRecords.first else {
            return
        }
        copy(record)
    }

    func preview(for record: ClipboardRecord) -> String {
        switch record.kind {
        case .image:
            return "\(record.pixelWidth ?? 0) × \(record.pixelHeight ?? 0) 图片"
        case .text:
            if let cached = textCache[record.id] {
                return cached
            }
            let text = store.text(for: record) ?? ""
            textCache[record.id] = text
            return text
        }
    }

    func copy(_ record: ClipboardRecord) {
        do {
            guard let content = store.content(for: record) else {
                throw ClipboardStoreError.recordNotFound
            }
            try pasteboard.write(
                content,
                sourceBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.noname4me.nylai"
            )
            errorMessage = nil
            if let onCopied { onCopied(record.id) } else { onClose() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func directPaste(_ record: ClipboardRecord) {
        guard let targetApplication,
              let bundleIdentifier = targetApplication.bundleIdentifier else {
            errorMessage = ClipboardDirectPasteError.targetUnavailable.localizedDescription
            return
        }
        do {
            guard let content = store.content(for: record) else {
                throw ClipboardStoreError.recordNotFound
            }
            try pasteboard.write(
                content,
                sourceBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.noname4me.nylai"
            )
            let expectedChangeCount = pasteboard.changeCount
            onClose()
            Task { [self] in
                let result = await directPaster.pasteAfterActivating(
                    target: targetApplication,
                    expectedBundleIdentifier: bundleIdentifier,
                    expectedChangeCount: expectedChangeCount,
                    pasteboard: pasteboard
                )
                if case .failure(let error) = result {
                    onError(error)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func togglePinned(_ record: ClipboardRecord) {
        do {
            try store.setPinned(!record.isPinned, id: record.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ record: ClipboardRecord) {
        do {
            try store.delete(id: record.id)
            selectedID = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func matches(_ record: ClipboardRecord) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        if record.sourceName?.localizedCaseInsensitiveContains(query) == true
            || record.sourceBundleIdentifier?.localizedCaseInsensitiveContains(query) == true {
            return true
        }
        guard record.kind == .text else { return false }
        return preview(for: record).localizedCaseInsensitiveContains(query)
    }
}

struct ClipboardPanelView: View {
    @Bindable var model: ClipboardPanelModel
    var panelHeight: CGFloat = 620
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredID: UUID?
    private var theme: SettingsTheme { SettingsTheme(colorScheme: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.pinnedMatches.isEmpty && model.ordinaryMatches.isEmpty {
                emptyState
            } else {
                List(selection: $model.selectedID) {
                    if !model.pinnedMatches.isEmpty {
                        Section("置顶") {
                            ForEach(model.pinnedMatches) { record in
                                recordRow(record)
                                    .tag(record.id)
                            }
                        }
                    }
                    if !model.ordinaryMatches.isEmpty {
                        Section("最近") {
                            ForEach(model.ordinaryMatches) { record in
                                recordRow(record)
                                    .tag(record.id)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .onKeyPress(.return) {
                    guard let selectedID = model.selectedID,
                          let record = (model.pinnedMatches + model.ordinaryMatches)
                            .first(where: { $0.id == selectedID }) else {
                        return .ignored
                    }
                    model.copy(record)
                    return .handled
                }
            }
            if let errorMessage = model.errorMessage {
                Divider()
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
            }
        }
        .frame(width: 540, height: panelHeight)
        .coordinateSpace(name: "clipboard.history")
        .background(theme.page)
        .mask { Rectangle().scaleEffect(x: max(0.002, model.reveal), y: 1) }
        .tint(NylaiPalette.accent)
        .onChange(of: model.selectedID) {
            guard hoveredID == nil else { return }
            model.onPreview(model.visibleRecords.first { $0.id == model.selectedID })
        }
        .onAppear { searchFocused = true }
        .onChange(of: model.searchText) {
            hoveredID = nil
            model.onPreview(nil)
            if !model.visibleRecords.contains(where: { $0.id == model.selectedID }) {
                model.selectedID = model.visibleRecords.first?.id
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(NylaiPalette.accent)
                    Text("剪贴板历史")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                }
                .overlay { ClipboardPanelDragArea() }
                Button {
                    model.onClose()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("关闭剪贴板历史")
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索文本或来源应用", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onKeyPress(.downArrow) {
                        model.selectNext(1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        model.selectNext(-1)
                        return .handled
                    }
                    .onKeyPress(.return) {
                        model.copySelectedOrFirst()
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        model.onClose()
                        return .handled
                    }
                if !model.searchText.isEmpty {
                    Button {
                        model.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.055))
            }
        }
        .padding(14)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(model.searchText.isEmpty ? "尚无剪贴板记录" : "没有匹配结果")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func recordRow(_ record: ClipboardRecord) -> some View {
        HStack(spacing: 11) {
            Button {
                model.copy(record)
            } label: {
                HStack(spacing: 11) {
                    preview(for: record)
                        .frame(width: 42, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.preview(for: record))
                            .font(.system(size: record.kind == .text ? 12.5 : 11.5))
                            .lineLimit(2)
                            .truncationMode(.tail)
                        HStack(spacing: 6) {
                            Text(record.sourceName ?? record.sourceBundleIdentifier ?? "来源未知")
                            Text("·")
                            Text(model.relativeTime(for: record.copiedAt))
                        }
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.togglePinned(record)
            } label: {
                Image(systemName: record.isPinned ? "pin.slash" : "pin")
            }
            .buttonStyle(.borderless)
            .help(record.isPinned ? "取消置顶" : "置顶")
            Button {
                model.delete(record)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除")
            if model.canDirectPaste {
                Button {
                    model.directPaste(record)
                } label: {
                    Image(systemName: "arrow.down.to.line.compact")
                }
                .buttonStyle(.borderless)
                .help("粘贴回原应用")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hoveredID == record.id ? NylaiPalette.accent.opacity(0.12) : .clear)
        }
        .background(ThinScrollIndicatorInstaller())
        .onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: .named("clipboard.history"))
        } action: { frame in
            model.rowFrames[record.id] = frame
            if hoveredID == record.id { model.onPreview(record) }
        }
        .onHover { hovering in
            if hovering {
                hoveredID = record.id
                model.onPreview(record)
            } else if hoveredID == record.id {
                hoveredID = nil
                model.onPreview(nil)
            }
        }
    }

    @ViewBuilder
    private func preview(for record: ClipboardRecord) -> some View {
        if record.kind == .image,
           let thumbnail = model.store.thumbnail(for: record) {
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 42, height: 42)
                .clipped()
        } else {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(0.055))
                .overlay {
                    Image(systemName: record.kind == .text ? "text.alignleft" : "photo")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
        }
    }
}

@MainActor
final class ClipboardPanelController: NSWindowController {
    private let store: ClipboardHistoryStore
    private let pasteboard: any ClipboardPasteboardAccessing
    private let directPaster: any ClipboardDirectPasting
    nonisolated private let notificationCenter: NotificationCenter
    private var lastExternalApplication: NSRunningApplication?
    nonisolated(unsafe) private var activationObserver: NSObjectProtocol?
    private var previewPanel: NSPanel?
    private var copyFeedback: Task<Void, Never>?
    private var transitionTask: Task<Void, Never>?
    private var toastPanel: NSPanel?

    init(
        store: ClipboardHistoryStore,
        pasteboard: any ClipboardPasteboardAccessing = SystemClipboardPasteboard(),
        directPaster: any ClipboardDirectPasting = SystemClipboardDirectPaster()
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.directPaster = directPaster
        notificationCenter = NSWorkspace.shared.notificationCenter
        super.init(window: nil)
        activationObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication
            Task { @MainActor in
                guard let application,
                      application.bundleIdentifier != Bundle.main.bundleIdentifier else {
                    return
                }
                self?.lastExternalApplication = application
            }
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalApplication = frontmost
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从归档创建剪贴板面板")
    }

    deinit {
        if let activationObserver {
            notificationCenter.removeObserver(activationObserver)
        }
    }

    override func close() {
        transitionTask?.cancel()
        transitionTask = nil
        dismissPreview()
        window?.orderOut(nil)
        window?.ignoresMouseEvents = false
    }

    func toggle() {
        if let window, window.isVisible, !window.ignoresMouseEvents,
           let host = window.contentView as? NSHostingView<ClipboardPanelView> {
            host.rootView.model.onClose()
        } else {
            present()
        }
    }

    func present() {
        if let window, window.isVisible, !window.ignoresMouseEvents {
            window.makeKeyAndOrderFront(nil)
            return
        }
        transitionTask?.cancel()
        dismissPreview()
        let target = NSWorkspace.shared.frontmostApplication.flatMap {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : $0
        } ?? lastExternalApplication
        let model = ClipboardPanelModel(
            store: store,
            pasteboard: pasteboard,
            targetApplication: target,
            directPaster: directPaster
        )
        let visible = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 900, height: 700)
        let height = min(620, max(220, visible.height - 24))
        let panel = (window as? ClipboardKeyPanel) ?? ClipboardKeyPanel(
            contentRect: CGRect(x: 0, y: 0, width: 540, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "剪贴板历史"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let hosting = NSHostingView(rootView: ClipboardPanelView(model: model, panelHeight: height))
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 12
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting
        panel.setFrame(CGRect(x: visible.midX - 270, y: visible.midY - height / 2,
                              width: 540, height: height), display: false)
        model.onPreview = { [weak self, weak panel, weak model] record in
            guard let self, let panel, let model else { return }
            let anchor = record.flatMap { model.rowFrames[$0.id] }.map { self.screenRect($0, in: panel) }
            self.showPreview(record, anchor: anchor, alongside: panel, visible: panel.screen?.visibleFrame ?? visible)
        }
        model.onClose = { [weak self, weak panel, weak model] in
            guard let self, let panel, let model else { return }
            self.animateClose(panel, model: model)
        }
        model.onCopied = { [weak self, weak panel, weak model] id in
            guard let self, let panel, let model else { return }
            let anchor = model.rowFrames[id].map { self.screenRect($0, in: panel) }
                ?? CGRect(x: panel.frame.midX, y: panel.frame.midY, width: 0, height: 0)
            self.close()
            self.showCopiedToast(at: anchor, visible: panel.screen?.visibleFrame ?? visible)
        }
        model.onError = { error in
            ClipboardDirectPasteErrorPresenter.show(error)
        }
        window = panel
        panel.ignoresMouseEvents = false
        let reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.reveal = reducesMotion ? 1 : 0
        panel.orderFrontRegardless()
        panel.makeKey()
        if !reducesMotion {
            transitionTask = Task { @MainActor [weak model] in
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, let model else { return }
                withAnimation(.easeOut(duration: 0.22)) { model.reveal = 1 }
            }
        }
    }

    private func screenRect(_ row: CGRect, in panel: NSPanel) -> CGRect {
        CGRect(x: panel.frame.minX + row.minX, y: panel.frame.maxY - row.maxY,
               width: row.width, height: row.height)
    }

    private func animateClose(_ panel: NSPanel, model: ClipboardPanelModel) {
        guard !panel.ignoresMouseEvents else { return }
        transitionTask?.cancel()
        dismissPreview()
        if model.reveal == 0 || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            close()
            return
        }
        panel.ignoresMouseEvents = true
        withAnimation(.easeIn(duration: 0.16)) { model.reveal = 0 }
        transitionTask = Task { @MainActor [weak self, weak panel] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled, let self, self.window === panel else { return }
            self.transitionTask = nil
            self.close()
        }
    }

    private func showCopiedToast(at anchor: CGRect, visible: CGRect) {
        copyFeedback?.cancel()
        toastPanel?.orderOut(nil)
        let host = NSHostingView(rootView: Label("已复制", systemImage: "checkmark.circle.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(NylaiPalette.accent)
            .padding(.horizontal, 15).padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule()))
        let size = host.fittingSize
        let origin = CGPoint(
            x: min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8),
            y: min(max(anchor.maxY + 5, visible.minY + 8), visible.maxY - size.height - 8)
        )
        let toast = NSPanel(contentRect: CGRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        toast.isReleasedWhenClosed = false
        toast.ignoresMouseEvents = true
        toast.isOpaque = false
        toast.backgroundColor = .clear
        toast.level = .floating
        toast.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        toast.contentView = host
        toastPanel = toast
        toast.orderFrontRegardless()
        copyFeedback = Task { @MainActor [weak self, weak toast] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self, self.toastPanel === toast else { return }
            toast?.orderOut(nil)
            self.toastPanel = nil
        }
    }

    private func dismissPreview() {
        guard let previewPanel else { return }
        previewPanel.parent?.removeChildWindow(previewPanel)
        previewPanel.orderOut(nil)
        self.previewPanel = nil
    }

    private func showPreview(_ record: ClipboardRecord?, anchor: CGRect?, alongside panel: NSPanel, visible: CGRect) {
        dismissPreview()
        guard let record, panel.isVisible else { return }
        let frame = panel.frame
        let row = anchor ?? frame
        let gap: CGFloat = 10
        let left = frame.minX - visible.minX - gap - 8
        let right = visible.maxX - frame.maxX - gap - 8
        let above = visible.maxY - frame.maxY - gap - 8
        let below = frame.minY - visible.minY - gap - 8
        let useSide = max(left, right) >= 170
        let useLeft = left >= 275 || left >= right
        let useAbove = above >= below
        guard useSide || max(above, below) >= 105 else { return }
        let width = useSide ? min(300, useLeft ? left : right) : min(330, frame.width)
        let height = useSide ? min(290, visible.height - 16) : min(240, max(above, below))
        let origin = CGPoint(
            x: useSide ? (useLeft ? frame.minX - gap - width : frame.maxX + gap) : min(max(row.midX - width / 2, visible.minX + 8), visible.maxX - width - 8),
            y: useSide ? max(visible.minY + 8, min(row.midY - height / 2, visible.maxY - height - 8))
                : (useAbove ? frame.maxY + gap : frame.minY - gap - height)
        )
        let preview = NSPanel(
            contentRect: CGRect(origin: origin, size: CGSize(width: width, height: height)),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        preview.isReleasedWhenClosed = false
        preview.ignoresMouseEvents = true
        preview.isOpaque = false
        preview.backgroundColor = .clear
        preview.hasShadow = true
        let host = NSHostingController(rootView: ClipboardRecordPreview(
            content: store.content(for: record), size: CGSize(width: width, height: height)
        ))
        preview.contentViewController = host
        panel.addChildWindow(preview, ordered: .above)
        preview.orderFrontRegardless()
        previewPanel = preview
    }

}

private struct ClipboardPanelDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

private final class ClipboardKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct ClipboardRecordPreview: View {
    let content: ClipboardContent?
    let size: CGSize
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = SettingsTheme(colorScheme: colorScheme)
        Group {
            switch content {
            case .text(let text):
                GeometryReader { geometry in
                    Text(String(text.prefix(1800)))
                        .font(.system(size: 12))
                        .lineSpacing(3)
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                        .clipped()
                }
            case .image(let image):
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            case nil:
                Text("无法预览").foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .frame(width: size.width, height: size.height)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(theme.border, lineWidth: 1) }
    }
}

enum ClipboardDirectPasteErrorPresenter {
    @MainActor
    static func show(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "无法直接粘贴"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
