import SwiftUI

struct SnippetLibraryView: View {
    @Bindable var model: ClipboardPanelModel
    @State private var pendingDelete: SavedSnippet?

    var body: some View {
        Group {
            if model.snippetMatches.isEmpty {
                VStack(spacing: 12) {
                    Text(L10n.shared.string(model.searchText.isEmpty ? "尚无常用短语" : "没有匹配结果"))
                        .foregroundStyle(.secondary)
                    if model.searchText.isEmpty {
                        Button("新建短语") { model.snippetDraft = SavedSnippet(name: "", group: "", text: "") }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selectedID) {
                    ForEach(model.snippetMatches) { snippet in
                        HStack(spacing: 10) {
                            Button { model.copySnippet(snippet) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(snippet.name).font(.system(size: 13, weight: .medium))
                                        if !snippet.group.isEmpty {
                                            Text(snippet.group).font(.system(size: 11)).foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(snippet.text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Menu {
                                Button("编辑") { model.snippetDraft = snippet }
                                Button("删除", role: .destructive) { pendingDelete = snippet }
                            } label: { Image(systemName: "ellipsis") }
                            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("短语操作")
                            if model.canDirectPaste {
                                Button { model.copySnippet(snippet, paste: true) } label: {
                                    Image(systemName: "arrow.down.to.line.compact")
                                }.buttonStyle(.borderless).help("粘贴回原应用")
                            }
                        }
                        .padding(.vertical, 5)
                        .accessibilityElement(children: .contain)
                        .tag(snippet.id)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .onKeyPress(.return) { model.copySelectedOrFirst(); return .handled }
            }
        }
        .confirmationDialog("删除这条常用短语？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("删除", role: .destructive) {
                guard let snippet = pendingDelete else { return }
                do { try model.snippets?.delete(snippet.id) }
                catch { model.errorMessage = error.localizedDescription }
                pendingDelete = nil
            }
        }
    }
}

struct SnippetEditorView: View {
    @State var draft: SavedSnippet
    let onSave: (SavedSnippet) throws -> Void
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("常用短语").font(.headline)
            Form {
                TextField("名称", text: $draft.name)
                TextField("分组", text: $draft.group)
            }
            TextEditor(text: $draft.text)
                .font(.system(size: 13))
                .frame(height: 210)
                .border(.secondary.opacity(0.25))
                .accessibilityLabel("短语内容")
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do { try onSave(draft); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
