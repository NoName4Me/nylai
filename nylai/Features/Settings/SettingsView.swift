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
    @State private var isNewGestureRule = false
    @State private var gestureErrorMessage: String?
    @State private var clipboardLimitDraft = ""
    @State private var clipboardRetentionDaysDraft = ""
    @State private var clipboardErrorMessage: String?
    @State private var confirmsClearClipboard = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                pageHeader
                Divider().opacity(0.6)
                ScrollView {
                    pageContent
                        .padding(.horizontal, 28)
                        .padding(.top, 20)
                        .padding(.bottom, 28)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.page)
        }
        .frame(width: 760, height: 580)
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
        .sheet(item: $editingGestureRule) { rule in
            GestureRuleEditorView(
                rule: rule,
                isNew: isNewGestureRule,
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
                if isNewGestureRule {
                    try mouseGestureController.addRule(updated)
                } else {
                    try mouseGestureController.updateRule(updated)
                }
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 30, height: 30)
                    .overlay {
                        Image(systemName: "command")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }

                VStack(alignment: .leading, spacing: 1) {
                    Text("nylai")
                        .font(.system(size: 14, weight: .semibold))
                    Text("快捷启动与截图")
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
                ForEach(SettingsSection.allCases, id: \.self) { section in
                    SidebarItem(
                        section: section,
                        isSelected: selectedSection == section
                    ) {
                        selectedSection = section
                    }
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 20)
        }
        .frame(width: 196)
        .background(theme.sidebar)
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
                            $0.isInternal && $0.action != .scrollCapture
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
                    sectionTitle("应用")
                    Spacer()
                    Button {
                        chooseApplication()
                    } label: {
                        Label("添加应用", systemImage: "plus")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
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
                ActionIcon(symbol: module.symbolName)
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
                    .toggleStyle(.switch)
                    .controlSize(.small)
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
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    .padding(14)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    sectionTitle("手势规则")
                    Spacer()
                    Button {
                        isNewGestureRule = true
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
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
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
                Text(rule.path.display)
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .frame(width: 92, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(rule.action.title)
                        .font(.system(size: 13, weight: .medium))
                    Text(rule.scopeBundleIdentifier == nil
                        ? "所有应用"
                        : applicationName(rule.scopeBundleIdentifier))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("编辑") {
                    isNewGestureRule = false
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
                sectionTitle("截图")
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
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .accessibilityLabel("记录最近截图")
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
                            Text("启动 nylai 后自动打开此窗口。")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 12)

                        Toggle("", isOn: $preferences.showSettingsOnLaunch)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .accessibilityLabel("打开应用时显示设置")
                    }
                    .padding(14)
                }
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
                                Text("用于截取屏幕内容。修改授权后可能需要重新启动 nylai。")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 12)

                            Button("打开系统设置…") {
                                missingSettingsPage = "屏幕录制"
                                showSettingsError = !ScreenRecordingPermission.openSystemSettings()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
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
                            .foregroundStyle(Color.accentColor)
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
                        isGranted: accessibilityGranted
                    ) {
                        missingSettingsPage = "辅助功能"
                        showSettingsError = !AccessibilityPermission.openSystemSettings()
                    }
                    Divider().padding(.leading, 54)
                    permissionRow(
                        title: "输入监控",
                        icon: "keyboard",
                        description: "用于接管 Command-Tab 和 Command-反引号键。",
                        isGranted: inputMonitoringGranted
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
            Button("打开系统设置…", action: openSettings)
                .buttonStyle(.bordered)
                .controlSize(.small)
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
                    .toggleStyle(.switch)
                    .controlSize(.small)
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

                    statusLine(status, id: binding.id)

                    if let target, !FileManager.default.fileExists(atPath: target.path) {
                        HStack(spacing: 6) {
                            Text(ApplicationLaunchError.missingApplication.localizedDescription)
                                .foregroundStyle(theme.danger)
                            Button("重新定位…") { relocateApplication(binding.id) }
                                .buttonStyle(.borderless)
                                .foregroundStyle(Color.accentColor)
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
                    .toggleStyle(.switch)
                    .controlSize(.small)
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
            .padding(.top, 11)
            .padding(.bottom, 8)

            if let target {
                HStack {
                    Toggle("再次触发时隐藏", isOn: hidesOnRepeatBinding(binding.id, fallback: target.hidesOnRepeatTrigger))
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.leading, 54)
                .padding(.trailing, 82)
                .padding(.bottom, 10)
            }

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

    private func statusLine(_ status: ShortcutBindingStatus, id: ShortcutBindingID) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor(status))
                .frame(width: 5, height: 5)

            Text(status.title)
                .foregroundStyle(statusColor(status))

            if case .failed(let reason) = status {
                Text(reason)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(reason)

                Button("重试") {
                    shortcutRuntime.retry(id)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
            }
        }
        .font(.system(size: 11))
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
                    try moduleStateController.setEnabled(value, for: module)
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
        do {
            _ = try shortcutRuntime.addApplicationBinding(
                bundleIdentifier: bundleIdentifier,
                path: url.path(percentEncoded: false)
            )
        } catch {
            handle(error)
        }
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

    private func statusColor(_ status: ShortcutBindingStatus) -> Color {
        switch status {
        case .registered:
            theme.success
        case .failed:
            theme.danger
        case .recording:
            Color.accentColor
        case .unbound, .disabled, .globallyDisabled, .targetModuleDisabled, .paused:
            .secondary
        }
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
}

private enum SettingsSection: CaseIterable {
    case modules
    case shortcuts
    case gestures
    case clipboard
    case general
    case permissions

    var title: String {
        switch self {
        case .modules:
            "功能"
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
            "启用或停用 nylai 的功能模块。"
        case .shortcuts:
            "为截图等内置功能或常用应用分配快捷键。"
        case .gestures:
            "按住右键绘制路径，松开后执行绑定动作。"
        case .clipboard:
            "管理剪贴板历史、来源屏蔽和保留期限。"
        case .general:
            "控制 nylai 启动时的行为。"
        case .permissions:
            "查看屏幕录制、辅助功能和输入监控的授权状态。"
        }
    }

    var symbol: String {
        switch self {
        case .modules:
            "square.grid.2x2"
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

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)

                Text(section.title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(Color.primary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundColor)
                    .shadow(color: isSelected ? Color.black.opacity(0.08) : .clear, radius: 1.5, y: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? theme.selectedBorder : .clear, lineWidth: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

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

private struct SettingsCard<Content: View>: View {
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

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.primary.opacity(0.06))
            .frame(width: 28, height: 28)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
    }
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

private struct SettingsTheme {
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
            page = Color(red: 0.105, green: 0.105, blue: 0.118)
            sidebar = Color(red: 0.125, green: 0.125, blue: 0.141)
            card = Color(red: 0.149, green: 0.149, blue: 0.165)
            border = Color.white.opacity(0.07)
            selected = Color.white.opacity(0.10)
            selectedBorder = Color.white.opacity(0.08)
            success = Color(red: 0.435, green: 0.851, blue: 0.608)
            warning = Color(red: 0.949, green: 0.71, blue: 0.267)
            danger = Color(red: 0.949, green: 0.545, blue: 0.51)
        default:
            page = .white
            sidebar = Color(red: 0.949, green: 0.949, blue: 0.961)
            card = Color(red: 0.969, green: 0.969, blue: 0.98)
            border = Color.black.opacity(0.055)
            selected = .white
            selectedBorder = Color.black.opacity(0.06)
            success = Color(red: 0.082, green: 0.541, blue: 0.294)
            warning = Color(red: 0.706, green: 0.325, blue: 0.035)
            danger = Color(red: 0.78, green: 0.16, blue: 0.18)
        }
    }
}
