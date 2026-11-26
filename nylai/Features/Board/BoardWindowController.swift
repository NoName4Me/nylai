import AppKit
import SwiftUI

@MainActor
final class BoardWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private let titleItemID = NSToolbarItem.Identifier("nylai.board.title")
    let store = BoardStore()
    private lazy var session = BoardSession(store: store)
    private var window: NSWindow?
    private var notes: [UUID: NSPanel] = [:]

    func present(boardID: UUID? = nil, itemID: UUID? = nil) {
        if let boardID { session.switchBoard(boardID) }
        if let itemID { session.focus(itemID) }
        if window == nil {
            let value = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 720),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                 backing: .buffered, defer: false)
            value.minSize = CGSize(width: 660, height: 420)
            value.isReleasedWhenClosed = false
            value.title = ""
            value.titleVisibility = .hidden
            value.titlebarAppearsTransparent = false
            let toolbar = NSToolbar(identifier: "nylai.board.toolbar")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            toolbar.centeredItemIdentifier = titleItemID
            value.toolbar = toolbar
            value.toolbarStyle = .unifiedCompact
            value.isMovableByWindowBackground = true
            value.delegate = self
            value.center()
            value.setFrameAutosaveName("nylai.board")
            session.onPinNote = { [weak self] board, item in self?.pinNote(board: board, item: item) }
            value.contentView = NSHostingView(rootView: BoardWorkspace(session: session, float: { [weak self] in self?.toggleFloating() }).nylaiLocalized())
            window = value
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, titleItemID]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, titleItemID, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == titleItemID else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = L10n.shared.string("画布")
        let view = NSHostingView(rootView: BoardTitleMenu(session: session,
            rename: { [weak self] in self?.requestBoardName(creating: false) },
            create: { [weak self] in self?.requestBoardName(creating: true) },
            delete: { [weak self] in self?.confirmDelete() }).nylaiLocalized())
        view.frame = CGRect(x: 0, y: 0, width: 220, height: 28)
        item.view = view
        item.minSize = CGSize(width: 170, height: 28)
        item.maxSize = CGSize(width: 220, height: 28)
        return item
    }

    private func requestBoardName(creating: Bool) {
        session.finishEditing()
        let alert = NSAlert()
        alert.messageText = L10n.shared.string(creating ? "新建画布" : "重命名画布")
        alert.addButton(withTitle: L10n.shared.string("确定"))
        alert.addButton(withTitle: L10n.shared.string("取消"))
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = creating ? "" : session.board.title
        field.placeholderString = L10n.shared.string("名称")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        if creating {
            session.selection = []
            store.create(title)
        } else { store.editBoard(session.board.id) { $0.title = title } }
    }

    private func confirmDelete() {
        session.finishEditing()
        guard store.library.boards.count > 1 else { return }
        let alert = NSAlert()
        alert.messageText = L10n.shared.string("删除当前画布？")
        alert.addButton(withTitle: L10n.shared.string("删除"))
        alert.addButton(withTitle: L10n.shared.string("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        session.selection = []
        store.delete(session.board.id)
    }

    @discardableResult
    func add(_ content: ClipboardContent, boardID: UUID? = nil) -> Bool {
        let id = boardID ?? store.library.defaultID
        let point = store.nextCapturePoint(in: id)
        switch content {
        case .text(let text):
            let item = store.addText(text, boardID: id, at: point)
            return store.document(id)?.items.contains { $0.id == item } == true
        case .image(let image):
            return store.addImage(NSImage(cgImage: image, size: .zero), boardID: id, at: point)
        }
    }

    func chooseDestination(for contents: [ClipboardContent]) {
        guard !contents.isEmpty, store.loadError == nil else { return }
        let alert = NSAlert()
        alert.messageText = L10n.shared.string("发送到画布")
        alert.addButton(withTitle: L10n.shared.string("添加"))
        alert.addButton(withTitle: L10n.shared.string("取消"))
        let picker = NSPopUpButton(frame: CGRect(x: 0, y: 0, width: 280, height: 26))
        let boards = store.library.boards
        picker.addItems(withTitles: boards.map(\.title))
        picker.selectItem(at: boards.firstIndex(where: { $0.id == store.library.defaultID }) ?? 0)
        alert.accessoryView = picker
        guard alert.runModal() == .alertFirstButtonReturn,
              boards.indices.contains(picker.indexOfSelectedItem) else { return }
        let id = boards[picker.indexOfSelectedItem].id
        for content in contents {
            if !add(content, boardID: id) {
                let failure = NSAlert()
                failure.messageText = store.error ?? L10n.shared.string("画布数据无效，原文件已保留。")
                failure.runModal()
                break
            }
        }
    }

    private func toggleFloating() {
        session.floating.toggle()
        window?.level = session.floating ? .floating : .normal
        window?.collectionBehavior = session.floating ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
    }

    private func pinNote(board: UUID, item: UUID) {
        if let existing = notes[item] { existing.makeKeyAndOrderFront(nil); return }
        guard store.document(board)?.items.contains(where: { $0.id == item && $0.kind == .note }) == true else { return }
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 260, height: 230),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = L10n.shared.string("便签")
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: BoardPinnedNote(store: store, boardID: board, itemID: item).nylaiLocalized())
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        notes[item] = panel
    }

    func close() {
        session.finishEditing()
        store.stop()
        window?.close()
        for panel in notes.values { panel.close() }
        notes.removeAll()
        window = nil
    }

    func refreshLocalization() {
        for panel in notes.values { panel.title = L10n.shared.string("便签") }
    }
    func windowWillClose(_ notification: Notification) { session.finishEditing(); store.flush() }
    func windowDidResignKey(_ notification: Notification) { session.finishEditing() }
}

struct BoardWorkspace: View {
    @Bindable var session: BoardSession
    let float: () -> Void
    @State private var query = ""
    @State private var shortcutsShown = false
    @State private var searching = false
    @FocusState private var searchFocused: Bool

    private var board: BoardDocument { session.board }
    private var matches: [BoardItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? [] : board.items.filter { $0.searchableText.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                BoardCanvasRepresentable(session: session, board: board, selection: session.selection, tool: session.tool, editingID: session.editingID)
                    .id(board.id)
                if board.items.isEmpty {
                    VStack(spacing: 8) {
                        Text("双击新建便签，或直接粘贴图片与文字")
                            .font(.callout)
                        Text("空格拖动平移 · ⌘ + 滚动缩放")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                }
                if searching && !query.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("搜索结果").font(.caption).foregroundStyle(.secondary)
                        if matches.isEmpty { Text("没有匹配内容").foregroundStyle(.secondary) }
                        ForEach(matches.prefix(15)) { item in
                            Button { session.focus(item.id) } label: {
                                Text(item.searchableText.isEmpty ? L10n.shared.string("图片") : item.searchableText)
                                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                    }.padding(12).frame(width: 260).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(.trailing, 16).padding(.bottom, 100)
                }
                toolbar.padding(.bottom, 14)
            }
        }
        .frame(minWidth: 660, minHeight: 420)
        .onChange(of: board.id) { _, _ in query = ""; searching = false }
        .alert("画布", isPresented: Binding(get: { session.store.error != nil }, set: { if !$0 { session.store.error = nil } })) {
            Button("确定") { session.store.error = nil }
        } message: { Text(session.store.error ?? "") }
        .overlay {
            if let error = session.store.loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.title)
                    Text(error)
                    Text("原数据文件已保留。").foregroundStyle(.secondary)
                }.padding(30).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func toolButton(_ tool: BoardTool, group: Bool = false) -> some View {
        Button { session.chooseTool(tool) } label: {
            Image(systemName: tool.symbol)
                .frame(width: 24, height: 26)
                .background((group ? session.tool.isShape : session.tool == tool) ? Color.accentColor.opacity(0.17) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .overlay(alignment: .topTrailing) {
                    if session.showsToolShortcuts {
                        Text(tool.shortcut).font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .padding(2).background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 3))
                            .offset(x: 5, y: -7)
                    }
                }
        }.buttonStyle(.plain).help(tool.title + " · " + tool.shortcut)
    }

    private var toolbar: some View {
        VStack(spacing: 6) {
            if !session.toolbarCollapsed {
                if session.tool.showsDrawingStyle || session.showsToolShortcuts { drawingStyleBar }
                HStack(spacing: 4) {
                    ForEach(BoardTool.allCases.filter { !$0.isShape }) { tool in
                        toolButton(tool)
                    }
                    toolButton(session.lastShape, group: true)
                    Divider().frame(height: 22)
                    Button { session.undo(); session.focusCanvas?() } label: { Image(systemName: "arrow.uturn.backward") }
                        .disabled(session.store.undoStack.isEmpty).help("撤销")
                    Button { session.redo(); session.focusCanvas?() } label: { Image(systemName: "arrow.uturn.forward") }
                        .disabled(session.store.redoStack.isEmpty).help("重做")
                    Button { session.confirmClear(); session.focusCanvas?() } label: { Image(systemName: "trash") }
                        .disabled(board.items.isEmpty).help("清空画布")
                    Menu {
                        Button("粘贴") { session.paste() }
                        Button("复制") { session.copy() }.disabled(session.selection.isEmpty)
                        Button("编组") { session.group() }.disabled(session.selection.count < 2)
                        Button("取消编组") { session.ungroup() }.disabled(session.selection.isEmpty)
                        Button("锁定 / 解锁") { session.toggleLock() }.disabled(session.selection.isEmpty)
                        Button("移到最前") { session.layer(front: true) }.disabled(session.selection.isEmpty)
                        Button("移到最后") { session.layer(front: false) }.disabled(session.selection.isEmpty)
                        Button("置顶便签") {
                            if let item = session.selected.first { session.onPinNote?(board.id, item.id) }
                        }.disabled(session.selected.count != 1 || session.selected.first?.kind != .note)
                        Button("删除", role: .destructive) { session.delete() }.disabled(session.selection.isEmpty)
                        Divider()
                        Button("置顶画布", action: float)
                        Button("导出 PNG") { session.export() }
                        Toggle("自动吸附", isOn: $session.snap)
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                    Divider().frame(height: 22)
                    Button { session.zoom(0.8); session.focusCanvas?() } label: { Image(systemName: "minus") }
                    Button { session.resetZoom(); session.focusCanvas?() } label: { Text("\(Int(board.viewport.zoom * 100))%").monospacedDigit().font(.caption) }
                        .help("100% 并居中")
                    Button { session.zoom(1.25); session.focusCanvas?() } label: { Image(systemName: "plus") }
                    Button { session.fit(); session.focusCanvas?() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("适应全部")
                    Divider().frame(height: 22)
                    HStack(spacing: 3) {
                        Button {
                            searching.toggle()
                            if searching {
                                session.finishEditing()
                                searchFocused = true
                            } else { query = ""; session.focusCanvas?() }
                        } label: { Image(systemName: "magnifyingglass") }.help("搜索当前画布")
                        if searching {
                            TextField("搜索", text: $query).textFieldStyle(.plain).font(.system(size: 12))
                                .focused($searchFocused).frame(width: 104)
                                .onSubmit { if let item = matches.first { session.focus(item.id); session.focusCanvas?() } }
                                .onExitCommand { searching = false; query = ""; session.focusCanvas?() }
                        }
                    }
                    .padding(searching ? 3 : 0)
                    .background(searching ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    Button { session.finishEditing(); shortcutsShown.toggle() } label: { Image(systemName: "questionmark.circle") }
                        .help("画布快捷键").popover(isPresented: $shortcutsShown) { shortcutHelp }
                    Divider().frame(height: 22)
                    Button {
                        searching = false; query = ""; session.toolbarCollapsed = true
                        session.focusCanvas?()
                    } label: { Image(systemName: "chevron.down") }.help("收起工具栏")
                }
                .buttonStyle(.borderless)
                .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)) }
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            } else {
                Button { session.toolbarCollapsed = false; session.focusCanvas?() } label: {
                    Image(systemName: "chevron.up").frame(width: 40, height: 23)
                }.buttonStyle(.plain).background(.regularMaterial, in: Capsule())
                    .overlay { Capsule().strokeBorder(Color.primary.opacity(0.12)) }.help("展开工具栏")
            }
        }
    }

    private var drawingStyleBar: some View {
        HStack(spacing: 5) {
            if session.tool.isShape || session.showsToolShortcuts {
                ForEach(BoardTool.shapes) { shape in toolButton(shape) }
                if session.tool.showsDrawingStyle { Divider().frame(height: 20) }
            }
            if session.tool.showsDrawingStyle {
                ForEach(BoardColor.drawingColors) { color in
                    Button { session.color = color; session.focusCanvas?() } label: {
                        Circle().fill(Color(nsColor: color.ink)).frame(width: 14, height: 14)
                            .overlay { Circle().strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.75) }
                            .padding(3)
                            .overlay { Circle().strokeBorder(session.color == color ? Color.accentColor : .clear, lineWidth: 1.5) }
                    }.buttonStyle(.plain).help(color.title)
                }
                Button { session.translucent.toggle(); session.focusCanvas?() } label: {
                    Image(systemName: "circle.lefthalf.filled").frame(width: 26, height: 26)
                        .background(session.translucent ? Color.accentColor.opacity(0.17) : .clear, in: RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain).help(session.translucent ? "关闭半透明" : "开启半透明")
                Divider().frame(height: 20)
                ForEach([CGFloat(2), 4, 6, 10], id: \.self) { width in
                    Button { session.strokeWidth = width; session.focusCanvas?() } label: {
                        Circle().fill(Color.primary).frame(width: width + 2, height: width + 2)
                            .frame(width: 24, height: 26)
                            .background(session.strokeWidth == width ? Color.accentColor.opacity(0.17) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain).help("\(Int(width)) pt")
                }
                Divider().frame(height: 20)
                Button { session.dashed.toggle(); session.focusCanvas?() } label: {
                    HStack(spacing: 2) {
                        ForEach(0..<3) { _ in Capsule().fill(Color.primary).frame(width: 5, height: 2) }
                    }.frame(width: 26, height: 26)
                        .background(session.dashed ? Color.accentColor.opacity(0.17) : .clear, in: RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain).help("虚线")
                if session.tool.isShape {
                    Button { session.filled.toggle(); session.focusCanvas?() } label: {
                        Image(systemName: "paintbucket").frame(width: 26, height: 26)
                            .background(session.filled ? Color.accentColor.opacity(0.17) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain).help("填充")
                }
            }
        }.padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.12)) }
    }

    private var shortcutHelp: some View {
        let rows = [("␣ + 拖动", "平移"), ("⌘ + 滚动 / 捏合", "缩放"), ("⌘0", "100% 并居中"), ("⌘⇧0", "适应全部"), ("⌘+ / ⌘−", "缩放"), ("⇧ + 点击", "多选"), ("⌘A", "全选"), ("⌘C / ⌘V", "复制 / 粘贴"), ("⌘Z / ⌘⇧Z", "撤销 / 重做"), ("⌘G / ⌘⇧G", "编组 / 取消编组"), ("← ↑ ↓ → / ⇧", "移动 / 加速移动"), ("⌥ + 拖动", "临时关闭吸附"), ("⌫ / ⌦", "删除"), ("⎋", "取消选择 / 完成便签编辑"), ("⌘↩", "完成便签编辑"), ("⌃ + 拖动", "正形 / 45° 约束"), ("⇧ + 拖动线条", "水平 / 垂直"), ("⌥", "显示工具快捷键"), ("双击", "新建 / 编辑便签或预览图片")]
        return ScrollView {
            VStack(alignment: .leading, spacing: 6) {
            Text("画布快捷键").font(.headline)
            ForEach(BoardTool.allCases) { tool in
                HStack { Text(tool.title).font(.caption); Spacer(); Text(tool.shortcut).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
            }
            Divider()
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: 18) {
                    Text(L10n.shared.string(rows[index].1)).font(.callout)
                    Spacer()
                    Text(L10n.shared.string(rows[index].0)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            }.padding(16)
        }.frame(width: 360, height: 440)
    }
}

private struct BoardTitleMenu: View {
    @Bindable var session: BoardSession
    let rename: () -> Void
    let create: () -> Void
    let delete: () -> Void

    var body: some View {
        Menu {
            ForEach(session.store.library.boards) { document in
                Button {
                    session.switchBoard(document.id)
                } label: {
                    if document.id == session.board.id { Label(document.title, systemImage: "checkmark") }
                    else { Text(document.title) }
                }
            }
            Divider()
            Button("新建画布", action: create)
            Button("重命名", action: rename)
            Button("设为默认画布") { session.store.makeDefault(session.board.id) }
                .disabled(session.store.library.defaultID == session.board.id)
            Button("删除画布", role: .destructive, action: delete)
                .disabled(session.store.library.boards.count <= 1)
        } label: {
            HStack(spacing: 5) {
                Text(session.board.title).lineLimit(1).font(.system(size: 13, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium))
            }.foregroundStyle(.primary).frame(maxWidth: .infinity)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 220, height: 28)
        .accessibilityLabel(session.board.title)
    }
}

private struct BoardMarkdownContent: View {
    let text: String
    let change: (String) -> Void
    var body: some View {
        let lines = text.components(separatedBy: "\n")
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(lines.indices, id: \.self) { index in
                    let line = lines[index]
                    if line.hasPrefix("- [ ] ") || line.lowercased().hasPrefix("- [x] ") {
                        let checked = line.lowercased().hasPrefix("- [x] ")
                        Button {
                            var edited = lines
                            edited[index] = (checked ? "- [ ] " : "- [x] ") + line.dropFirst(6)
                            change(edited.joined(separator: "\n"))
                        } label: {
                            Label(String(line.dropFirst(6)), systemImage: checked ? "checkmark.square" : "square")
                                .strikethrough(checked)
                        }.buttonStyle(.plain)
                    } else {
                        Text(AttributedString(BoardRenderer.noteText(line, scale: 1, darkInk: false)))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
}

private struct BoardPinnedNote: View {
    let store: BoardStore
    let boardID: UUID
    let itemID: UUID
    @State private var editing = false
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        if let item = store.document(boardID)?.items.first(where: { $0.id == itemID }) {
            VStack(alignment: .leading) {
                if editing {
                    TextEditor(text: Binding(get: { store.document(boardID)?.items.first(where: { $0.id == itemID })?.text ?? "" },
                        set: { store.updateText($0, boardID: boardID, itemID: itemID) }))
                } else {
                    BoardMarkdownContent(text: item.text) { store.updateText($0, boardID: boardID, itemID: itemID) }
                }
                Button(editing ? "完成" : "编辑") { editing.toggle() }.disabled(item.locked)
            }.padding(10)
                .background(Color(nsColor: item.color == .clear ? .windowBackgroundColor : item.color.paper))
                .environment(\.colorScheme, item.color == .clear ? colorScheme : .light)
        } else {
            Text("便签已删除").foregroundStyle(.secondary).padding()
        }
    }
}

