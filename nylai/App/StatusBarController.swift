import AppKit
import SwiftUI

@MainActor
private final class MonitorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let preferences: AppPreferences
    private let monitor = SystemMonitorModel()
    private let panel = MonitorPanel(
        contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
    )
    private let openSettings: () -> Void
    private let isInteractionLocked: () -> Bool
    private var localMonitor: Any?
    private var globalMonitor: Any?

    init(
        preferences: AppPreferences,
        openSettings: @escaping () -> Void,
        isInteractionLocked: @escaping () -> Bool
    ) {
        self.preferences = preferences
        self.openSettings = openSettings
        self.isInteractionLocked = isInteractionLocked
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let button = statusItem.button {
            let image = NSImage(named: NSImage.Name("MenuBarIcon"))
            image?.size = NSSize(width: 18, height: 18)
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        monitor.onUpdate = { [weak self] in self?.updateReadouts() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(configurationChanged),
            name: .systemMonitorConfigurationDidChange, object: nil
        )
        refreshLocalization()
    }

    func refreshLocalization() {
        statusItem.button?.toolTip = AppName.current
        statusItem.button?.setAccessibilityLabel(AppName.current)
        rebuildContent()
        refreshSampling()
    }

    private func rebuildContent() {
        panel.contentView = NSHostingView(rootView: SystemMonitorView(
            model: monitor,
            openSettings: { [weak self] in
                self?.closeMonitor()
                self?.openSettings()
            },
            quit: { NSApp.terminate(nil) },
            metrics: preferences.systemMonitorMetrics
        ).nylaiLocalized().clipShape(RoundedRectangle(cornerRadius: 14)))
    }

    @objc private func configurationChanged() {
        if !preferences.systemMonitorEnabled { closeMonitor() }
        rebuildContent()
        refreshSampling()
    }

    private func refreshSampling() {
        let menuMetrics = preferences.systemMonitorMenuBarMetrics.intersection(preferences.systemMonitorMetrics)
        let metrics = panel.isVisible ? preferences.systemMonitorMetrics : menuMetrics
        if preferences.systemMonitorEnabled && !metrics.isEmpty {
            monitor.start(metrics: metrics)
        } else {
            monitor.stop()
        }
        updateReadouts()
    }

    private func updateReadouts() {
        let enabled = preferences.systemMonitorEnabled
            ? preferences.systemMonitorMenuBarMetrics.intersection(preferences.systemMonitorMetrics) : []
        let text = SystemMonitorMetric.allCases.filter { enabled.contains($0) }.map { metric in
            switch metric {
            case .cpu:
                return "CPU " + (monitor.cpuUsage.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—")
            case .memory:
                let value = monitor.snapshot?.memoryUsed.map {
                    (Double($0) / Double(ProcessInfo.processInfo.physicalMemory)).formatted(.percent.precision(.fractionLength(0)))
                } ?? "—"
                return L10n.shared.string("内存") + " " + value
            case .network:
                return "↓" + Self.rate(monitor.download) + " ↑" + Self.rate(monitor.upload)
            case .storage:
                let value = monitor.volumes.first.map {
                    ByteCountFormatter.string(fromByteCount: $0.available, countStyle: .decimal)
                } ?? "—"
                return L10n.shared.string("可用") + " " + value
            }
        }.joined(separator: "   ")
        statusItem.button?.title = text.isEmpty ? "" : " " + text
        statusItem.button?.setAccessibilityValue(text)
    }

    private static func rate(_ value: Double?) -> String {
        guard let value else { return "—" }
        let formatted = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: UInt64(max(0, value))), countStyle: .binary
        )
        return formatted.replacingOccurrences(of: " ", with: "") + "/s"
    }

    func closeMonitor() {
        panel.orderOut(nil)
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        refreshSampling()
    }

    func shutdown() {
        closeMonitor()
        monitor.stop()
        NotificationCenter.default.removeObserver(self)
    }

    private func showMonitor(relativeTo button: NSStatusBarButton) {
        guard let window = button.window, let screen = window.screen else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let width: CGFloat = min(360, visible.width)
        let height: CGFloat = min(420, visible.height)
        panel.setFrame(CGRect(
            x: min(max(anchor.midX - width / 2, visible.minX), visible.maxX - width),
            y: max(visible.minY, min(anchor.minY - height - 8, visible.maxY - height)),
            width: width, height: height
        ), display: true)
        panel.orderFrontRegardless()
        refreshSampling()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closeMonitor() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.type == .keyDown {
                    if event.keyCode == 53 { self.closeMonitor(); return true }
                } else if event.window !== self.panel && event.window !== self.statusItem.button?.window {
                    self.closeMonitor()
                }
                return false
            }
            return consumed ? nil : event
        }
    }

    @objc private func clicked() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp,
           let button = statusItem.button {
            closeMonitor()
            let menu = NSMenu()
            menu.addItem(
                withTitle: L10n.shared.string("退出 %@", AppName.current),
                action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""
            )
            NSMenu.popUpContextMenu(menu, with: event, for: button)
            return
        }
        guard !isInteractionLocked() else { return }
        guard preferences.systemMonitorEnabled, let button = statusItem.button else {
            openSettings()
            return
        }
        if panel.isVisible { closeMonitor() } else { showMonitor(relativeTo: button) }
    }
}
