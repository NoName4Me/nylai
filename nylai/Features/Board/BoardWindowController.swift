import AppKit
import SwiftUI

@MainActor
final class BoardWindowController: NSObject, NSWindowDelegate {
    let store = BoardStore()
    private lazy var session = BoardSession(store: store)
    private var window: NSWindow?
    private var captureWindow: NSPanel?
    private var notes: [UUID: NSPanel] = [:]

    func present(boardID: UUID? = nil, itemID: UUID? = nil) {
        if let boardID { session.switchBoard(boardID) }
        if let itemID { session.focus(itemID) }
        if window == nil {
            let value = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 720),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                 backing: .buffered, defer: false)
            value.minSize = CGSize(width: 560, height: 420)
            value.isReleasedWhenClosed = false
            value.title = L10n.shared.string("无限画布")
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

    func quickCapture() {
        if let captureWindow, captureWindow.isVisible { captureWindow.makeKeyAndOrderFront(nil); return }
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 420, height: 280),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = L10n.shared.string("快速记录")
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.center()
        panel.contentView = NSHostingView(rootView: BoardQuickCapture(store: store,
            save: { [weak self] text, id in if self?.add(.text(text), boardID: id) == true { self?.captureWindow?.orderOut(nil) } },
            paste: { [weak self] id in
                guard let self else { return }
                if let images = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage], !images.isEmpty {
                    for image in images { self.store.addImage(image, boardID: id, at: self.store.nextCapturePoint(in: id)) }
                    self.captureWindow?.orderOut(nil)
                } else if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
                    if self.add(.text(text), boardID: id) { self.captureWindow?.orderOut(nil) }
                }
            }).nylaiLocalized())
        captureWindow = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        store.flush()
        window?.close()
        captureWindow?.close()
        for panel in notes.values { panel.close() }
        notes.removeAll()
        window = nil; captureWindow = nil
    }

    func refreshLocalization() {
        window?.title = L10n.shared.string("无限画布")
        captureWindow?.title = L10n.shared.string("快速记录")
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
        .frame(minWidth: 560, minHeight: 420)
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
        HStack(spacing: 10) {
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
                Label(board.title, systemImage: "rectangle.on.rectangle")
                    .font(.system(size: 13, weight: .medium))
            }.fixedSize()
            Spacer(minLength: 6)
            TextField("搜索当前画布", text: $query)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
            Button(action: float) { Image(systemName: session.floating ? "pin.fill" : "pin") }
                .help("置顶画布")
            Button { session.export() } label: { Image(systemName: "square.and.arrow.up") }.help("导出 PNG")
        }.padding(12)
    }

    private var toolbar: some View {
        HStack(spacing: 5) {
            ForEach(BoardTool.allCases) { tool in
                Button {
                    session.tool = tool
                } label: {
                    Image(systemName: tool.symbol)
                        .frame(width: 23, height: 25)
                        .background(session.tool == tool ? Color.accentColor.opacity(0.17) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain).help(tool.title)
            }
            Divider().frame(height: 22)
            Menu {
                ForEach(BoardColor.allCases) { color in
                    Button { session.color = color; session.mutateSelected { $0.color = color } } label: {
                        Label(color.rawValue, systemImage: session.color == color ? "checkmark.circle.fill" : "circle.fill")
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
            Button { session.fit() } label: { Text("\(Int(board.viewport.zoom * 100))%").monospacedDigit().font(.caption) }
                .help("适应全部")
            Button { session.zoom(1.25) } label: { Image(systemName: "plus") }
        }
        .buttonStyle(.borderless)
        .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)) }
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
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
                .environment(\.colorScheme, item.color == .clear ? .light : .light)
        } else {
            Text("便签已删除").foregroundStyle(.secondary).padding()
        }
    }
}

private struct BoardQuickCapture: View {
    let store: BoardStore
    let save: (String, UUID) -> Void
    let paste: (UUID) -> Void
    @State private var text = ""
    @State private var boardID: UUID?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $text).focused($focused)
                .font(.system(size: 14)).border(Color.secondary.opacity(0.18))
            HStack {
                Picker("画布", selection: $boardID) {
                    ForEach(store.library.boards) { board in Text(board.title).tag(Optional(board.id)) }
                }
                Button("粘贴图文") { paste(boardID ?? store.library.defaultID) }
                Button("保存") { save(text, boardID ?? store.library.defaultID) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(12).onAppear { boardID = store.library.defaultID; focused = true }
    }
}
