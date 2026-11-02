import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: AppPreferences
    @State private var screenRecordingGranted = false
    @State private var showSettingsError = false

    var body: some View {
        Form {
            Section("通用") {
                Toggle("打开应用时显示设置", isOn: $preferences.showSettingsOnLaunch)
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
        .frame(width: 480, height: 300)
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

    private func refreshPermission() {
        screenRecordingGranted = ScreenRecordingPermission.isGranted
    }
}
