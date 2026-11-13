import SwiftUI

struct SystemMonitorSettingsView: View {
    @Bindable var preferences: AppPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("监控项目").font(.headline)
                Spacer()
                Text("菜单栏显示").font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(SystemMonitorMetric.allCases, id: \.self) { metric in
                    HStack(spacing: 18) {
                        Toggle(metric.title, isOn: Binding(
                            get: { preferences.systemMonitorMetrics.contains(metric) },
                            set: { enabled in
                                if enabled { preferences.systemMonitorMetrics.insert(metric) }
                                else {
                                    preferences.systemMonitorMenuBarMetrics.remove(metric)
                                    preferences.systemMonitorMetrics.remove(metric)
                                }
                            }
                        ))
                        .disabled(preferences.systemMonitorMetrics == [metric])
                        .toggleStyle(.checkbox)
                        Spacer()
                        Toggle("菜单栏显示", isOn: Binding(
                            get: { preferences.systemMonitorMenuBarMetrics.contains(metric) },
                            set: { enabled in
                                if enabled { preferences.systemMonitorMenuBarMetrics.insert(metric) }
                                else { preferences.systemMonitorMenuBarMetrics.remove(metric) }
                            }
                        ))
                        .labelsHidden()
                        .accessibilityLabel(metric.title + " " + L10n.shared.string("菜单栏显示"))
                        .disabled(!preferences.systemMonitorMetrics.contains(metric))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    }
                    .padding(14)
                    if metric != .storage { Divider() }
                }
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            Text("菜单栏显示的项目会持续更新，其余项目仅在浮层打开时更新。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
