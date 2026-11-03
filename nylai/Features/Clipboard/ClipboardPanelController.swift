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
            onClose()
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
    @FocusState private var searchFocused: Bool

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
        .frame(width: 540, height: 620)
        .onAppear { searchFocused = true }
        .onChange(of: model.searchText) {
            if !model.visibleRecords.contains(where: { $0.id == model.selectedID }) {
                model.selectedID = model.visibleRecords.first?.id
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("剪贴板历史")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    model.onClose()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
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
                            Text(record.copiedAt, style: .relative)
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
        .padding(.vertical, 4)
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
    private var lastExternalApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?

    init(
        store: ClipboardHistoryStore,
        pasteboard: any ClipboardPasteboardAccessing = SystemClipboardPasteboard(),
        directPaster: any ClipboardDirectPasting = SystemClipboardDirectPaster()
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.directPaster = directPaster
        super.init(window: nil)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
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

    isolated deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    func present() {
        if window != nil {
            window?.close()
            window = nil
        }
        let target = NSWorkspace.shared.frontmostApplication.flatMap {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : $0
        } ?? lastExternalApplication
        let model = ClipboardPanelModel(
            store: store,
            pasteboard: pasteboard,
            targetApplication: target,
            directPaster: directPaster
        )
        let hosting = NSHostingController(rootView: ClipboardPanelView(model: model))
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 540, height: 620),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "剪贴板历史"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = hosting
        panel.center()
        model.onClose = { [weak self, weak panel] in
            panel?.orderOut(nil)
            self?.window = nil
        }
        model.onError = { error in
            ClipboardDirectPasteErrorPresenter.show(error)
        }
        window = panel
        panel.orderFrontRegardless()
        panel.makeKey()
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
