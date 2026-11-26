import AppKit
import SwiftUI

@MainActor
final class BoardWindowController: NSObject, NSWindowDelegate {
    let store = BoardStore()
    private lazy var session = BoardSession(store: store)
    private var window: NSWindow?
    private var notes: [UUID: NSPanel] = [:]

    func present(boardID: UUID? = nil, itemID: UUID? = nil) {
        if let boardID { session.switchBoard(boardID) }
        if let itemID { session.focus(itemID) }
        if window == nil {
            let value = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 720),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
            value.minSize = CGSize(width: 660, height: 420)
            value.isReleasedWhenClosed = false
            value.title = ""
            value.titleVisibility = .hidden
            value.titlebarAppearsTransparent = true
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
        store.stop()
        window?.close()
        for panel in notes.values { panel.close() }
        notes.removeAll()
        window = nil
    }

    func refreshLocalization() {
        for panel in notes.values { panel.title = L10n.shared.string("便签") }
    }
    func windowWillClose(_ notification: Notification) { store.flush() }
}

struct BoardWorkspace: View {
    @Bindable var session: BoardSession
    let float: () -> Void
    @State private var query = ""
    @State private var name = ""
    @State private var naming = false
    @State private var creating = false
    @State private var confirmsDelete = false
    @State private var shortcutsShown = false

    private var board: BoardDocument { session.board }
    private var matches: [BoardItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? [] : board.items.filter { $0.searchableText.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack(alignment: .bottom) {
                BoardCanvasRepresentable(session: session, board: board, selection: session.selection, tool: session.tool)
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
                if !query.isEmpty {
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
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(12)
                }
                toolbar.padding(.bottom, 14)
            }
        }
        .frame(minWidth: 660, minHeight: 420)
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: Binding(get: { session.editingID != nil }, set: { if !$0 { session.editingID = nil } })) {
            if let id = session.editingID, let item = board.items.first(where: { $0.id == id }) {
                BoardNoteEditor(text: item.text) { text in
                    session.store.updateText(text, boardID: board.id, itemID: id)
                    session.editingID = nil
                } cancel: { session.editingID = nil }
                .id(id)
            }
        }
        .alert(creating ? "新建画布" : "重命名画布", isPresented: $naming) {
            TextField("名称", text: $name)
            Button("取消", role: .cancel) {}
            Button("确定") {
                let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return }
                if creating { session.selection = []; session.store.create(title) }
                else { session.store.editBoard(board.id) { $0.title = title } }
            }
        }
        .confirmationDialog("删除当前画布？", isPresented: $confirmsDelete) {
            Button("删除", role: .destructive) { session.selection = []; session.store.delete(board.id) }
        }
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

    private var header: some View {
        ZStack {
            HStack {
                Spacer()
                Button(action: float) { Image(systemName: session.floating ? "pin.fill" : "pin") }.help("置顶画布")
                Button { session.export() } label: { Image(systemName: "square.and.arrow.up") }.help("导出 PNG")
                Button { shortcutsShown.toggle() } label: { Image(systemName: "keyboard") }.help("画布快捷键")
                    .popover(isPresented: $shortcutsShown) { shortcutHelp }
            }.buttonStyle(.borderless).padding(.horizontal, 14)
            Menu {
                ForEach(session.store.library.boards) { document in
                    Button {
                        session.switchBoard(document.id); query = ""
                    } label: {
                        if document.id == board.id { Label(document.title, systemImage: "checkmark") }
                        else { Text(document.title) }
                    }
                }
                Divider()
                Button("新建画布") { creating = true; name = ""; naming = true }
                Button("重命名") { creating = false; name = board.title; naming = true }
                Button("设为默认画布") { session.store.makeDefault(board.id) }
                    .disabled(session.store.library.defaultID == board.id)
                Button("删除画布", role: .destructive) { confirmsDelete = true }
                    .disabled(session.store.library.boards.count <= 1)
            } label: {
                Text(board.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            }.menuStyle(.borderlessButton).frame(maxWidth: 200)
        }.frame(height: 42)
        .overlay(alignment: .leading) {
            TextField("搜索当前画布", text: $query).textFieldStyle(.roundedBorder).frame(width: 145).padding(.leading, 84)
        }
    }

    private var toolbar: some View {
        VStack(spacing: 6) {
            if session.tool.isShape {
                HStack(spacing: 5) {
                    ForEach(BoardTool.shapes) { shape in
                        Button { session.tool = shape } label: {
                            Image(systemName: shape.symbol).frame(width: 30, height: 27)
                                .background(session.tool == shape ? Color.accentColor.opacity(0.17) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain).help(shape.title)
                    }
                }.padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                    .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.12)) }
            }
            HStack(spacing: 5) {
            ForEach(BoardTool.allCases.filter { !$0.isShape }) { tool in
                Button {
                    session.tool = tool
                } label: {
                    Image(systemName: tool.symbol)
                        .frame(width: 23, height: 25)
                        .background(session.tool == tool ? Color.accentColor.opacity(0.17) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain).help(tool.title)
            }
            Button { session.tool = session.lastShape } label: {
                Image(systemName: session.lastShape.symbol).frame(width: 23, height: 25)
                    .background(session.tool.isShape ? Color.accentColor.opacity(0.17) : .clear, in: RoundedRectangle(cornerRadius: 5))
            }.buttonStyle(.plain).help("图形")
            Divider().frame(height: 22)
            Menu {
                ForEach(BoardColor.allCases) { color in
                    Button { session.color = color; session.mutateSelected { if $0.kind != .note { $0.color = color } } } label: {
                        Label(color.title, systemImage: session.color == color ? "checkmark.circle.fill" : "circle.fill")
                    }
                }
                Button("细") { session.strokeWidth = 2 }
                Button("中") { session.strokeWidth = 4 }
                Button("粗") { session.strokeWidth = 8 }
            } label: { Circle().fill(Color(nsColor: session.color.paper == .clear ? .labelColor : session.color.ink)).frame(width: 16, height: 16) }
            .menuStyle(.borderlessButton).fixedSize()
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
                Toggle("自动吸附", isOn: $session.snap)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            Divider().frame(height: 22)
            Button { session.store.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(session.store.undoStack.isEmpty).help("撤销")
            Button { session.store.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(session.store.redoStack.isEmpty).help("重做")
            Button { session.zoom(0.8) } label: { Image(systemName: "minus") }
            Button { session.resetZoom() } label: { Text("\(Int(board.viewport.zoom * 100))%").monospacedDigit().font(.caption) }
                .help("100% 并居中")
            Button { session.zoom(1.25) } label: { Image(systemName: "plus") }
            Button { session.fit() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("适应全部")
        }
        .buttonStyle(.borderless)
        .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)) }
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        }
    }

    private var shortcutHelp: some View {
        let rows = [("␣ + 拖动", "平移"), ("⌘ + 滚动 / 捏合", "缩放"), ("⌘0", "100% 并居中"), ("⌘⇧0", "适应全部"), ("⌘+ / ⌘−", "缩放"), ("⇧ + 点击", "多选"), ("⌘A", "全选"), ("⌘C / ⌘V", "复制 / 粘贴"), ("⌘Z / ⌘⇧Z", "撤销 / 重做"), ("⌘G / ⌘⇧G", "编组 / 取消编组"), ("← ↑ ↓ → / ⇧", "移动 / 加速移动"), ("⌥ + 拖动", "临时关闭吸附"), ("⌫ / ⌦", "删除"), ("⎋", "取消选择"), ("双击", "新建 / 编辑便签或预览图片")]
        return VStack(alignment: .leading, spacing: 8) {
            Text("画布快捷键").font(.headline)
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: 18) {
                    Text(L10n.shared.string(rows[index].1)).font(.callout)
                    Spacer()
                    Text(L10n.shared.string(rows[index].0)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }.padding(16).frame(width: 360)
    }
}

private struct BoardNoteEditor: View {
    @State var text: String
    let save: (String) -> Void
    let cancel: () -> Void
    @State private var preview = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("编辑便签").font(.headline)
                Spacer()
                Toggle("预览", isOn: $preview).toggleStyle(.switch).controlSize(.small)
            }
            if preview {
                BoardMarkdownContent(text: text) { text = $0 }
            } else {
                TextEditor(text: $text).font(.system(size: 15)).focused($focused)
            }
            HStack {
                Text("Markdown · - [ ] Todo").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button("完成") { save(text) }.keyboardShortcut(.defaultAction)
            }
        }.padding(16).frame(width: 460, height: 340).onAppear { focused = true }
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

