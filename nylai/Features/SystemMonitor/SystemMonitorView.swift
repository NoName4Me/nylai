import AppKit
import SwiftUI
import Observation

@MainActor
@Observable
final class SystemMonitorModel {
    var snapshot: SystemMonitorSnapshot?
    var cpuUsage: Double?
    var download: Double?
    var upload: Double?
    var cpuHistory: [Double] = []
    var memoryHistory: [Double] = []
    var downloadHistory: [Double] = []
    var uploadHistory: [Double] = []
    var volumes: [SystemMonitorSnapshot.Volume] = []
    var actionError: String?
    var metrics = Set(SystemMonitorMetric.allCases)
    var onUpdate: (() -> Void)?
    private let sampler = SystemMonitorSampler()
    private var samplingTask: Task<Void, Never>?

    func start(metrics: Set<SystemMonitorMetric> = Set(SystemMonitorMetric.allCases)) {
        if samplingTask != nil, self.metrics == metrics { return }
        stop()
        self.metrics = metrics
        snapshot = nil
        cpuUsage = nil
        download = nil
        upload = nil
        cpuHistory = []
        memoryHistory = []
        downloadHistory = []
        uploadHistory = []
        actionError = nil
        samplingTask = Task { [weak self] in
            var sampleIndex = 0
            while !Task.isCancelled {
                guard let sampler = self?.sampler else { return }
                let current = await sampler.sample(includeVolumes: sampleIndex % 10 == 0, metrics: metrics)
                guard !Task.isCancelled else { return }
                self?.receive(current, includeVolumes: sampleIndex % 10 == 0)
                sampleIndex += 1
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func stop() {
        samplingTask?.cancel()
        samplingTask = nil
    }

    func receive(_ current: SystemMonitorSnapshot, includeVolumes: Bool) {
        if let previous = snapshot {
            cpuUsage = Self.cpuUsage(previous: previous.cpuTicks, current: current.cpuTicks)
            let elapsed = current.uptime - previous.uptime
            if elapsed > 0 {
                var received: UInt64 = 0
                var sent: UInt64 = 0
                for interface in current.networks {
                    guard let old = previous.networks.first(where: { $0.name == interface.name }) else { continue }
                    received += interface.received >= old.received ? interface.received - old.received : 0
                    sent += interface.sent >= old.sent ? interface.sent - old.sent : 0
                }
                download = Double(received) / elapsed
                upload = Double(sent) / elapsed
            }
        }
        snapshot = current
        if includeVolumes { volumes = current.volumes }
        if let cpuUsage { append(cpuUsage, to: &cpuHistory) }
        if let used = current.memoryUsed {
            append(Double(used) / Double(ProcessInfo.processInfo.physicalMemory), to: &memoryHistory)
        }
        if let download { append(download, to: &downloadHistory) }
        if let upload { append(upload, to: &uploadHistory) }
        onUpdate?()
    }

    static func cpuUsage(previous: [UInt32]?, current: [UInt32]?) -> Double? {
        guard let previous, let current, previous.count == 4, current.count == 4 else { return nil }
        let delta = zip(current, previous).map { UInt64($0 &- $1) }
        let total = delta.reduce(0, +)
        guard total > 0 else { return 0 }
        return Double(total - delta[2]) / Double(total)
    }

    private func append(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > 60 { history.removeFirst(history.count - 60) }
    }

    func openApplication(_ identifier: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
            actionError = L10n.shared.string("无法打开系统工具。")
            return
        }
        Task {
            do {
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    func openSettings(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:" + anchor),
              NSWorkspace.shared.open(url) else {
            openApplication("com.apple.systempreferences")
            return
        }
    }
}

struct SystemMonitorView: View {
    @Bindable var model: SystemMonitorModel
    let openSettings: () -> Void
    let quit: () -> Void
    @State var selectedTab = 0
    var metrics = Set(SystemMonitorMetric.allCases)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("系统监控").font(.headline)
                Spacer()
                Button(action: openSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(.plain)
                    .help("设置")
                    .accessibilityLabel("设置")
            }
            Picker("监控项目", selection: $selectedTab) {
                ForEach(Array(SystemMonitorMetric.allCases.enumerated()), id: \.element) { index, metric in
                    if metrics.contains(metric) { Text(metric.title).tag(index) }
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch selectedTab {
                    case 0: cpu
                    case 1: memory
                    case 2: network
                    default: storage
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 268)
            Divider()
            HStack {
                Button("活动监视器") { model.openApplication("com.apple.ActivityMonitor") }
                    .buttonStyle(.link)
                Spacer()
                Button("退出", action: quit).buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .padding(18)
        .frame(width: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(NylaiPalette.accent)
        .onAppear { selectAvailableTab() }
        .onChange(of: metrics) { selectAvailableTab() }
        .alert("无法打开系统工具。", isPresented: Binding(
            get: { model.actionError != nil },
            set: { if !$0 { model.actionError = nil } }
        )) {
            Button("好") { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
    }

    private func selectAvailableTab() {
        if !metrics.contains(SystemMonitorMetric.allCases[selectedTab]) {
            selectedTab = SystemMonitorMetric.allCases.firstIndex(where: { metrics.contains($0) }) ?? 0
        }
    }

    private var cpu: some View {
        VStack(alignment: .leading, spacing: 14) {
            headline(percent(model.cpuUsage), label: "CPU 使用率")
            trend(model.cpuHistory, maximum: 1)
            row("逻辑核心", value: "\(ProcessInfo.processInfo.activeProcessorCount)")
            row("运行时间", value: model.snapshot.map { Duration.seconds($0.uptime).formatted(.units(
                allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2
            )) } ?? "—")
            row("温控状态", value: thermalState)
        }
    }

    private var memory: some View {
        VStack(alignment: .leading, spacing: 14) {
            headline(bytes(model.snapshot?.memoryUsed), label: "已用内存")
            trend(model.memoryHistory, maximum: 1)
            row("物理内存", value: bytes(ProcessInfo.processInfo.physicalMemory))
            row("联动内存", value: bytes(model.snapshot?.memoryWired))
            row("压缩内存", value: bytes(model.snapshot?.memoryCompressed))
            row("已用交换空间", value: bytes(model.snapshot?.swapUsed))
        }
    }

    private var network: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                headline(rate(model.download), label: "下载").foregroundStyle(NylaiPalette.accent)
                Spacer()
                headline(rate(model.upload), label: "上传").foregroundStyle(.orange)
            }
            trend(model.downloadHistory, secondary: model.uploadHistory,
                  maximum: max(1024, (model.downloadHistory + model.uploadHistory).max() ?? 1024))
            ForEach(model.snapshot?.networks ?? [], id: \.name) { interface in
                row(interface.name, value: interface.address ?? "—", localized: false)
            }
            Button("网络设置") { model.openSettings("com.apple.Network-Settings.extension") }
                .buttonStyle(.link)
        }
    }

    private var storage: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.volumes.isEmpty {
                Text("无法读取磁盘容量。").foregroundStyle(.secondary)
            }
            ForEach(model.volumes) { volume in
                VStack(alignment: .leading, spacing: 8) {
                    Text(volume.name).font(.callout.weight(.medium)).lineLimit(1)
                    ProgressView(value: Double(max(0, volume.total - volume.available)), total: Double(volume.total))
                    row("可用", value: bytes(UInt64(max(0, volume.available))))
                    row("总容量", value: bytes(UInt64(volume.total)))
                }
            }
            HStack {
                Button("系统存储") {
                    model.openSettings("com.apple.settings.Storage")
                }
                Spacer()
                Button("磁盘工具") { model.openApplication("com.apple.DiskUtility") }
            }
            .buttonStyle(.link)
        }
    }

    private func headline(_ value: String, label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 27, weight: .medium)).monospacedDigit()
        }
    }

    private func row(_ label: String, value: String, localized: Bool = true) -> some View {
        HStack {
            Text(localized ? L10n.shared.string(label) : label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
        .font(.callout)
    }

    private func trend(_ values: [Double], secondary: [Double] = [], maximum: Double) -> some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(0..<3) { index in
                    Path { path in
                        let height = CGFloat(index) * geometry.size.height / 2
                        path.move(to: CGPoint(x: 0, y: height))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: height))
                    }.stroke(.secondary.opacity(0.15), lineWidth: 0.5)
                }
                curve(values, size: geometry.size, maximum: maximum).stroke(NylaiPalette.accent, lineWidth: 2)
                curve(secondary, size: geometry.size, maximum: maximum).stroke(.orange, lineWidth: 1.5)
            }
        }
        .frame(height: 64)
        .accessibilityHidden(true)
    }

    private func curve(_ values: [Double], size: CGSize, maximum: Double) -> Path {
        Path { path in
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: size.width * CGFloat(index) / 59,
                                    y: size.height * (1 - min(1, max(0, value / maximum))))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }

    private func bytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    private func rate(_ value: Double?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: UInt64(max(0, value))), countStyle: .binary) + "/s"
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.percent.precision(.fractionLength(0)))
    }

    private var thermalState: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: L10n.shared.string("正常")
        case .fair: L10n.shared.string("偏热")
        case .serious: L10n.shared.string("较热")
        case .critical: L10n.shared.string("过热")
        @unknown default: "—"
        }
    }
}
