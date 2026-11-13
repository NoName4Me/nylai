import AppKit
import SwiftUI

extension ClipboardGroupColor {
    var tint: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .gray: .gray
        }
    }
    var title: String {
        let key = switch self {
        case .red: "红色"
        case .orange: "橙色"
        case .yellow: "黄色"
        case .green: "绿色"
        case .blue: "蓝色"
        case .purple: "紫色"
        case .gray: "灰色"
        }
        return L10n.shared.string(key)
    }
}

struct ClipboardPanelView: View {
    @Bindable var model: ClipboardPanelModel
    var panelHeight: CGFloat = 620
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredID: UUID?
    @State private var deletingGroup: ClipboardGroup?
    @Namespace private var groupSelection
    private var theme: SettingsTheme { SettingsTheme(colorScheme: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            header
            groupTabs
            search
            Divider()
            records
            if model.isSelecting { selectionActions }
            else { clearActions }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11.5)).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        }
        .frame(width: 540, height: panelHeight)
        .coordinateSpace(name: "clipboard.history")
        .background(theme.page)
        .tint(NylaiPalette.accent)
        .mask { Rectangle().scaleEffect(x: max(0.002, model.reveal), y: 1) }
        .onAppear { searchFocused = true }
        .onKeyPress(.escape) {
            if !model.isPinned { model.onClose() }
            return .handled
        }
        .onChange(of: model.searchText) { resetSelection() }
        .onChange(of: model.selectedGroupID) { resetSelection() }
        .sheet(item: $model.groupDraft) { group in
            ClipboardGroupEditor(draft: group) { draft in
                guard let store = model.groups else { throw ClipboardGroupError.unsupportedVersion }
                try store.save(draft)
            }
            .nylaiLocalized()
        }
        .confirmationDialog(model.clearConfirmationTitle, isPresented: $model.confirmsClearHistory) {
            Button(model.clearConfirmationActionTitle, role: .destructive) { model.clearCurrentScope() }
        } message: {
            Text(model.clearConfirmationMessage)
        }
        .confirmationDialog("删除分组？", isPresented: Binding(get: { deletingGroup != nil }, set: { if !$0 { deletingGroup = nil } })) {
            Button("删除分组", role: .destructive) {
                guard let group = deletingGroup else { return }
                do {
                    try model.groups?.delete(group.id, history: model.store)
                    if model.selectedGroupID == group.id { model.selectedGroupID = nil }
                } catch { model.errorMessage = error.localizedDescription }
                deletingGroup = nil
            }
        } message: { Text("内容会保留在“全部”中。") }
    }

    private func resetSelection() {
        model.checkedIDs = []
        model.selectedID = nil
        model.onPreview(nil)
        hoveredID = nil
    }

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "doc.on.clipboard").foregroundStyle(NylaiPalette.accent)
                Text("剪贴板").font(.system(size: 15, weight: .semibold))
                Spacer()
            }.overlay { ClipboardPanelDragArea() }
            Button(model.isSelecting ? L10n.shared.string("完成") : L10n.shared.string("多选")) {
                model.isSelecting.toggle()
                model.checkedIDs = []
                model.onPreview(nil)
            }.buttonStyle(.borderless)
            Button { model.isPinned.toggle() } label: {
                Image(systemName: model.isPinned ? "pin.fill" : "pin")
                    .foregroundStyle(model.isPinned ? NylaiPalette.accent : .primary)
            }
            .buttonStyle(.borderless)
            .help(model.isPinned ? L10n.shared.string("取消钉住") : L10n.shared.string("钉住面板"))
            .accessibilityLabel(model.isPinned ? L10n.shared.string("取消钉住") : L10n.shared.string("钉住面板"))
            Button { model.onClose() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).accessibilityLabel("关闭剪贴板历史")
        }.padding(.horizontal, 15).padding(.top, 14).padding(.bottom, 12)
    }

    private var groupTabs: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 32, height: 26)
            Spacer(minLength: 0)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    tab(name: L10n.shared.string("全部"), color: nil, selected: model.selectedGroupID == nil) { model.selectedGroupID = nil }
                    ForEach(model.groups?.groups ?? []) { group in
                        tab(name: group.name, color: group.color.tint, selected: model.selectedGroupID == group.id) { model.selectedGroupID = group.id }
                            .contextMenu {
                                Button {
                                    model.groupDraft = group
                                } label: {
                                    Label {
                                        Text("编辑分组")
                                    } icon: {
                                        Image(nsImage: NylaiIcon.edit.image(pointSize: 13))
                                    }
                                }
                                Button(role: .destructive) {
                                    deletingGroup = group
                                } label: {
                                    Label {
                                        Text("删除分组")
                                    } icon: {
                                        Image(nsImage: NylaiIcon.trash.image(pointSize: 13))
                                    }
                                }
                            }
                    }
                }
                .padding(3)
                .background(
                    Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.06),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.055), lineWidth: 0.5)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            Button { model.groupDraft = ClipboardGroup(name: "") } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(model.groups == nil)
            .help("添加分组")
            .accessibilityLabel("添加分组")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private func tab(name: String, color: Color?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let color { Circle().fill(color).frame(width: 7, height: 7) }
                Text(name).font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
            }
            .padding(.horizontal, 10).frame(height: 28)
            .contentShape(Rectangle())
            .foregroundStyle(selected ? .primary : .secondary)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.16) : .white)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(
                                    colorScheme == .dark
                                        ? Color.white.opacity(0.20)
                                        : Color.black.opacity(0.08),
                                    lineWidth: 0.75
                                )
                        }
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.16 : 0.10), radius: 2, y: 1)
                        .matchedGeometryEffect(id: "clipboard.group.selection", in: groupSelection)
                }
            }
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.20, extraBounce: 0.04), value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索当前分组", text: $model.searchText)
                .textFieldStyle(.plain).focused($searchFocused)
                .onKeyPress(.downArrow) { model.selectNext(1); return .handled }
                .onKeyPress(.upArrow) { model.selectNext(-1); return .handled }
                .onKeyPress(.return) { model.copySelectedOrFirst(); return .handled }
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).frame(height: 32)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var records: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.visibleRecords.isEmpty {
                        Text(model.searchText.isEmpty ? L10n.shared.string("暂无内容") : L10n.shared.string("没有匹配结果"))
                            .foregroundStyle(.secondary).padding(.top, 100)
                    }
                    ForEach(model.visibleRecords) { record in
                        row(record).id(record.id)
                    }
                }
            }
            .onChange(of: model.selectedID) {
                if let id = model.selectedID { reader.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func row(_ record: ClipboardRecord) -> some View {
        HStack(alignment: .center, spacing: 10) {
            if model.isSelecting {
                Button { model.choose(record) } label: {
                    Image(systemName: model.checkedIDs.contains(record.id) ? "checkmark.square.fill" : "square")
                        .font(.system(size: 17)).foregroundStyle(record.kind == .text ? NylaiPalette.accent : .secondary)
                }.buttonStyle(.plain).disabled(record.kind != .text).accessibilityLabel("选择记录")
            }
            Button { model.choose(record, modifiers: NSApp.currentEvent?.modifierFlags ?? []) } label: {
                HStack(spacing: 10) {
                    if record.kind == .image, let thumbnail = model.store.thumbnail(for: record) {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    } else {
                        Image(systemName: "text.alignleft")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(NylaiPalette.accent.opacity(0.75))
                            .frame(width: 40, height: 40)
                            .background(
                                NylaiPalette.accent.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 5)
                            )
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        if let name = model.groups?.name(for: record.id), !model.preview(for: record).hasPrefix(name) {
                            Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        }
                        Text(model.preview(for: record)).font(.system(size: 12.5)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 5) {
                            Text(record.sourceName ?? record.sourceBundleIdentifier ?? L10n.shared.string("来源未知")).lineLimit(1)
                            Text("·")
                            Text(model.relativeTime(for: record.copiedAt))
                            ForEach((model.groups?.groups ?? []).filter { $0.recordIDs.contains(record.id) }) { group in
                                Circle().fill(group.color.tint).frame(width: 6, height: 6).help(group.name)
                            }
                        }.font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button("粘贴") { model.directPaste(record) }.buttonStyle(.borderless)
                .disabled(!model.canDirectPaste)
                .help(model.canDirectPaste ? L10n.shared.string("粘贴到 %@", model.targetApplication?.localizedName ?? "") : L10n.shared.string("先切换到目标应用，再打开剪贴板。"))
            Menu { recordActions(record) } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("记录操作")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background((hoveredID == record.id || model.selectedID == record.id) ? NylaiPalette.accent.opacity(0.10) : .clear)
        .contextMenu { recordActions(record) }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("clipboard.history")) } action: { model.rowFrames[record.id] = $0 }
        .onHover { hovering in
            hoveredID = hovering ? record.id : nil
            if !model.isSelecting { model.onPreview(hovering ? record : nil) }
        }
    }

    @ViewBuilder private func recordActions(_ record: ClipboardRecord) -> some View {
        Button("复制") { model.copy(record) }
        Menu("分组") {
            ForEach(model.groups?.groups ?? []) { group in
                Button {
                    model.assign([record.id], to: group, included: !group.recordIDs.contains(record.id))
                } label: {
                    Label {
                        Text(group.name)
                    } icon: {
                        GroupAssignmentCircle(
                            assigned: group.recordIDs.contains(record.id),
                            color: group.color.tint
                        )
                    }
                }
            }
            Button("添加分组") { model.groupDraft = ClipboardGroup(name: "") }
        }
        Button("删除", role: .destructive) { model.delete(record) }
    }

    private var selectionActions: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(spacing: 9) {
                Text(L10n.shared.string("已选 %@ 条", String(model.checkedRecords.count))).font(.system(size: 11.5))
                Picker("分隔", selection: $model.joinWithSpace) {
                    Text("换行").tag(false)
                    Text("空格").tag(true)
                }.labelsHidden().frame(width: 75)
                Menu("分组") {
                    ForEach(model.groups?.groups ?? []) { group in
                        let ids = Set(model.checkedRecords.map(\.id))
                        let included = !ids.isEmpty && ids.isSubset(of: group.recordIDs)
                        Button {
                            model.assign(ids, to: group, included: !included)
                        } label: {
                            Label {
                                Text(group.name)
                            } icon: {
                                GroupAssignmentCircle(
                                    assigned: included,
                                    color: group.color.tint
                                )
                            }
                        }
                    }
                }.fixedSize().disabled(model.checkedRecords.isEmpty)
                Spacer(minLength: 0)
                Button("复制合并") { model.copyChecked() }.disabled(model.checkedRecords.isEmpty)
                Button("粘贴合并") { model.copyChecked(paste: true) }.disabled(model.checkedRecords.isEmpty || !model.canDirectPaste)
            }.padding(.horizontal, 12).padding(.bottom, 10)
        }
    }

    private var clearActions: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button {
                    model.confirmsClearHistory = true
                } label: {
                    Text("清空")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(model.clearActionHelp)
                .accessibilityIdentifier("clipboard.clear")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
    }
}

private struct GroupAssignmentCircle: View {
    let assigned: Bool
    let color: Color

    var body: some View {
        Image(nsImage: menuImage)
            .renderingMode(.original)
            .accessibilityHidden(true)
    }

    private var menuImage: NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14))
        image.lockFocus()
        NSColor(color).set()
        let circle = NSBezierPath(ovalIn: CGRect(x: 2, y: 2, width: 10, height: 10))
        circle.lineWidth = 1.5
        if assigned { circle.fill() } else { circle.stroke() }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

private struct ClipboardGroupEditor: View {
    @State var draft: ClipboardGroup
    let onSave: (ClipboardGroup) throws -> Void
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("分组").font(.headline)
            TextField("名称", text: $draft.name)
            HStack(spacing: 10) {
                ForEach(ClipboardGroupColor.allCases, id: \.self) { color in
                    Button {
                        draft.color = color
                    } label: {
                        Circle()
                            .fill(color.tint)
                            .frame(width: 20, height: 20)
                            .overlay {
                                Circle().strokeBorder(
                                    draft.color == color ? Color.primary.opacity(0.75) : .clear,
                                    lineWidth: 2
                                )
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(color.title)
                    .accessibilityLabel(color.title)
                    .accessibilityAddTraits(draft.color == color ? .isSelected : [])
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do { try onSave(draft); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 330)
    }
}
