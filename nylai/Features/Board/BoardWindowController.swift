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
    func windowDidResignKey(_ notification: Notification) { session.finishEditing(); session.showsToolShortcuts = false }
}

struct BoardWorkspace: View {
    @Bindable var session: BoardSession
    let float: () -> Void
    @State private var query = ""
    @State private var helpShown = false
    @State private var helpPinned = false
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                VStack(alignment: .trailing, spacing: 8) {
                    topActions
                    if searching && !query.isEmpty { searchResults }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 12)
                .padding(.trailing, 14)
                toolbar.padding(.horizontal, 6).padding(.bottom, 14)
            }
        }
        .frame(minWidth: 660, minHeight: 420)
        .onChange(of: board.id) { _, _ in
            query = ""
            searching = false
            searchFocused = false
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

    private func toolButton(_ tool: BoardTool, group: Bool = false) -> some View {
        Button { session.chooseTool(tool) } label: {
            Image(systemName: tool.symbol)
                .modifier(BoardToolbarTarget(selected: group ? session.tool.isShape : session.tool == tool))
                .overlay(alignment: .topTrailing) {
                    if session.showsToolShortcuts {
                        Text(tool.shortcut).font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .padding(2).background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 3))
                            .offset(x: 5, y: -7)
                    }
                }
        }.buttonStyle(.plain).help(tool.title + " · " + tool.shortcut)
    }

    private func toolbarButton(
        _ symbol: String, help: LocalizedStringKey, width: CGFloat = 30,
        selected: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol).modifier(BoardToolbarTarget(width: width, selected: selected))
        }
        .help(help)
    }

    private var toolbarSeparator: some View {
        Divider().frame(height: 18).padding(.horizontal, 3)
    }

    private func closeSearch() {
        searching = false
        searchFocused = false
        query = ""
        session.focusCanvas?()
    }

    private var searchControl: some View {
        HStack(spacing: 0) {
            toolbarButton("magnifyingglass", help: "搜索当前画布", selected: searching) {
                if searching { closeSearch() }
                else {
                    session.finishEditing()
                    searching = true
                }
            }
            BoardSearchFieldReveal(progress: searching ? 1 : 0) {
                TextField("搜索", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                    .padding(.horizontal, 6)
                    .opacity(searching ? 1 : 0)
                    .onSubmit { if let item = matches.first { session.focus(item.id); session.focusCanvas?() } }
                    .onExitCommand(perform: closeSearch)
            }
            .clipped()
            .allowsHitTesting(searching)
            .accessibilityHidden(!searching)
        }
        .background(Color.primary.opacity(searching ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 9))
        .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: searching)
        .onChange(of: searching) { _, active in
            if active { searchFocused = true }
        }
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("搜索结果").font(.caption).foregroundStyle(.secondary)
            if matches.isEmpty { Text("没有匹配内容").foregroundStyle(.secondary) }
            ForEach(matches.prefix(15)) { item in
                Button { session.focus(item.id) } label: {
                    Text(item.searchableText.isEmpty ? L10n.shared.string("图片") : item.searchableText)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.14), radius: 7, y: 3)
    }

    private var topActions: some View {
        HStack(spacing: 0) {
            searchControl
            toolbarSeparator
            toolbarButton("questionmark.circle", help: "画布帮助", selected: helpShown) {
                session.finishEditing()
                if !helpShown { searchFocused = false }
                helpShown.toggle()
            }
            .popover(isPresented: $helpShown, arrowEdge: .top) {
                boardHelp
                    .interactiveDismissDisabled(helpPinned)
            }
        }
        .buttonStyle(.plain)
        .background { toolbarBackground }
    }

    private var toolbar: some View {
        VStack(spacing: 6) {
            if !session.toolbarCollapsed {
                if session.tool.showsDrawingStyle || session.showsToolShortcuts || canFillSelectedShapes { drawingStyleBar }
                HStack(spacing: 0) {
                    ForEach(BoardTool.allCases.filter { !$0.isShape }) { tool in
                        toolButton(tool)
                    }
                    toolButton(session.lastShape, group: true)
                    toolbarSeparator
                    toolbarButton("arrow.uturn.backward", help: "撤销") { session.undo(); session.focusCanvas?() }
                        .disabled(session.store.undoStack.isEmpty)
                    toolbarButton("arrow.uturn.forward", help: "重做") { session.redo(); session.focusCanvas?() }
                        .disabled(session.store.redoStack.isEmpty)
                    toolbarButton("trash", help: "清空画布") { session.confirmClear(); session.focusCanvas?() }
                        .disabled(board.items.isEmpty)
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
                    } label: {
                        Image(systemName: "ellipsis.circle").modifier(BoardToolbarTarget())
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    toolbarSeparator
                    toolbarButton("minus", help: "缩小") { session.zoom(0.8); session.focusCanvas?() }
                    Button { session.resetZoom(); session.focusCanvas?() } label: {
                        Text("\(Int(board.viewport.zoom * 100))%").monospacedDigit().font(.caption)
                            .modifier(BoardToolbarTarget(width: 40))
                    }
                        .help("100% 并居中")
                    toolbarButton("plus", help: "放大") { session.zoom(1.25); session.focusCanvas?() }
                    toolbarButton("arrow.up.left.and.arrow.down.right", help: "适应全部") { session.fit(); session.focusCanvas?() }
                    toolbarSeparator
                    toolbarButton("chevron.down", help: "收起工具栏") {
                        closeSearch()
                        session.toolbarCollapsed = true
                    }
                }
                .background { toolbarBackground }
                .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: searching)
            } else {
                toolbarButton("chevron.up", help: "展开工具栏", width: 40) {
                    session.toolbarCollapsed = false
                    session.focusCanvas?()
                }
                .background { toolbarBackground }
            }
        }
        .buttonStyle(.plain)
    }

    private var toolbarBackground: some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(.regularMaterial)
            .shadow(color: .black.opacity(0.16), radius: 7, y: 3)
    }

    private var canFillSelectedShapes: Bool {
        session.tool == .select && !session.editableSelectedShapes.isEmpty
    }

    private var drawingStyleBar: some View {
        HStack(spacing: 0) {
            if session.tool.isShape || session.showsToolShortcuts {
                ForEach(BoardTool.shapes) { shape in toolButton(shape) }
                if session.tool.showsDrawingStyle || canFillSelectedShapes { toolbarSeparator }
            }
            if session.tool.showsDrawingStyle {
                ForEach(BoardColor.drawingColors) { color in
                    Button { session.color = color; session.focusCanvas?() } label: {
                        Circle().fill(Color(nsColor: color.ink)).frame(width: 14, height: 14)
                            .overlay { Circle().strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.75) }
                            .padding(3)
                            .overlay { Circle().strokeBorder(session.color == color ? Color.accentColor : .clear, lineWidth: 1.5) }
                            .modifier(BoardToolbarTarget())
                    }.buttonStyle(.plain).help(color.title)
                }
                toolbarButton("circle.lefthalf.filled", help: session.translucent ? "关闭半透明" : "开启半透明",
                              selected: session.translucent) { session.translucent.toggle(); session.focusCanvas?() }
                toolbarSeparator
                ForEach([CGFloat(2), 4, 6, 10], id: \.self) { width in
                    Button { session.strokeWidth = width; session.focusCanvas?() } label: {
                        Circle().fill(Color.primary).frame(width: width + 2, height: width + 2)
                            .modifier(BoardToolbarTarget(selected: session.strokeWidth == width))
                    }.buttonStyle(.plain).help("\(Int(width)) pt")
                }
                toolbarSeparator
                Button { session.dashed.toggle(); session.focusCanvas?() } label: {
                    HStack(spacing: 2) {
                        ForEach(0..<3) { _ in Capsule().fill(Color.primary).frame(width: 5, height: 2) }
                    }.modifier(BoardToolbarTarget(selected: session.dashed))
                }.buttonStyle(.plain).help("虚线")
            }
            if session.tool.isShape || canFillSelectedShapes {
                let filled = session.tool.isShape ? session.filled : session.selectedShapesAreFilled
                toolbarButton("square.inset.filled", help: filled ? "取消图形填充" : "填充图形", selected: filled) {
                    if session.tool.isShape { session.filled.toggle() }
                    else { session.toggleSelectedShapeFill() }
                    session.focusCanvas?()
                }
            }
        }.background { toolbarBackground }
    }

    private var boardHelp: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("画布帮助").font(.title3.weight(.semibold))
                    Text("功能与对应的鼠标或键盘操作。固定后可继续在画布上操作。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    helpPinned.toggle()
                } label: {
                    Image(systemName: helpPinned ? "pin.fill" : "pin")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .background(helpPinned ? Color.accentColor.opacity(0.16) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help(helpPinned ? "取消固定帮助" : "固定帮助")
                .accessibilityLabel(helpPinned ? "取消固定帮助" : "固定帮助")
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    helpSection("便签", rows: [
                        ("新建便签", "双击画布空白处"),
                        ("编辑便签", "双击便签"),
                        ("选择便签文字", "在便签正文拖动"),
                        ("移动便签", "拖动便签顶部栏"),
                        ("折叠或展开", "点击便签右上角箭头"),
                        ("勾选待办", "点击待办项前的方框")
                    ])
                    helpSection("标注与图形", rows: [
                        ("回到选取模式", "绘制完成后按 Esc"),
                        ("绘制正方形或正圆", "按住 Control 拖动"),
                        ("约束线条方向", "按住 Shift 拖动"),
                        ("切换半透明", "点击半透明按钮"),
                        ("填充图形", "绘制前或选中图形后点击填充"),
                        ("删除对象", "选中后按 Delete")
                    ])
                    helpSection("画布操作", rows: [
                        ("平移", "按住空格并拖动"),
                        ("缩放", "⌘ + 滚动或捏合"),
                        ("100% 并居中", "⌘0"),
                        ("适应全部", "⌘⇧0"),
                        ("多选", "⇧ + 点击"),
                        ("全选文字或对象", "⌘A"),
                        ("复制或粘贴", "⌘C / ⌘V"),
                        ("撤销或重做", "⌘Z / ⌘⇧Z"),
                        ("编组或取消编组", "⌘G / ⌘⇧G"),
                        ("移动对象", "方向键，按住 ⇧ 加速"),
                        ("临时关闭吸附", "⌥ + 拖动")
                    ])
                    helpSection("工具快捷键", rows: BoardTool.allCases.map { ($0.title, $0.shortcut) })
                }
                .padding(16)
            }
        }
        .frame(width: 430, height: 520)
    }

    private func helpSection(_ title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.shared.string(title)).font(.headline)
            helpRow("功能项", "操作方法", header: true)
            ForEach(rows.indices, id: \.self) { index in
                helpRow(rows[index].0, rows[index].1)
            }
        }
    }

    private func helpRow(_ title: String, _ action: String, header: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(L10n.shared.string(title))
                .font(header ? .caption.weight(.semibold) : .callout)
                .foregroundStyle(header ? .secondary : .primary)
                .frame(width: 130, alignment: .leading)
            Spacer()
            Text(L10n.shared.string(action))
                .font(header ? .caption.weight(.semibold) : .callout)
                .foregroundStyle(header ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct BoardSearchFieldReveal: Layout {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(108, proposal.width ?? 108) * progress
        let height = subviews[0].sizeThatFits(.unspecified).height
        return CGSize(width: max(0, width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: max(44, bounds.width), height: bounds.height))
    }
}

private struct BoardToolbarTarget: ViewModifier {
    var width: CGFloat = 30
    var selected = false
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content
            .frame(width: width, height: 32)
            .background {
                RoundedRectangle(cornerRadius: 9)
                    .fill(selected ? Color.accentColor.opacity(0.17) : .clear)
            }
            .background {
                RoundedRectangle(cornerRadius: 9)
                    .fill(hovering && enabled ? Color.primary.opacity(0.08) : .clear)
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
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

