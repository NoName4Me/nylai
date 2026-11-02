import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: AppPreferences
    var settingsShortcut: GlobalShortcutController
    var screenshotShortcut: GlobalShortcutController
    @State private var screenRecordingGranted = false
    @State private var showSettingsError = false

    var body: some View {
        Form {
            Section("通用") {
                Toggle("打开应用时显示设置", isOn: $preferences.showSettingsOnLaunch)
            }

            Section("全局快捷键") {
                shortcutRow("打开设置", keys: "⌃⌥N", accessibilityLabel: "Control Option N", controller: settingsShortcut)
                shortcutRow("截取主显示器", keys: "⌃⌥S", accessibilityLabel: "Control Option S", controller: screenshotShortcut)
            }

            Section("系统权限") {
                LabeledContent("屏幕录制", value: screenRecordingGranted ? "已授权" : "未授权")
                HStack {
                    Button("打开系统设置…") {
                        showSettingsError = !ScreenRecordingPermission.openSystemSettings()
                    }
                    Spacer()
                    Button("刷新状态") {
                        refreshPermission()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 440)
        .onAppear(perform: refreshPermission)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermission()
        }
        .alert("无法打开系统设置", isPresented: $showSettingsError) {
            Button("好", role: .cancel) {}
        } message: {
            Text("请前往系统设置 → 隐私与安全性 → 屏幕录制。")
        }
    }

    @ViewBuilder
    private func shortcutRow(_ title: String, keys: String, accessibilityLabel: String, controller: GlobalShortcutController) -> some View {
        LabeledContent(title) {
            Text(keys).accessibilityLabel(accessibilityLabel)
        }
        if case .failed(let message) = controller.status {
            Text(message)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            Button("重试注册") { controller.start() }
        }
    }

    private func refreshPermission() {
        screenRecordingGranted = ScreenRecordingPermission.isGranted
    }
}
