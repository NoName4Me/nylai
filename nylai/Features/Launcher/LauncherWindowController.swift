import AppKit
import SwiftUI

@MainActor
private final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class LauncherWindowController: NSObject, NSWindowDelegate {
    let preferences: LauncherPreferences
    let model: LauncherModel
    private var panel: LauncherPanel?
    private var localMonitor: Any?
    private var previousApplication: NSRunningApplication?
    private var running: Task<Void, Never>?
    private var isClosing = false

    init(preferences: LauncherPreferences, sources: LauncherSources) {
        self.preferences = preferences
        model = LauncherModel(preferences: preferences, sources: sources)
        super.init()
        model.onDismiss = { [weak self] in self?.dismiss() }
        model.onRun = { [weak self] result, action in self?.execute(result, action: action) }
    }

    func toggle() {
        if panel?.isVisible == true { dismiss() }
        else { present() }
    }

    func present() {
        guard running == nil else { return }
        if panel?.isVisible == true { panel?.makeKeyAndOrderFront(nil); return }
        let front = NSWorkspace.shared.frontmostApplication
        previousApplication = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front
        model.begin(target: previousApplication)
        let visible = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let width = min(720, max(350, visible.width - 32))
        let height = min(530, max(280, visible.height - 50))
        let value = LauncherPanel(contentRect: CGRect(x: visible.midX - width / 2, y: visible.maxY - height - 86,
                                                      width: width, height: height),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        value.isReleasedWhenClosed = false
        value.isOpaque = false
        value.backgroundColor = .clear
        value.hasShadow = true
        value.level = .floating
        value.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        value.hidesOnDeactivate = false
        value.delegate = self
        value.title = L10n.shared.string("Launcher")
        let hosting = NSHostingView(rootView: LauncherPanelView(model: model).nylaiLocalized())
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 14
        hosting.layer?.masksToBounds = true
        value.contentView = hosting
        panel = value
        installMonitor()
        NSApp.activate(ignoringOtherApps: true)
        value.makeKeyAndOrderFront(nil)
    }

    private func installMonitor() {
        removeMonitor()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, event.window === self.panel, self.panel?.isVisible == true,
                      !self.model.settingsPresented else { return false }
                if let editor = self.panel?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "k" {
                    self.model.toggleActions(); return true
                }
                switch event.keyCode {
                case 125: self.model.move(1)
                case 126: self.model.move(-1)
                case 48: self.model.cycleScope(reverse: flags.contains(.shift))
                case 36, 76: self.model.confirm()
                case 53: self.model.escape()
                default: return false
                }
                return true
            }
            return consumed ? nil : event
        }
    }

    private func removeMonitor() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        if !isClosing, !model.settingsPresented, panel?.isVisible == true {
            dismiss(restore: false)
        }
    }

    private func hidePanel() {
        isClosing = true
        removeMonitor()
        panel?.orderOut(nil)
        panel = nil
        isClosing = false
    }

    func dismiss(restore: Bool = true) {
        let target = previousApplication
        hidePanel()
        model.clear()
        previousApplication = nil
        if restore, let target, !target.isTerminated {
            try? ApplicationActivationService().bringToFront(ApplicationActivationTarget(target))
        }
    }

    func close() {
        running?.cancel()
        running = nil
        dismiss(restore: false)
    }

    private func execute(_ result: LauncherResult, action: LauncherAction) {
        guard running == nil else { return }
        let target = previousApplication
        model.stopSearch()
        hidePanel()
        running = Task { [weak self] in
            guard let self else { return }
            defer { model.clear(); previousApplication = nil; running = nil }
            do {
                if action.restoresPreviousApplication, let target, !target.isTerminated {
                    try? ApplicationActivationService().bringToFront(ApplicationActivationTarget(target))
                    try await Task.sleep(for: .milliseconds(120))
                }
                try Task.checkCancellation()
                try await action.run()
                preferences.record(result.id)
            } catch is CancellationError {
            } catch {
                let alert = NSAlert()
                alert.messageText = L10n.shared.string("操作失败")
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: L10n.shared.string("好"))
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }
}

private struct LauncherPanelView: View {
    @Bindable var model: LauncherModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 21)).foregroundStyle(.secondary)
                TextField("搜索应用、文件、内容或命令", text: $model.input)
                    .textFieldStyle(.plain).font(.system(size: 23)).focused($focused)
                if model.searching || model.indexing {
                    ProgressView().controlSize(.small).help("正在搜索")
                }
                Button { model.settingsPresented = true } label: {
                    Image(systemName: "gearshape").font(.system(size: 17))
                }.buttonStyle(.plain).help("Launcher 设置")
            }.padding(18)
            Divider()
            scopeBar
            Divider()
            HStack(spacing: 0) {
                resultList
                if model.showingActions, let selected = model.selected {
                    Divider()
                    actionsPane(selected).frame(width: 230)
                } else if let result = model.selected, let preview = result.preview {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Image(nsImage: preview).resizable().scaledToFit().frame(maxHeight: 180)
                        Text(result.title).font(.caption).lineLimit(7)
                        Text(result.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                        Spacer(minLength: 0)
                    }.padding(14).frame(width: 215)
                }
            }.frame(maxHeight: .infinity)
            Divider()
            HStack(spacing: 12) {
                Text(model.query.scope.title).font(.caption).foregroundStyle(.secondary)
                if let error = model.preferences.loadError { Text(error).font(.caption).foregroundStyle(.red).lineLimit(1) }
                Spacer()
                Text("↑ ↓").monospaced().font(.caption)
                Text("选择").font(.caption).foregroundStyle(.secondary)
                Button { model.confirm() } label: {
                    Label(model.showingActions ? L10n.shared.string("执行") : (model.selected?.actions.first?.title ?? L10n.shared.string("打开")), systemImage: "return")
                }.buttonStyle(.borderless).disabled(model.selected == nil)
                Button { model.toggleActions() } label: { Text("操作 ⌘K").font(.caption) }
                    .buttonStyle(.borderless).disabled(model.selected == nil)
                Button("Esc") { model.escape() }.buttonStyle(.borderless)
            }.padding(.horizontal, 14).padding(.vertical, 9)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.13)) }
        .onAppear { focused = true }
        .onChange(of: model.focusToken) { _, _ in focused = true }
        .sheet(isPresented: $model.settingsPresented, onDismiss: { model.restartIndex() }) {
            LauncherSettingsView(preferences: model.preferences)
        }
    }

    private var scopeBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(LauncherScope.allCases) { scope in
                    Button { model.selectScope(scope) } label: {
                        Text(scope.title).font(.system(size: 11, weight: model.query.scope == scope ? .medium : .regular))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(model.query.scope == scope ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).help(scope.alias + ":")
                }
            }.padding(.horizontal, 12).padding(.vertical, 7)
        }
    }

    private var resultList: some View {
        Group {
            if model.results.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").font(.system(size: 27)).foregroundStyle(.tertiary)
                    Text(model.searching || model.indexing ? "正在搜索…" : "没有匹配结果")
                        .foregroundStyle(.secondary)
                    if model.query.scope == .windows {
                        Text("窗口搜索需要辅助功能与屏幕录制权限。").font(.caption).foregroundStyle(.secondary)
                    }
                    if [.tabs, .bookmarks, .history].contains(model.query.scope) {
                        Text("在 Launcher 设置中启用对应浏览器数据。部分浏览器需要自动化或磁盘访问权限。")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 20)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(model.results) { result in
                                row(result)
                                    .id(result.id)
                            }
                        }.padding(7)
                    }
                    .onChange(of: model.selectedID) { _, id in
                        if let id { proxy.scrollTo(id, anchor: nil) }
                    }
                }
            }
        }
    }

    private func row(_ result: LauncherResult) -> some View {
        HStack(spacing: 11) {
            Group {
                if let icon = result.icon {
                    Image(nsImage: icon).resizable().scaledToFit()
                } else if let preview = result.preview {
                    Image(nsImage: preview).resizable().scaledToFit()
                } else {
                    Image(systemName: result.symbol ?? result.scope.symbol).font(.system(size: 18)).foregroundStyle(.secondary)
                }
            }.frame(width: 31, height: 31)
            VStack(alignment: .leading, spacing: 3) {
                Text(result.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if !result.subtitle.isEmpty {
                    Text(result.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 5)
            if model.preferences.configuration.favorites.contains(result.id) {
                Image(systemName: "star.fill").font(.caption2).foregroundStyle(.secondary)
            }
            Text(result.scope.title).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(model.selectedID == result.id ? Color.accentColor.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.select(result.id); model.confirm() }
        .onTapGesture { model.select(result.id) }
        .contextMenu {
            ForEach(result.actions) { action in
                Button(action.title) { model.onRun?(result, action) }
            }
        }
    }

    private func actionsPane(_ selected: LauncherResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(selected.title).font(.headline).lineLimit(2).padding(.bottom, 6)
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(Array(model.actions.enumerated()), id: \.offset) { index, action in
                        Button {
                            model.onRun?(selected, action)
                        } label: {
                            HStack {
                                Image(systemName: action.symbol).frame(width: 18)
                                Text(action.title).lineLimit(1)
                                Spacer()
                                if index == model.actionIndex { Image(systemName: "return").font(.caption2) }
                            }
                            .font(.system(size: 12)).padding(8)
                            .background(index == model.actionIndex ? Color.accentColor.opacity(0.18) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain)
                    }
                }
            }
            Spacer(minLength: 0)
        }.padding(10)
    }
}

private struct LauncherSettingsView: View {
    let preferences: LauncherPreferences
    @State private var draft: LauncherConfiguration
    @Environment(\.dismiss) private var dismiss

    init(preferences: LauncherPreferences) {
        self.preferences = preferences
        _draft = State(initialValue: preferences.configuration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Launcher 设置").font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    Text("快捷入口").font(.headline)
                    Text("支持网址、文件、目录和应用路径；在网址中使用 {query} 插入经过编码的查询参数。").font(.caption).foregroundStyle(.secondary)
                    ForEach($draft.links) { $link in
                        HStack {
                            TextField("名称", text: $link.title).frame(width: 115)
                            TextField("别名", text: $link.alias).frame(width: 80)
                            TextField("网址或路径", text: $link.target)
                            Button(role: .destructive) {
                                let id = link.id
                                draft.links.removeAll { $0.id == id }
                            } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                        }.textFieldStyle(.roundedBorder)
                    }
                    Button("添加快捷入口") { draft.links.append(.init(title: "", alias: "", target: "")) }
                    Divider()
                    Text("额外搜索目录").font(.headline)
                    Text("补充 Spotlight 未覆盖的目录；按需搜索文件名、路径和常见文本源码，不建立全盘索引。").font(.caption).foregroundStyle(.secondary)
                    ForEach(draft.searchRoots, id: \.self) { root in
                        HStack {
                            Text(root).font(.caption).lineLimit(1)
                            Spacer()
                            Button { draft.searchRoots.removeAll { $0 == root } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                        }
                    }
                    Button("添加目录") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true; panel.canChooseFiles = false
                        panel.allowsMultipleSelection = true
                        if panel.runModal() == .OK {
                            for url in panel.urls where !draft.searchRoots.contains(url.path) { draft.searchRoots.append(url.path) }
                        }
                    }
                    Divider()
                    Text("浏览器搜索").font(.headline)
                    Toggle("已打开的标签页（Safari / Chrome / Edge / Brave）", isOn: $draft.browserTabs)
                    Toggle("书签（Safari / Chromium / Firefox）", isOn: $draft.browserBookmarks)
                    Toggle("浏览历史（Safari / Chromium / Firefox）", isOn: $draft.browserHistory)
                    Text("仅本地读取；默认关闭。标签页可能触发系统自动化授权，Safari 历史和其他受保护目录可能需要完全磁盘访问。浏览器数据不写入 Launcher 索引。").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Text("快捷键").font(.headline)
                    Text("固定快捷键 ⌘␣。启用 Launcher 后接管 Spotlight 快捷键，关闭后恢复系统行为。")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = preferences.error ?? preferences.loadError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    preferences.error = nil
                    draft.links = draft.links.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.target.isEmpty }
                    preferences.update { $0 = draft }
                    if preferences.error == nil { dismiss() }
                }.keyboardShortcut(.defaultAction).disabled(preferences.loadError != nil)
            }
        }.padding(20).frame(width: 620, height: 500)
    }
}
