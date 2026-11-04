import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: AppPreferences
    var shortcutRuntime: ShortcutBindingRuntime
    var moduleStateController: ModuleStateController
    var mouseGestureController: MouseGestureController
    var clipboardHistoryStore: ClipboardHistoryStore?
    var clipboardMonitor: ClipboardMonitor?
    var clipboardLoadError: String?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var screenRecordingGranted = false
    @State private var accessibilityGranted = false
    @State private var inputMonitoringGranted = false
    @State private var showSettingsError = false
    @State private var missingSettingsPage = "屏幕录制"
    @State private var selectedSection = SettingsSection.modules
    @State private var editingBindingID: ShortcutBindingID?
    @State private var keyCaptureMessage: String?
    @State private var keyboardLayoutRevision = 0
    @State private var editingGestureRule: MouseGestureRule?
    @State private var gestureErrorMessage: String?
    @State private var clipboardLimitDraft = ""
    @State private var clipboardRetentionDaysDraft = ""
    @State private var clipboardErrorMessage: String?
    @State private var confirmsClearClipboard = false

    @State private var pullFrames: [MenuPullAnchor: CGRect] = [:]
    @State private var menuPull: SidebarMenuPull?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(theme.border)
                .frame(width: 1)
                .frame(maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .top)
            VStack(spacing: 0) {
                pageHeader
                Divider().opacity(0.6)
                ScrollView {
                    pageContent
                        .background(ThinScrollIndicatorInstaller())
                        .padding(.horizontal, 28)
                        .padding(.top, 20)
                        .padding(.bottom, 28)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.page)
        }
        .frame(width: 760, height: 580)
        .coordinateSpace(name: MenuPullAnchor.space)
        .onPreferenceChange(MenuPullFrames.self) { pullFrames = $0 }
        .overlay(alignment: .topLeading) {
            if let menuPull {
                SidebarMenuPullOverlay(pull: menuPull)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .task(id: menuPull?.started) {
            guard let menuPull else { return }
            do {
                try await Task.sleep(for: .seconds(SidebarMenuPull.duration))
                guard self.menuPull?.started == menuPull.started else { return }
                self.menuPull = nil
            } catch {}
        }
        .onChange(of: selectedSection) {
            menuPull = nil
        }
        .tint(NylaiPalette.accent)
        .onAppear {
            refreshPermission()
            syncClipboardDrafts()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermission()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSTextInputContext.keyboardSelectionDidChangeNotification)) { _ in
            keyboardLayoutRevision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            cancelRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window.identifier?.rawValue == "nylai.settings" else { return }
            cancelRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window.identifier?.rawValue == "nylai.settings" else { return }
            cancelRecording()
        }
        .onChange(of: selectedSection) {
            shortcutRuntime.endTransientRecording()
            cancelRecording()
            syncClipboardDrafts()
        }
        .onChange(of: visibleSections) { _, sections in
            guard !sections.contains(selectedSection) else { return }
            selectedSection = .modules
        }
        .onDisappear {
            shortcutRuntime.endTransientRecording()
            cancelRecording()
        }
        .alert("无法打开系统设置", isPresented: $showSettingsError) {
            Button("好", role: .cancel) {}
        } message: {
            Text("请前往系统设置 → 隐私与安全性 → \(missingSettingsPage)。")
        }
        .alert("快捷键错误", isPresented: operationErrorPresented) {
            Button("好", role: .cancel) { shortcutRuntime.clearOperationError() }
        } message: {
            Text(shortcutRuntime.operationError ?? "")
        }
        .alert("清空全部剪贴板历史？", isPresented: $confirmsClearClipboard) {
            Button("取消", role: .cancel) {}
            Button("清空全部", role: .destructive) {
                do {
                    try clipboardHistoryStore?.clearAll()
                } catch {
                    clipboardErrorMessage = error.localizedDescription
                }
            }
        } message: {
            Text("这会同时删除置顶记录，但不会修改系统剪贴板当前内容。")
        }
        .sheet(item: $editingGestureRule, onDismiss: {
            mouseGestureController.setRuleEditing(false)
        }) { rule in
            let isNew = rule.path.isEmpty
            GestureRuleEditorView(
                rule: rule,
                isNew: isNew,
                onBeginShortcutRecording: {
                    cancelRecording()
                    do {
                        try shortcutRuntime.beginTransientRecording()
                        return true
                    } catch {
                        shortcutRuntime.showError(error)
                        return false
                    }
                },
                onEndShortcutRecording: {
                    shortcutRuntime.endTransientRecording()
                }
            ) { updated in
                if isNew {
                    try mouseGestureController.addRule(updated)
                } else {
                    try mouseGestureController.updateRule(updated)
                }
            }
            .onDisappear {
                mouseGestureController.setRuleEditing(false)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image("BrandIcon")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 1) {
                    Text("拈来")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Nylai")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 20)

            Text("设置")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 18)
                .padding(.bottom, 7)

            VStack(spacing: 3) {
                sidebarItem(.modules)
                if moduleStateController.isEnabled(.screenshot) {
                    sidebarItem(.screenshot)
                }
                if moduleStateController.isEnabled(.globalShortcuts) {
                    sidebarItem(.shortcuts)
                }
                if moduleStateController.isEnabled(.mouseGestures) {
                    sidebarItem(.gestures)
                }
                if moduleStateController.isEnabled(.clipboard) {
                    sidebarItem(.clipboard)
                }
                sidebarItem(.general)
                sidebarItem(.permissions)
            }
            .reportMenuPullFrame(.sidebar)
            .padding(.horizontal, 10)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.12)
                    : .easeInOut(duration: 0.24).delay(0.28),
                value: visibleSections
            )

            Spacer(minLength: 20)
        }
        .frame(width: 196)
        .background(theme.sidebar)
    }

    private func sidebarItem(_ section: SettingsSection) -> some View {
        SidebarItem(
            section: section,
            isSelected: selectedSection == section
        ) {
            selectedSection = section
        }
        .opacity(menuPull?.section == section ? 0 : 1)
        .transition(reduceMotion ? .opacity : .identity)
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selectedSection.title)
                .font(.system(size: 22, weight: .semibold))
            Text(selectedSection.subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch selectedSection {
        case .modules:
            modulesPage
        case .screenshot:
            screenshotPage
        case .shortcuts:
            shortcutsPage
        case .gestures:
            gesturesPage
        case .clipboard:
            clipboardPage
        case .general:
            generalPage
        case .permissions:
            permissionsPage
        }
    }

    private var shortcutsPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 9) {
                sectionTitle("内置功能")
                SettingsCard {
                    if let configuration = shortcutRuntime.configuration {
                        let bindings = configuration.bindings.filter {
                            $0.isInternal
                                && $0.action != .scrollCapture
                                && $0.action != .openSettings
                        }
                        ForEach(Array(bindings.enumerated()), id: \.element.id) { index, binding in
                            bindingRow(binding, isLast: index == bindings.count - 1)
                        }
                    } else {
                        unavailableRow
                    }
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    sectionTitle("打开/切换应用")
                    Spacer()
                    Menu {
                        ForEach(runningApplications) { application in
                            Button {
                                addApplication(
                                    bundleIdentifier: application.bundleIdentifier,
                                    path: application.path
                                )
                            } label: {
                                Label {
                                    Text(application.name)
                                } icon: {
                                    Image(nsImage: application.icon)
                                }
                            }
                            .disabled(
                                boundApplicationBundleIdentifiers.contains(
                                    application.bundleIdentifier
                                )
                            )
                        }
                        if !runningApplications.isEmpty {
                            Divider()
                        }
                        Button("浏览应用程序…") {
                            chooseApplication()
                        }
                    } label: {
                        Label("添加应用", systemImage: "plus")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .foregroundStyle(NylaiPalette.accent)
                    .disabled(shortcutRuntime.configuration == nil)
                }

                SettingsCard {
                    if let configuration = shortcutRuntime.configuration {
                        let bindings = configuration.bindings.filter { !$0.isInternal }
                        if bindings.isEmpty {
                            emptyApplicationsRow
                        } else {
                            ForEach(Array(bindings.enumerated()), id: \.element.id) { index, binding in
                                applicationRow(binding, isLast: index == bindings.count - 1)
                            }
                        }
                    } else {
                        unavailableRow
                    }
                }
            }
        }
    }

    private var modulesPage: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("功能模块")
            SettingsCard {
                ForEach(Array(NylaiModuleID.allCases.enumerated()), id: \.element) { index, module in
                    moduleRow(module, isLast: index == NylaiModuleID.allCases.count - 1)
                }
            }
        }
    }

    private func moduleRow(_ module: NylaiModuleID, isLast: Bool) -> some View {
        let status = moduleStateController.status(for: module)
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                ActionIcon(
                    symbol: module.symbolName,
                    isEnabled: status != .off,
                    slashDelay: menuPull.flatMap { pull in
                        SettingsSection(module: module) == pull.section ? pull.slashDelay : nil
                    } ?? 0
                )
                .reportMenuPullFrame(.icon(module))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(module.title)
                            .font(.system(size: 13, weight: .medium))
                        Text(status.title)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(moduleStatusColor(status))
                    }
                    Text(module.summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    if case .failed(let reason) = status {
                        Text(reason)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.danger)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 12)
                Toggle("", isOn: moduleEnabledBinding(module))
                    .labelsHidden()
                    .compactSettingsSwitch()
                    .disabled(module == .globalShortcuts && shortcutRuntime.loadError != nil)
                    .accessibilityLabel(module.title)
            }
            .padding(14)
            if !isLast {
                Divider().padding(.leading, 54)
            }
        }
    }

    private var gesturesPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let loadError = mouseGestureController.loadError {
                SettingsCard {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(theme.danger)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(loadError)
                            Button("使用新的空配置") {
                                do {
                                    try mouseGestureController.useNewEmptyConfiguration()
                                } catch {
                                    gestureErrorMessage = error.localizedDescription
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                        Spacer()
                    }
                    .font(.system(size: 11.5))
                    .padding(14)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    sectionTitle("行为")
                    Spacer()
                    Text(mouseGestureController.statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                SettingsCard {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("显示手势轨迹")
                                .font(.system(size: 13, weight: .medium))
                            Text("仅在按住右键识别期间显示，松开或取消后立即清除。")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: showsGestureTraceBinding)
                            .labelsHidden()
                            .compactSettingsSwitch()
                    }
                    .padding(14)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    sectionTitle("手势规则")
                    Spacer()
                    Button {
                        mouseGestureController.setRuleEditing(true)
                        editingGestureRule = MouseGestureRule(
                            path: GesturePath(),
                            action: .nylai(.openSettings)
                        )
                    } label: {
                        Label("添加规则", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }
                SettingsCard {
                    let rules = mouseGestureController.configuration?.rules ?? []
                    if rules.isEmpty {
                        Text("尚无规则。添加后会显示在此处。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    } else {
                        ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                            gestureRuleRow(rule, isLast: index == rules.count - 1)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    sectionTitle("应用禁用名单")
                    Spacer()
                    Button("添加应用…") {
                        addGestureDisabledApplication()
                    }
                    .buttonStyle(.borderless)
                }
                SettingsCard {
                    let disabled = Array(
                        mouseGestureController.configuration?.disabledBundleIdentifiers ?? []
                    ).sorted()
                    if disabled.isEmpty {
                        Text("名单内应用不会识别或拦截鼠标手势。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    } else {
                        ForEach(Array(disabled.enumerated()), id: \.element) { index, bundleIdentifier in
                            HStack(spacing: 10) {
                                ApplicationIconView(
                                    path: NSWorkspace.shared
                                        .urlForApplication(withBundleIdentifier: bundleIdentifier)?
                                        .path(percentEncoded: false)
                                )
                                Text(applicationName(bundleIdentifier))
                                    .font(.system(size: 12.5))
                                Spacer()
                                Button("移除") {
                                    do {
                                        try mouseGestureController.setApplicationDisabled(
                                            false,
                                            bundleIdentifier: bundleIdentifier
                                        )
                                    } catch {
                                        gestureErrorMessage = error.localizedDescription
                                    }
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            if index != disabled.count - 1 {
                                Divider().padding(.leading, 54)
                            }
                        }
                    }
                }
            }

            if case .failed(let reason) = mouseGestureController.runtimeStatus {
                HStack(spacing: 8) {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.danger)
                    Spacer()
                    Button("系统设置…") {
                        _ = AccessibilityPermission.openSystemSettings()
                    }
                    .buttonStyle(.borderless)
                    Button("重试") {
                        mouseGestureController.retry()
                    }
                }
                .font(.system(size: 11.5))
            } else if let gestureErrorMessage {
                Text(gestureErrorMessage)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.danger)
            }
        }
    }

    private var clipboardPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let clipboardLoadError {
                SettingsCard {
                    Label(clipboardLoadError, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
            }

            if let store = clipboardHistoryStore {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        sectionTitle("记录")
                        Spacer()
                        Text(clipboardMonitor?.statusText ?? "已关闭")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        if case .failed = clipboardMonitor?.runtimeStatus {
                            Button("重试") {
                                clipboardMonitor?.retry()
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                        }
                    }
                    SettingsCard {
                        VStack(spacing: 0) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("普通记录上限")
                                        .font(.system(size: 13, weight: .medium))
                                    Text("置顶记录不计入上限。完成输入后点应用才会清理。")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                TextField("200", text: $clipboardLimitDraft)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 76)
                                Text("条")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                Button("应用") {
                                    applyClipboardLimits()
                                }
                                .controlSize(.small)
                            }
                            .padding(14)

                            Divider().padding(.leading, 14)

                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("按天自动清理")
                                        .font(.system(size: 13, weight: .medium))
                                    Text("按最后复制时间计算；置顶记录永不自动删除。")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                TextField("30", text: $clipboardRetentionDaysDraft)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 54)
                                    .disabled(!store.settings.retentionEnabled)
                                Text("天")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                Toggle("", isOn: clipboardRetentionBinding)
                                    .labelsHidden()
                                    .compactSettingsSwitch()
                                Button("应用") {
                                    applyClipboardLimits()
                                }
                                .controlSize(.small)
                            }
                            .padding(14)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        sectionTitle("应用屏蔽")
                        Spacer()
                        Button("添加应用…") {
                            addClipboardDisabledApplication()
                        }
                        .buttonStyle(.borderless)
                    }
                    SettingsCard {
                        if store.settings.disabledBundleIdentifiers.isEmpty {
                            Text("可结合来源标记和观察时的前台应用跳过复制内容；macOS 不保证来源百分之百准确。")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                        } else {
                            let values = Array(store.settings.disabledBundleIdentifiers).sorted()
                            ForEach(Array(values.enumerated()), id: \.element) { index, bundleIdentifier in
                                HStack(spacing: 10) {
                                    ApplicationIconView(
                                        path: NSWorkspace.shared
                                            .urlForApplication(withBundleIdentifier: bundleIdentifier)?
                                            .path(percentEncoded: false)
                                    )
                                    Text(applicationName(bundleIdentifier))
                                        .font(.system(size: 12.5))
                                    Spacer()
                                    Button("移除") {
                                        removeClipboardDisabledApplication(bundleIdentifier)
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                if index != values.count - 1 {
                                    Divider().padding(.leading, 54)
                                }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 9) {
                    sectionTitle("数据管理")
                    SettingsCard {
                        VStack(spacing: 0) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(store.ordinaryRecords.count) 条普通 · \(store.pinnedRecords.count) 条置顶")
                                        .font(.system(size: 13, weight: .medium))
                                    Text("删除历史不会修改系统剪贴板当前内容。")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("清空普通记录") {
                                    do {
                                        try store.clearOrdinary()
                                    } catch {
                                        clipboardErrorMessage = error.localizedDescription
                                    }
                                }
                                .controlSize(.small)
                                Button("清空全部…") {
                                    confirmsClearClipboard = true
                                }
                                .controlSize(.small)
                            }
                            .padding(14)
                        }
                    }
                }
            }

            if let clipboardErrorMessage {
                Text(clipboardErrorMessage)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.danger)
            }
        }
    }

    private func gestureRuleRow(_ rule: MouseGestureRule, isLast: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                GesturePathThumbnail(path: rule.path)
                    .frame(width: 74, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    if case .sendShortcut(let shortcut) = rule.action {
                        ShortcutKeycaps(shortcut: shortcut)
                    } else {
                        Text(rule.action.title)
                            .font(.system(size: 13, weight: .medium))
                    }
                    Text(rule.scopeBundleIdentifier == nil
                        ? "所有应用"
                        : applicationName(rule.scopeBundleIdentifier))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("编辑") {
                    mouseGestureController.setRuleEditing(true)
                    editingGestureRule = rule
                }
                .buttonStyle(.borderless)
                Button {
                    do {
                        try mouseGestureController.setRuleEnabled(!rule.isEnabled, id: rule.id)
                    } catch {
                        gestureErrorMessage = error.localizedDescription
                    }
                } label: {
                    Image(systemName: rule.isEnabled ? "pause.circle" : "play.circle")
                }
                .buttonStyle(.borderless)
                .help(rule.isEnabled ? "停用规则" : "启用规则")
                Button {
                    do {
                        try mouseGestureController.removeRule(rule.id)
                    } catch {
                        gestureErrorMessage = error.localizedDescription
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .padding(14)
            if !isLast {
                Divider().padding(.leading, 54)
            }
        }
    }

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 9) {
                sectionTitle("外观")
                SettingsCard {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("视觉模式")
                                .font(.system(size: 13, weight: .medium))
                            Text("只影响 \(AppName.current) 的窗口与面板。")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 12)

                        AppearanceModePicker(selection: appearanceModeBinding)
                        .frame(width: 230)
                    }
                    .padding(14)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                sectionTitle("启动")
                SettingsCard {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("打开应用时显示设置")
                                .font(.system(size: 13, weight: .medium))
                            Text("启动 \(AppName.current) 后自动打开此窗口。")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 12)

                        Toggle("", isOn: $preferences.showSettingsOnLaunch)
                            .labelsHidden()
                            .compactSettingsSwitch()
                            .accessibilityLabel("打开应用时显示设置")
                    }
                    .padding(14)
                }
            }
        }
    }

    private var screenshotPage: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("历史")
            SettingsCard {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("记录最近截图")
                            .font(.system(size: 13, weight: .medium))
                        Text("复制、保存或置顶成功后保留一张缩略图和 PNG。关闭不会删除已有记录。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    Toggle("", isOn: $preferences.screenshotHistoryEnabled)
                        .labelsHidden()
                        .compactSettingsSwitch()
                        .accessibilityLabel("记录最近截图")
                }
                .padding(14)
            }
        }
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 9) {
                sectionTitle("屏幕录制")
                SettingsCard {
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                                .frame(width: 28, height: 28)
                                .overlay {
                                    Image(systemName: "display")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 7) {
                                    Text("屏幕录制")
                                        .font(.system(size: 13, weight: .medium))
                                    permissionBadge(granted: screenRecordingGranted)
                                }
                                Text("用于截取屏幕内容。修改授权后可能需要重新启动 \(AppName.current)。")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 12)

                            HStack(spacing: 8) {
                                if !screenRecordingGranted {
                                    Button("请求权限") {
                                        _ = ScreenRecordingPermission.requestAccessIfNeeded()
                                        refreshPermission()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                }
                                Button("系统设置…") {
                                    missingSettingsPage = "屏幕录制"
                                    showSettingsError = !ScreenRecordingPermission.openSystemSettings()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .padding(14)

                        Divider().padding(.leading, 54)

                        HStack(spacing: 8) {
                            Text(screenRecordingGranted ? "权限已生效。" : "尚未授权，截图时会提示开启权限。")
                            Spacer()
                            Button("刷新状态") {
                                refreshPermission()
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(NylaiPalette.accent)
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                sectionTitle("窗口切换")
                SettingsCard {
                    permissionRow(
                        title: "辅助功能",
                        icon: "accessibility",
                        description: "用于定位并激活所选窗口。",
                        isGranted: accessibilityGranted,
                        requestPermission: {
                            _ = AccessibilityPermission.requestIfNeeded()
                            refreshPermission()
                        }
                    ) {
                        missingSettingsPage = "辅助功能"
                        showSettingsError = !AccessibilityPermission.openSystemSettings()
                    }
                    Divider().padding(.leading, 54)
                    permissionRow(
                        title: "输入监控",
                        icon: "keyboard",
                        description: "用于接管 Command-Tab 和 Command-反引号键。",
                        isGranted: inputMonitoringGranted,
                        requestPermission: {
                            _ = InputMonitoringPermission.requestIfNeeded()
                            refreshPermission()
                        }
                    ) {
                        missingSettingsPage = "输入监控"
                        showSettingsError = !InputMonitoringPermission.openSystemSettings()
                    }
                }
            }
        }
    }

    private func permissionRow(
        title: String,
        icon: String,
        description: String,
        isGranted: Bool,
        requestPermission: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                    permissionBadge(granted: isGranted)
                }
                Text(description)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                if !isGranted {
                    Button("请求权限", action: requestPermission)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                Button("系统设置…", action: openSettings)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(14)
    }

    private func bindingRow(_ binding: ShortcutBinding, isLast: Bool) -> some View {
        let status = shortcutRuntime.status(for: binding.id)
        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                ActionIcon(symbol: binding.action.iconName)

                VStack(alignment: .leading, spacing: 3) {
                    Text(ShortcutBindingRuntime.title(for: binding.action))
                        .font(.system(size: 13, weight: .medium))

                    statusLine(status, id: binding.id)

                    if editingBindingID == binding.id, let keyCaptureMessage {
                        Text(keyCaptureMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)
                recorder(for: binding)

                Toggle("", isOn: bindingEnabledBinding(binding))
                    .labelsHidden()
                    .compactSettingsSwitch()
                    .accessibilityLabel("启用「\(ShortcutBindingRuntime.title(for: binding.action))」")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            if !isLast {
                Divider().padding(.leading, 54)
            }
        }
    }

    private func applicationRow(_ binding: ShortcutBinding, isLast: Bool) -> some View {
        let status = shortcutRuntime.status(for: binding.id)
        let target = binding.applicationTarget
        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                ApplicationIconView(path: target?.path)

                VStack(alignment: .leading, spacing: 3) {
                    Text(applicationName(for: target))
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(target?.path ?? "")

                    if let target {
                        Toggle("再次触发时隐藏", isOn: hidesOnRepeatBinding(binding.id, fallback: target.hidesOnRepeatTrigger))
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    statusLine(status, id: binding.id)

                    if let target, !FileManager.default.fileExists(atPath: target.path) {
                        HStack(spacing: 6) {
                            Text(ApplicationLaunchError.missingApplication.localizedDescription)
                                .foregroundStyle(theme.danger)
                            Button("重新定位…") { relocateApplication(binding.id) }
                                .buttonStyle(.borderless)
                                .foregroundStyle(NylaiPalette.accent)
                        }
                        .font(.system(size: 11))
                    }

                    if editingBindingID == binding.id, let keyCaptureMessage {
                        Text(keyCaptureMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)
                recorder(for: binding)

                Toggle("", isOn: bindingEnabledBinding(binding))
                    .labelsHidden()
                    .compactSettingsSwitch()
                    .accessibilityLabel("启用「\(applicationName(for: target))」")

                Button {
                    do {
                        try shortcutRuntime.removeApplicationBinding(binding.id)
                    } catch {
                        handle(error)
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("删除应用绑定")
                .accessibilityLabel("删除「\(applicationName(for: target))」")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            if !isLast {
                Divider().padding(.leading, 54)
            }
        }
    }

    private var emptyApplicationsRow: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.tertiary)
                }

            Text("尚未添加应用")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var unavailableRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.danger)
            Text("快捷键配置不可用")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(14)
    }

    private func recorder(for binding: ShortcutBinding) -> some View {
        ShortcutRecorder(
            shortcut: binding.shortcut,
            isRecording: editingBindingID == binding.id,
            onBegin: { beginRecording(binding.id) },
            onCapture: { shortcut in capture(shortcut, bindingID: binding.id) },
            onCancel: { cancelRecording(binding.id) },
            onClear: { clear(bindingID: binding.id) },
            onMessage: { keyCaptureMessage = $0 }
        )
        .frame(width: 112, height: 28)
        .focusEffectDisabled()
        .id("\(binding.id.rawValue)-\(keyboardLayoutRevision)")
    }

    @ViewBuilder
    private func statusLine(_ status: ShortcutBindingStatus, id: ShortcutBindingID) -> some View {
        if case .failed(let reason) = status {
            HStack(spacing: 5) {
                Text(reason)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(reason)

                Button("重试") {
                    shortcutRuntime.retry(id)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(NylaiPalette.accent)
            }
            .font(.system(size: 11))
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func moduleEnabledBinding(_ module: NylaiModuleID) -> Binding<Bool> {
        Binding(
            get: { moduleStateController.isEnabled(module) },
            set: { value in
                do {
                    guard moduleStateController.isEnabled(module) != value else { return }
                    let pull = makeMenuPull(module: module, appearing: value)
                    try moduleStateController.setEnabled(value, for: module)
                    menuPull = pull
                } catch {
                    handle(error)
                }
            }
        )
    }

    private var showsGestureTraceBinding: Binding<Bool> {
        Binding(
            get: { mouseGestureController.configuration?.showsTrace ?? true },
            set: { value in
                do {
                    try mouseGestureController.setShowsTrace(value)
                } catch {
                    gestureErrorMessage = error.localizedDescription
                }
            }
        )
    }

    private var appearanceModeBinding: Binding<AppAppearanceMode> {
        Binding(
            get: { preferences.appearanceMode },
            set: { mode in
                preferences.appearanceMode = mode
                mode.apply()
            }
        )
    }

    private func addGestureDisabledApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "加入名单"
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleIdentifier = Bundle(url: url)?.bundleIdentifier else {
            return
        }
        do {
            try mouseGestureController.setApplicationDisabled(
                true,
                bundleIdentifier: bundleIdentifier
            )
        } catch {
            gestureErrorMessage = error.localizedDescription
        }
    }

    private var clipboardRetentionBinding: Binding<Bool> {
        Binding(
            get: { clipboardHistoryStore?.settings.retentionEnabled ?? false },
            set: { value in
                guard let store = clipboardHistoryStore else { return }
                var settings = store.settings
                settings.retentionEnabled = value
                if value, settings.retentionDays < 1 {
                    settings.retentionDays = 30
                }
                do {
                    try store.updateSettings(settings)
                    syncClipboardDrafts()
                } catch {
                    clipboardErrorMessage = error.localizedDescription
                }
            }
        )
    }

    private func syncClipboardDrafts() {
        guard let settings = clipboardHistoryStore?.settings else { return }
        clipboardLimitDraft = "\(settings.maximumItems)"
        clipboardRetentionDaysDraft = "\(settings.retentionDays)"
    }

    private func applyClipboardLimits() {
        guard let store = clipboardHistoryStore,
              let maximumItems = Int(clipboardLimitDraft),
              let retentionDays = Int(clipboardRetentionDaysDraft),
              (1...5_000).contains(maximumItems),
              (1...365).contains(retentionDays) else {
            clipboardErrorMessage = "普通上限需为 1–5000，保留天数为 1–365。"
            return
        }
        var settings = store.settings
        settings.maximumItems = maximumItems
        settings.retentionDays = retentionDays
        do {
            try store.updateSettings(settings)
            clipboardErrorMessage = nil
            syncClipboardDrafts()
        } catch {
            clipboardErrorMessage = error.localizedDescription
        }
    }

    private func addClipboardDisabledApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "加入名单"
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleIdentifier = Bundle(url: url)?.bundleIdentifier,
              let store = clipboardHistoryStore else {
            return
        }
        var settings = store.settings
        settings.disabledBundleIdentifiers.insert(bundleIdentifier)
        do {
            try store.updateSettings(settings)
        } catch {
            clipboardErrorMessage = error.localizedDescription
        }
    }

    private func removeClipboardDisabledApplication(_ bundleIdentifier: String) {
        guard let store = clipboardHistoryStore else { return }
        var settings = store.settings
        settings.disabledBundleIdentifiers.remove(bundleIdentifier)
        do {
            try store.updateSettings(settings)
        } catch {
            clipboardErrorMessage = error.localizedDescription
        }
    }

    private func applicationName(_ bundleIdentifier: String?) -> String {
        guard let bundleIdentifier else { return "所有应用" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        return bundleIdentifier
    }

    private func bindingEnabledBinding(_ binding: ShortcutBinding) -> Binding<Bool> {
        Binding(
            get: { shortcutRuntime.binding(for: binding.id)?.isEnabled ?? binding.isEnabled },
            set: { value in
                do {
                    try shortcutRuntime.setBindingEnabled(value, for: binding.id)
                } catch {
                    handle(error)
                }
            }
        )
    }

    private func hidesOnRepeatBinding(_ id: ShortcutBindingID, fallback: Bool) -> Binding<Bool> {
        Binding(
            get: { shortcutRuntime.binding(for: id)?.applicationTarget?.hidesOnRepeatTrigger ?? fallback },
            set: { value in
                do {
                    try shortcutRuntime.setHidesOnRepeatTrigger(value, for: id)
                } catch {
                    handle(error)
                }
            }
        )
    }

    private func permissionBadge(granted: Bool) -> some View {
        let color = granted ? theme.success : theme.warning
        return Text(granted ? "已授权" : "未授权")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private func applicationName(for target: ApplicationShortcutTarget?) -> String {
        guard let target else { return "未知应用" }
        if let bundle = Bundle(path: target.path) {
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
               !name.isEmpty {
                return name
            }
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
               !name.isEmpty {
                return name
            }
        }
        let name = URL(fileURLWithPath: target.path).deletingPathExtension().lastPathComponent
        return name.isEmpty ? target.bundleIdentifier : name
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "添加"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleIdentifier = Bundle(url: url)?.bundleIdentifier else {
            if panel.url != nil {
                shortcutRuntime.showError(ShortcutOperationError.invalidApplication)
            }
            return
        }
        addApplication(
            bundleIdentifier: bundleIdentifier,
            path: url.path(percentEncoded: false)
        )
    }

    private func addApplication(bundleIdentifier: String, path: String) {
        do {
            _ = try shortcutRuntime.addApplicationBinding(
                bundleIdentifier: bundleIdentifier,
                path: path
            )
        } catch {
            handle(error)
        }
    }

    private var runningApplications: [RunningApplicationMenuItem] {
        var applications: [String: RunningApplicationMenuItem] = [:]
        for application in NSWorkspace.shared.runningApplications
        where application.activationPolicy == .regular {
            guard !application.isTerminated,
                  let bundleIdentifier = application.bundleIdentifier,
                  let url = application.bundleURL
                    ?? NSWorkspace.shared.urlForApplication(
                        withBundleIdentifier: bundleIdentifier
                    )
            else {
                continue
            }
            let name = application.localizedName
                ?? url.deletingPathExtension().lastPathComponent
            applications[bundleIdentifier] = RunningApplicationMenuItem(
                bundleIdentifier: bundleIdentifier,
                path: url.path(percentEncoded: false),
                name: name,
                icon: NSWorkspace.shared.icon(forFile: url.path)
            )
        }
        return applications.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private var boundApplicationBundleIdentifiers: Set<String> {
        Set(
            shortcutRuntime.configuration?.bindings.compactMap { binding in
                guard case .application(let target) = binding.action else { return nil }
                return target.bundleIdentifier
            } ?? []
        )
    }

    private func relocateApplication(_ id: ShortcutBindingID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "重新定位"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleIdentifier = Bundle(url: url)?.bundleIdentifier else {
            return
        }
        do {
            try shortcutRuntime.relocateApplication(
                id,
                path: url.path(percentEncoded: false),
                bundleIdentifier: bundleIdentifier
            )
        } catch {
            handle(error)
        }
    }

    private var operationErrorPresented: Binding<Bool> {
        Binding(
            get: { shortcutRuntime.operationError != nil },
            set: { if !$0 { shortcutRuntime.clearOperationError() } }
        )
    }

    private func beginRecording(_ id: ShortcutBindingID) -> Bool {
        if editingBindingID != nil {
            cancelRecording()
        }
        guard editingBindingID == nil else { return false }
        do {
            try shortcutRuntime.beginRecording(id)
            editingBindingID = id
            keyCaptureMessage = nil
            return true
        } catch {
            handle(error)
            return false
        }
    }

    private func capture(_ shortcut: ShortcutKey, bindingID: ShortcutBindingID) {
        do {
            try shortcutRuntime.updateShortcut(shortcut, for: bindingID)
            finishRecording()
        } catch {
            keyCaptureMessage = error.localizedDescription
            NSSound.beep()
        }
    }

    private func clear(bindingID: ShortcutBindingID) {
        do {
            try shortcutRuntime.updateShortcut(nil, for: bindingID)
            finishRecording()
        } catch {
            keyCaptureMessage = error.localizedDescription
        }
    }

    private func cancelRecording(_ id: ShortcutBindingID? = nil) {
        if let id, editingBindingID != id { return }
        guard editingBindingID != nil else { return }
        editingBindingID = nil
        keyCaptureMessage = nil
        shortcutRuntime.endRecording()
    }

    private func finishRecording() {
        editingBindingID = nil
        keyCaptureMessage = nil
        shortcutRuntime.endRecording()
    }

    private func handle(_ error: Error) {
        shortcutRuntime.showError(error)
    }

    private func moduleStatusColor(_ status: ModuleRuntimeStatus) -> Color {
        switch status {
        case .running, .available:
            theme.success
        case .starting:
            theme.warning
        case .failed:
            theme.danger
        case .off:
            .secondary
        }
    }

    private func refreshPermission() {
        screenRecordingGranted = ScreenRecordingPermission.isGranted
        accessibilityGranted = AccessibilityPermission.isGranted
        inputMonitoringGranted = InputMonitoringPermission.isGranted
    }

    private var theme: SettingsTheme {
        SettingsTheme(colorScheme: colorScheme)
    }

    private func makeMenuPull(module: NylaiModuleID, appearing: Bool) -> SidebarMenuPull? {
        guard !reduceMotion, selectedSection == .modules,
              let section = SettingsSection(module: module),
              let sidebar = pullFrames[.sidebar],
              let icon = pullFrames[.icon(module)] else { return nil }
        let orderedModules = NylaiModuleID.allCases.prefix { $0 != module }
        let row = 1 + orderedModules.filter {
            SettingsSection(module: $0) != nil && moduleStateController.isEnabled($0)
        }.count
        let slot = CGRect(x: sidebar.minX, y: sidebar.minY + CGFloat(row) * 37,
                          width: sidebar.width, height: 34)
        return SidebarMenuPull(section: section, slot: slot, icon: icon, appearing: appearing)
    }

    private var visibleSections: [SettingsSection] {
        let moduleSections: [SettingsSection] = NylaiModuleID.allCases.compactMap {
            module -> SettingsSection? in
            guard moduleStateController.isEnabled(module) else { return nil }
            return SettingsSection(module: module)
        }
        return [.modules] + moduleSections + [.general, .permissions]
    }
}

private enum SettingsSection: Hashable {
    case modules
    case screenshot
    case general
    case permissions
    case shortcuts
    case gestures
    case clipboard

    var title: String {
        switch self {
        case .modules:
            "功能"
        case .screenshot:
            "截图"
        case .shortcuts:
            "快捷键"
        case .gestures:
            "鼠标手势"
        case .clipboard:
            "剪贴板"
        case .general:
            "通用"
        case .permissions:
            "系统权限"
        }
    }

    var subtitle: String {
        switch self {
        case .modules:
            "启用或停用 \(AppName.current) 的功能模块。"
        case .screenshot:
            "管理最近截图的记录方式。"
        case .shortcuts:
            "为截图等内置功能或常用应用分配快捷键。"
        case .gestures:
            "按住右键绘制路径，松开后执行绑定动作。"
        case .clipboard:
            "管理剪贴板历史、来源屏蔽和保留期限。"
        case .general:
            "控制 \(AppName.current) 的视觉模式与启动行为。"
        case .permissions:
            "查看屏幕录制、辅助功能和输入监控的授权状态。"
        }
    }

    var symbol: String {
        switch self {
        case .modules:
            "square.grid.2x2"
        case .screenshot:
            "viewfinder"
        case .shortcuts:
            "keyboard"
        case .gestures:
            "hand.draw"
        case .clipboard:
            "doc.on.clipboard"
        case .general:
            "gearshape"
        case .permissions:
            "lock.shield"
        }
    }

    init?(module: NylaiModuleID) {
        switch module {
        case .screenshot:
            self = .screenshot
        case .globalShortcuts:
            self = .shortcuts
        case .mouseGestures:
            self = .gestures
        case .clipboard:
            self = .clipboard
        case .windowSwitcher:
            return nil
        }
    }
}

private extension NylaiModuleID {
    var symbolName: String {
        switch self {
        case .screenshot:
            "viewfinder"
        case .globalShortcuts:
            "keyboard"
        case .mouseGestures:
            "hand.draw"
        case .clipboard:
            "doc.on.clipboard"
        case .windowSwitcher:
            "rectangle.on.rectangle"
        }
    }
}

private struct SidebarItem: View {
    let section: SettingsSection
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var selectionTrigger = 0

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .symbolEffect(
                        .bounce,
                        options: .nonRepeating,
                        value: selectionTrigger
                    )

                Text(section.title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(Color.primary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background {
                selectionShape.fill(backgroundColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .onChange(of: isSelected) { wasSelected, isSelected in
            guard isSelected, !wasSelected else { return }
            selectionTrigger &+= 1
        }
    }

    private var selectionShape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    private var backgroundColor: Color {
        if isSelected {
            return theme.selected
        }
        return isHovered ? Color.primary.opacity(0.05) : .clear
    }

    private var theme: SettingsTheme {
        SettingsTheme(colorScheme: colorScheme)
    }
}

private enum MenuPullAnchor: Hashable, Sendable {
    static let space = "settings.menuPull"
    case sidebar
    case icon(NylaiModuleID)
}

private struct MenuPullFrames: PreferenceKey {
    static let defaultValue: [MenuPullAnchor: CGRect] = [:]

    static func reduce(value: inout [MenuPullAnchor: CGRect], nextValue: () -> [MenuPullAnchor: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct SidebarMenuPull {
    static let duration = 0.72
    static let catchTime = 0.23
    static let landing = 0.70
    let section: SettingsSection
    let slot: CGRect
    let icon: CGRect
    let appearing: Bool
    let started = Date()

    var slashDelay: Double {
        Self.duration * (appearing ? Self.catchTime : Self.landing)
    }
}

private struct SidebarMenuPullOverlay: View {
    let pull: SidebarMenuPull
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = clamp(timeline.date.timeIntervalSince(pull.started) / SidebarMenuPull.duration)
            let sidebar = CGPoint(x: pull.slot.midX, y: pull.slot.midY)
            let icon = CGPoint(x: pull.icon.midX, y: pull.icon.midY)
            let iconAnchor = CGPoint(x: pull.icon.minX + 2, y: pull.icon.minY + 2)
            let throwOrigin = pull.appearing ? sidebar : icon
            let catchPoint = pull.appearing ? icon : sidebar
            let ropeOrigin = pull.appearing ? sidebar : iconAnchor
            let ropeTarget = pull.appearing ? iconAnchor : sidebar
            let travel = clamp((time - 0.30) / 0.40)
            let tug = pow(travel, 2.35)
            let impact = clamp((time - SidebarMenuPull.landing) / 0.25)
            let recoil = sin(impact * .pi * 4) * pow(1 - impact, 2) * 7
            let tension = sin(.pi * clamp((time - 0.21) / 0.18))
            let center = CGPoint(
                x: mix(catchPoint.x, throwOrigin.x, tug) + (pull.appearing ? -recoil : recoil),
                y: mix(catchPoint.y, throwOrigin.y, tug) - sin(.pi * travel) * 9
            )
            let scale = pull.appearing ? mix(0.18, 1, tug) : mix(1, 0.18, tug)
            let cast = clamp(time / SidebarMenuPull.catchTime)
            let castEase = 1 - pow(1 - cast, 2)
            let lineTip = cast < 1
                ? CGPoint(x: mix(ropeOrigin.x, ropeTarget.x, castEase),
                          y: mix(ropeOrigin.y, ropeTarget.y, castEase) - sin(.pi * cast) * 19)
                : CGPoint(x: center.x + (pull.appearing ? (iconAnchor.x - icon.x) * (1 - tug) : 0),
                          y: center.y + (pull.appearing ? (iconAnchor.y - icon.y) * (1 - tug) : 0))
            let release = clamp((time - 0.65) / 0.24)
            let lineStart = pull.appearing
                ? CGPoint(x: mix(ropeOrigin.x, lineTip.x, release),
                          y: mix(ropeOrigin.y, lineTip.y, release))
                : ropeOrigin

            ZStack(alignment: .topLeading) {
                HStack(spacing: 9) {
                    Image(systemName: pull.section.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                    Text(pull.section.title)
                        .font(.system(size: 13))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(width: pull.slot.width, height: pull.slot.height)
                .background(SettingsTheme(colorScheme: colorScheme).sidebar,
                            in: RoundedRectangle(cornerRadius: 8))
                .scaleEffect(x: scale * (1 + tension * 0.055), y: scale * (1 - tension * 0.07))
                .position(center)
                .opacity(pull.appearing
                         ? clamp((time - 0.19) / 0.10)
                         : 1 - clamp((time - 0.79) / 0.18))

                Path { path in
                    path.move(to: lineStart)
                    path.addQuadCurve(
                        to: lineTip,
                        control: CGPoint(
                            x: (lineStart.x + lineTip.x) / 2,
                            y: (lineStart.y + lineTip.y) / 2
                                + (sin(.pi * cast) * 22 - tension * 6 + 4) * (1 - release)
                        )
                    )
                }
                .stroke(NylaiPalette.accent.opacity(0.76 * (1 - release)),
                        style: StrokeStyle(lineWidth: 1.25 + tension * 0.65, lineCap: .round))

                Circle()
                    .fill(NylaiPalette.accent)
                    .frame(width: 4, height: 4)
                    .position(lineTip)
                    .opacity((1 - release) * min(1, cast * 10))
            }
        }
    }

    private func mix(_ start: Double, _ end: Double, _ fraction: Double) -> Double {
        start + (end - start) * fraction
    }

    private func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}

private extension View {
    func reportMenuPullFrame(_ anchor: MenuPullAnchor) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: MenuPullFrames.self,
                    value: [anchor: geometry.frame(in: .named(MenuPullAnchor.space))]
                )
            }
        }
    }

    func compactSettingsSwitch() -> some View {
        toggleStyle(.switch)
            .controlSize(.small)
            .scaleEffect(0.8, anchor: .trailing)
    }
}

struct SettingsCard<Content: View>: View {
    let content: Content
    @Environment(\.colorScheme) private var colorScheme

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.card)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 0.5)
        }
    }

    private var theme: SettingsTheme {
        SettingsTheme(colorScheme: colorScheme)
    }
}

private struct ActionIcon: View {
    let symbol: String
    var isEnabled = true
    var slashDelay: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.primary.opacity(0.06))
            .frame(width: 28, height: 28)
            .overlay {
                ZStack {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .opacity(isEnabled ? 1 : 0.7)

                    Path { path in
                        path.move(to: CGPoint(x: 5, y: 5))
                        path.addLine(to: CGPoint(x: 23, y: 23))
                    }
                        .trim(from: 0, to: isEnabled ? 0 : 1)
                        .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                        .frame(width: 28, height: 28)
                        .opacity(isEnabled ? 0 : 0.9)
                        .animation(
                            reduceMotion
                                ? .easeOut(duration: 0.12)
                                : .easeInOut(duration: 0.18).delay(slashDelay),
                            value: isEnabled
                        )
                }
            }
            .accessibilityHidden(true)
    }
}

private struct AppearanceModePicker: View {
    @Binding var selection: AppAppearanceMode
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let inset: CGFloat = 4
            let segmentWidth = (geometry.size.width - inset * 2)
                / CGFloat(AppAppearanceMode.allCases.count)
            let selectedIndex = AppAppearanceMode.allCases.firstIndex(of: selection) ?? 0

            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.055))

                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(NylaiPalette.accent.opacity(colorScheme == .dark ? 0.24 : 0.16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(
                                NylaiPalette.accent.opacity(colorScheme == .dark ? 0.38 : 0.24),
                                lineWidth: 0.5
                            )
                    }
                    .frame(
                        width: max(0, segmentWidth - 8),
                        height: max(0, geometry.size.height - inset * 2)
                    )
                    .position(
                        x: inset + segmentWidth * (CGFloat(selectedIndex) + 0.5),
                        y: geometry.size.height / 2
                    )
                    .animation(
                        reduceMotion
                            ? .easeOut(duration: 0.12)
                            : .spring(response: 0.32, dampingFraction: 0.86),
                        value: selection
                    )

                HStack(spacing: 0) {
                    ForEach(AppAppearanceMode.allCases) { mode in
                        Button {
                            selection = mode
                        } label: {
                            Text(mode.title)
                                .font(.system(
                                    size: 11.5,
                                    weight: selection == mode ? .semibold : .regular
                                ))
                                .foregroundStyle(
                                    selection == mode ? Color.primary : Color.secondary
                                )
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(mode.title)
                        .accessibilityAddTraits(selection == mode ? .isSelected : [])
                    }
                }
                .padding(inset)
            }
        }
        .frame(height: 30)
    }
}

private struct RunningApplicationMenuItem: Identifiable {
    let bundleIdentifier: String
    let path: String
    let name: String
    let icon: NSImage

    var id: String { bundleIdentifier }
}

private struct ApplicationIconView: View {
    let path: String?

    var body: some View {
        Group {
            if let path, FileManager.default.fileExists(atPath: path) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .overlay {
                        Image(systemName: "macwindow")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: 28, height: 28)
    }
}

private extension ShortcutBinding {
    var isInternal: Bool {
        switch action {
        case .openSettings, .captureMainDisplay, .captureInteractive,
             .screenshotHistory, .openCollage, .scrollCapture, .clipboardHistory:
            true
        case .application:
            false
        }
    }
}


struct ThinScrollIndicatorInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollProbe { ScrollProbe() }
    func updateNSView(_ view: ScrollProbe, context: Context) {}

    final class ScrollProbe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let scroll = self?.enclosingScrollView,
                      scroll.hasVerticalScroller,
                      !(scroll.verticalScroller is ThinScroller) else { return }
                scroll.verticalScroller = ThinScroller()
            }
        }
    }

    private final class ThinScroller: NSScroller {
        override class var isCompatibleWithOverlayScrollers: Bool { true }

        override func drawKnob() {
            let knob = rect(for: .knob)
            let width: CGFloat = 4
            let shape = CGRect(x: knob.maxX - width - 1, y: knob.minY + 1,
                               width: width, height: max(0, knob.height - 2))
            NSColor.labelColor.withAlphaComponent(0.40).setFill()
            NSBezierPath(roundedRect: shape, xRadius: width / 2, yRadius: width / 2).fill()
        }

        override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    }
}

private extension ShortcutAction {
    var iconName: String {
        switch self {
        case .openSettings:
            "gearshape"
        case .captureMainDisplay, .captureInteractive:
            "viewfinder"
        case .screenshotHistory:
            "photo.on.rectangle.angled"
        case .openCollage:
            "rectangle.3.group"
        case .scrollCapture:
            "rectangle.portrait.and.arrow.forward"
        case .clipboardHistory:
            "doc.on.clipboard"
        case .application:
            "macwindow"
        }
    }
}

struct SettingsTheme {
    let page: Color
    let sidebar: Color
    let card: Color
    let border: Color
    let selected: Color
    let selectedBorder: Color
    let success: Color
    let warning: Color
    let danger: Color

    init(colorScheme: ColorScheme) {
        switch colorScheme {
        case .dark:
            page = Color(red: 0.10, green: 0.11, blue: 0.08)
            sidebar = Color(red: 0.12, green: 0.14, blue: 0.10)
            card = Color(red: 0.16, green: 0.18, blue: 0.13)
            border = Color(red: 0.96, green: 0.94, blue: 0.90).opacity(0.08)
            selected = Color(red: 0.96, green: 0.94, blue: 0.90).opacity(0.09)
            selectedBorder = NylaiPalette.accent.opacity(0.38)
            success = Color(red: 0.67, green: 0.78, blue: 0.55)
            warning = Color(red: 0.82, green: 0.57, blue: 0.22)
            danger = Color(red: 0.95, green: 0.52, blue: 0.48)
        default:
            page = Color(red: 0.985, green: 0.98, blue: 0.965)
            sidebar = Color(red: 0.95, green: 0.945, blue: 0.925)
            card = Color(red: 0.995, green: 0.992, blue: 0.982)
            border = Color(nsColor: NylaiPalette.olive).opacity(0.08)
            selected = .white.opacity(0.92)
            selectedBorder = NylaiPalette.accent.opacity(0.24)
            success = Color(nsColor: NylaiPalette.olive)
            warning = Color(red: 0.66, green: 0.39, blue: 0.12)
            danger = Color(red: 0.72, green: 0.17, blue: 0.16)
        }
    }
}
