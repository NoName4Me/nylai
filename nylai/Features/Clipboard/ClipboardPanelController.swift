import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class ClipboardPanelModel {
    let groups: ClipboardGroupsStore?
    var selectedGroupID: UUID?
    var groupDraft: ClipboardGroup?
    var isPinned = false
    var isSelecting = false
    var checkedIDs: Set<UUID> = []
    var joinWithSpace = false
    enum Section: String, CaseIterable { case history, snippets }
    var section = Section.history
    let snippets: SnippetStore?
    var snippetDraft: SavedSnippet?
    var snippetMatches: [SavedSnippet] { snippets?.matches(searchText) ?? [] }
    let store: ClipboardHistoryStore
    let pasteboard: any ClipboardPasteboardAccessing
    let targetApplication: NSRunningApplication?
    var searchText = ""
    var selectedID: UUID?
    var errorMessage: String?
    var confirmsClearHistory = false
    var onClose: () -> Void = {}
    var onCopied: ((UUID) -> Void)?
    var reveal: CGFloat = 0
    var rowFrames: [UUID: CGRect] = [:]
    let openedAt = Date()
    private let timeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = L10n.shared.locale
        return formatter
    }()

    func relativeTime(for date: Date) -> String {
        if date.timeIntervalSince(openedAt) > -60 { return L10n.shared.string("刚刚") }
        return timeFormatter.localizedString(for: date, relativeTo: openedAt)
    }
    var onPreview: (ClipboardRecord?) -> Void = { _ in }
    var onError: @MainActor (Error) -> Void = { _ in }
    private let directPaster: any ClipboardDirectPasting
    private var textCache: [UUID: String] = [:]

    init(
        store: ClipboardHistoryStore,
        pasteboard: any ClipboardPasteboardAccessing,
        targetApplication: NSRunningApplication?,
        directPaster: any ClipboardDirectPasting = SystemClipboardDirectPaster(),
        snippets: SnippetStore? = nil,
        groups: ClipboardGroupsStore? = nil
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.targetApplication = targetApplication
        self.directPaster = directPaster
        self.snippets = snippets
        self.groups = groups
    }

    var pinnedMatches: [ClipboardRecord] {
        store.pinnedRecords.filter(matches)
    }

    var ordinaryMatches: [ClipboardRecord] {
        store.ordinaryRecords.filter(matches)
    }

    var canDirectPaste: Bool {
        targetApplication?.bundleIdentifier != nil && targetApplication?.isTerminated == false
            && targetApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
    }

    var visibleRecords: [ClipboardRecord] {
        let records = groups == nil ? store.allRecords : store.allRecords.sorted { $0.copiedAt > $1.copiedAt }
        let members = groups?.groups.first { $0.id == selectedGroupID }?.recordIDs
        return records.filter { (selectedGroupID == nil || members?.contains($0.id) == true) && matches($0) }
    }

    var checkedRecords: [ClipboardRecord] { visibleRecords.filter { checkedIDs.contains($0.id) && $0.kind == .text } }

    func choose(_ record: ClipboardRecord, modifiers: NSEvent.ModifierFlags = []) {
        if isSelecting || modifiers.contains(.command) || modifiers.contains(.shift) {
            isSelecting = true
            guard record.kind == .text else { return }
            if modifiers.contains(.shift), let anchor = selectedID,
               let first = visibleRecords.firstIndex(where: { $0.id == anchor }),
               let last = visibleRecords.firstIndex(where: { $0.id == record.id }) {
                checkedIDs.formUnion(visibleRecords[min(first, last)...max(first, last)].filter { $0.kind == .text }.map(\.id))
            } else if !checkedIDs.insert(record.id).inserted { checkedIDs.remove(record.id) }
            selectedID = record.id
        } else { copy(record) }
    }

    func assign(_ ids: Set<UUID>, to group: ClipboardGroup, included: Bool = true) {
        do { try groups?.setMembership(ids, groupID: group.id, included: included, history: store) }
        catch { errorMessage = error.localizedDescription }
    }

    func copyChecked(paste: Bool = false) {
        let records = checkedRecords
        guard !records.isEmpty else { return }
        let bodies = records.compactMap { store.text(for: $0) }
        guard bodies.count == records.count else { errorMessage = ClipboardStoreError.recordNotFound.localizedDescription; return }
        let text = bodies.joined(separator: joinWithSpace ? " " : "\n")
        copyContent(.text(text), id: records[0].id, paste: paste)
    }

    private func copyContent(_ content: ClipboardContent, id: UUID, paste: Bool) {
        do {
            if paste, !canDirectPaste { throw ClipboardDirectPasteError.targetUnavailable }
            try pasteboard.write(content, sourceBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.noname4me.nylai")
            errorMessage = nil
            if paste, let targetApplication, let bundleIdentifier = targetApplication.bundleIdentifier {
                let count = pasteboard.changeCount
                if !isPinned { onClose() }
                Task { [self] in
                    let result = await directPaster.pasteAfterActivating(target: targetApplication, expectedBundleIdentifier: bundleIdentifier,
                                                                        expectedChangeCount: count, pasteboard: pasteboard)
                    if case .failure(let error) = result { onError(error) }
                }
            } else if let onCopied { onCopied(id) } else if !isPinned { onClose() }
        } catch { errorMessage = error.localizedDescription }
    }

    func selectNext(_ offset: Int) {
        if section == .snippets {
            let ids = snippetMatches.map(\.id)
            guard !ids.isEmpty else { selectedID = nil; return }
            let index = selectedID.flatMap { ids.firstIndex(of: $0) }
            selectedID = ids[min(max((index ?? (offset < 0 ? ids.count : -1)) + offset, 0), ids.count - 1)]
            return
        }
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
        if isSelecting { copyChecked(); return }
        if section == .snippets {
            if let snippet = snippetMatches.first(where: { $0.id == selectedID }) ?? snippetMatches.first { copySnippet(snippet) }
            return
        }
        guard let record = visibleRecords.first(where: { $0.id == selectedID })
            ?? visibleRecords.first else {
            return
        }
        copy(record)
    }

    func preview(for record: ClipboardRecord) -> String {
        switch record.kind {
        case .image:
            return L10n.shared.string(
                "%@ × %@ 图片",
                String(record.pixelWidth ?? 0),
                String(record.pixelHeight ?? 0)
            )
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
            if let onCopied { onCopied(record.id) } else if !isPinned { onClose() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveAsSnippet(_ record: ClipboardRecord) {
        guard record.kind == .text, let text = store.text(for: record) else { return }
        snippetDraft = SavedSnippet(name: String((text.components(separatedBy: .newlines).first ?? "").prefix(40)), group: "", text: text)
        onPreview(nil)
    }

    func copySnippet(_ snippet: SavedSnippet, paste: Bool = false) {
        do {
            try pasteboard.write(.text(snippet.text), sourceBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.noname4me.nylai")
            errorMessage = nil
            if paste {
                guard let targetApplication, let bundle = targetApplication.bundleIdentifier else {
                    throw ClipboardDirectPasteError.targetUnavailable
                }
                let changeCount = pasteboard.changeCount
                onClose()
                Task { [self] in
                    let result = await directPaster.pasteAfterActivating(target: targetApplication, expectedBundleIdentifier: bundle,
                                                                        expectedChangeCount: changeCount, pasteboard: pasteboard)
                    if case .failure(let error) = result { onError(error) }
                }
            } else if let onCopied { onCopied(snippet.id) } else { onClose() }
        } catch { errorMessage = error.localizedDescription }
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
            if !isPinned { onClose() }
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

    func clearHistory() {
        do {
            try groups?.clearAllMemberships()
            try store.clearAll()
            finishClear()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var clearActionHelp: String {
        if let group = groups?.groups.first(where: { $0.id == selectedGroupID }) {
            return L10n.shared.string("清空分组“%@”", group.name)
        }
        return L10n.shared.string("清空全部剪贴板历史")
    }

    var clearConfirmationTitle: String {
        if let group = groups?.groups.first(where: { $0.id == selectedGroupID }) {
            return L10n.shared.string("清空分组“%@”？", group.name)
        }
        return L10n.shared.string("清空全部剪贴板历史？")
    }

    var clearConfirmationActionTitle: String {
        L10n.shared.string("清空")
    }

    var clearConfirmationMessage: String {
        if let group = groups?.groups.first(where: { $0.id == selectedGroupID }) {
            return L10n.shared.string("“%@”中的记录会从本机删除，不会修改系统剪贴板当前内容。", group.name)
        }
        return L10n.shared.string("所有记录都会从本机删除，不会修改系统剪贴板当前内容。")
    }

    func clearCurrentScope() {
        guard let groupID = selectedGroupID,
              let groups,
              let group = groups.groups.first(where: { $0.id == groupID }) else {
            clearHistory()
            return
        }
        do {
            try groups.clearMembers(of: group.id, history: store)
            finishClear()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func finishClear() {
        checkedIDs = []
        selectedID = nil
        searchText = ""
        onPreview(nil)
        errorMessage = nil
    }

    private func matches(_ record: ClipboardRecord) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        if record.sourceName?.localizedCaseInsensitiveContains(query) == true
            || record.sourceBundleIdentifier?.localizedCaseInsensitiveContains(query) == true {
            return true
        }
        if groups?.name(for: record.id)?.localizedCaseInsensitiveContains(query) == true { return true }
        guard record.kind == .text else { return false }
        return preview(for: record).localizedCaseInsensitiveContains(query)
    }
}

@MainActor
final class ClipboardPanelController: NSWindowController, NSWindowDelegate {
    private let groups: ClipboardGroupsStore?
    nonisolated(unsafe) private var outsideLocalMonitor: Any?
    nonisolated(unsafe) private var outsideGlobalMonitor: Any?
    private let snippets: SnippetStore?
    private let snippetLoadError: String?
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
    private(set) var activeModel: ClipboardPanelModel?

    init(
        store: ClipboardHistoryStore,
        pasteboard: any ClipboardPasteboardAccessing = SystemClipboardPasteboard(),
        directPaster: any ClipboardDirectPasting = SystemClipboardDirectPaster()
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.directPaster = directPaster
        do {
            let legacy = try SnippetStore(fileURL: store.directoryURL.appendingPathComponent("snippets.json"))
            let categories = try ClipboardGroupsStore(fileURL: store.directoryURL.appendingPathComponent("groups.json"))
            try categories.migrateLegacyItems(history: store, snippets: legacy)
            snippets = legacy
            groups = categories
            snippetLoadError = nil
        } catch {
            snippets = nil
            groups = nil
            snippetLoadError = error.localizedDescription
        }
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
                self?.dismissIfOutside(nil)
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
        if let outsideLocalMonitor { NSEvent.removeMonitor(outsideLocalMonitor) }
        if let outsideGlobalMonitor { NSEvent.removeMonitor(outsideGlobalMonitor) }
        if let activationObserver {
            notificationCenter.removeObserver(activationObserver)
        }
    }

    override func close() {
        removeOutsideMonitors()
        transitionTask?.cancel()
        transitionTask = nil
        dismissPreview()
        window?.orderOut(nil)
        window?.ignoresMouseEvents = false
        activeModel = nil
    }

    func toggle() {
        if let window, window.isVisible, !window.ignoresMouseEvents,
           let activeModel {
            if activeModel.isPinned { window.makeKeyAndOrderFront(nil) }
            else { activeModel.onClose() }
        } else {
            present()
        }
    }

    func refreshLocalization() {
        window?.title = L10n.shared.string("剪贴板历史")
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
            directPaster: directPaster,
            snippets: snippets,
            groups: groups
        )
        activeModel = model
        model.errorMessage = snippetLoadError
        let visible = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 900, height: 700)
        let height = min(620, max(220, visible.height - 24))
        let panel = (window as? ClipboardKeyPanel) ?? ClipboardKeyPanel(
            contentRect: CGRect(x: 0, y: 0, width: 540, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.shared.string("剪贴板历史")
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let hosting = NSHostingView(
            rootView: ClipboardPanelView(model: model, panelHeight: height)
                .nylaiLocalized()
        )
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
            if !model.isPinned { self.close() }
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
        installOutsideMonitors()
        if !reducesMotion {
            transitionTask = Task { @MainActor [weak model] in
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, let model else { return }
                withAnimation(.easeOut(duration: 0.22)) { model.reveal = 1 }
            }
        }
    }

    private func removeOutsideMonitors() {
        if let outsideLocalMonitor { NSEvent.removeMonitor(outsideLocalMonitor) }
        if let outsideGlobalMonitor { NSEvent.removeMonitor(outsideGlobalMonitor) }
        outsideLocalMonitor = nil
        outsideGlobalMonitor = nil
    }

    private func dismissIfOutside(_ clickedWindow: NSWindow?) {
        guard let panel = window, panel.isVisible, let model = activeModel, !model.isPinned,
              model.groupDraft == nil, panel.attachedSheet == nil else { return }
        var candidate = clickedWindow
        while let current = candidate {
            if current === panel { return }
            candidate = current.parent
        }
        if let clickedWindow, clickedWindow.level.rawValue >= NSWindow.Level.popUpMenu.rawValue { return }
        close()
    }

    private func installOutsideMonitors() {
        removeOutsideMonitors()
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        outsideGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            Task { @MainActor in self?.dismissIfOutside(nil) }
        }
        outsideLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.dismissIfOutside(event.window) }
            return event
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        dismissIfOutside(NSApp.keyWindow)
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
        let host = NSHostingView(rootView: Label(
            L10n.shared.string("已复制"),
            systemImage: "checkmark.circle.fill"
        )
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
        let availableWidth = useSide ? (useLeft ? left : right) : min(visible.width - 16, frame.width)
        let availableHeight = useSide ? visible.height - 16 : max(above, below)
        let requestedSize = ClipboardPreviewLayout.size(
            for: store.content(for: record),
            available: CGSize(width: availableWidth, height: availableHeight)
        )
        let width = requestedSize.width
        let height = requestedSize.height
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
        let host = NSHostingController(
            rootView: ClipboardRecordPreview(
                content: store.content(for: record),
                size: CGSize(width: width, height: height)
            ).nylaiLocalized()
        )
        preview.contentViewController = host
        panel.addChildWindow(preview, ordered: .above)
        preview.orderFrontRegardless()
        previewPanel = preview
    }

}

enum ClipboardPreviewLayout {
    static func size(for content: ClipboardContent?, available: CGSize) -> CGSize {
        let maximumWidth = min(420, max(240, available.width))
        let maximumHeight = min(360, max(180, available.height))
        guard case .image(let image) = content, image.width > 0, image.height > 0 else {
            return CGSize(width: maximumWidth, height: min(280, maximumHeight))
        }
        let aspect = CGFloat(image.width) / CGFloat(image.height)
        let width = min(maximumWidth, maximumHeight * aspect, max(1, available.width))
        let height = width / aspect
        return CGSize(width: width, height: height)
    }
}

struct ClipboardPanelDragArea: NSViewRepresentable {
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
        alert.messageText = L10n.shared.string("无法直接粘贴")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L10n.shared.string("好"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
