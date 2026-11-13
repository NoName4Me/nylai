import AppKit
import SwiftUI
import XCTest
@testable import nylai

final class SystemMonitorTests: XCTestCase {
    @MainActor
    func testCPUUsageUsesIntervalAndHandlesCounterWrap() throws {
        XCTAssertEqual(try XCTUnwrap(SystemMonitorModel.cpuUsage(
            previous: [100, 100, 100, 0], current: [120, 110, 170, 0]
        )), 0.3, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(SystemMonitorModel.cpuUsage(
            previous: [.max - 4, 0, 20, 0], current: [5, 0, 30, 0]
        )), 0.5, accuracy: 0.001)
        XCTAssertNil(SystemMonitorModel.cpuUsage(previous: nil, current: [1, 2, 3, 4]))
    }

    @MainActor
    func testNetworkRatesUseElapsedTimeAndIgnoreCounterResets() {
        let model = SystemMonitorModel()
        model.receive(snapshot(uptime: 10, received: 1000, sent: 1000), includeVolumes: true)
        XCTAssertNil(model.download)
        model.receive(snapshot(uptime: 12, received: 3000, sent: 2000), includeVolumes: false)
        XCTAssertEqual(model.download, 1000)
        XCTAssertEqual(model.upload, 500)
        model.receive(snapshot(uptime: 14, received: 20, sent: 10), includeVolumes: false)
        XCTAssertEqual(model.download, 0)
        XCTAssertEqual(model.upload, 0)
    }

    @MainActor
    func testMonitorPreferenceDefaultsOffAndPersists() throws {
        let suite = "SystemMonitorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.systemMonitorEnabled)
        preferences.systemMonitorEnabled = true
        XCTAssertTrue(AppPreferences(defaults: defaults).systemMonitorEnabled)
        preferences.systemMonitorEnabled = false
        XCTAssertFalse(AppPreferences(defaults: defaults).systemMonitorEnabled)
        preferences.systemMonitorMetrics = [.cpu, .network]
        preferences.systemMonitorMenuBarMetrics = [.network]
        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.systemMonitorMetrics, [.cpu, .network])
        XCTAssertEqual(restored.systemMonitorMenuBarMetrics, [.network])
    }

    func testDisabledMetricsAreNotSampled() async {
        let snapshot = await SystemMonitorSampler().sample(includeVolumes: true, metrics: [.storage])
        XCTAssertNil(snapshot.cpuTicks)
        XCTAssertNil(snapshot.memoryUsed)
        XCTAssertNil(snapshot.swapUsed)
        XCTAssertTrue(snapshot.networks.isEmpty)
        XCTAssertFalse(snapshot.volumes.isEmpty)
    }

    func testSamplerReadsLiveSystemWithoutExtraPermissions() async throws {
        let snapshot = await SystemMonitorSampler().sample(includeVolumes: true)
        XCTAssertEqual(snapshot.cpuTicks?.count, 4)
        XCTAssertGreaterThan(try XCTUnwrap(snapshot.memoryUsed), 0)
        XCTAssertFalse(snapshot.volumes.isEmpty)
        for volume in snapshot.volumes {
            XCTAssertGreaterThan(volume.total, 0)
            XCTAssertGreaterThanOrEqual(volume.available, 0)
        }
    }

    @MainActor
    func testMonitorSettingsRender() throws {
        let suite = "SystemMonitorSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let host = NSHostingView(rootView: SystemMonitorSettingsView(preferences: preferences)
            .padding(20).background(Color.white).environment(\.colorScheme, .light))
        host.frame = CGRect(x: 0, y: 0, width: 507, height: 360)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let attachment = XCTAttachment(image: NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: host.bounds.size))
        attachment.name = "Monitor Settings"
        attachment.lifetime = .keepAlways
        add(attachment)
        window.orderOut(nil)
    }

    @MainActor
    func testMonitorTabsRender() async throws {
        let model = SystemMonitorModel()
        model.receive(await SystemMonitorSampler().sample(includeVolumes: true), includeVolumes: true)
        model.receive(await SystemMonitorSampler().sample(includeVolumes: false), includeVolumes: false)
        for tab in 0..<4 {
            let host = NSHostingView(rootView: SystemMonitorView(
                model: model, openSettings: {}, quit: {}, selectedTab: tab
            ).environment(\.locale, Locale(identifier: "zh-Hans")).environment(\.colorScheme, .light))
            host.frame = CGRect(x: 0, y: 0, width: 360, height: 420)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let attachment = XCTAttachment(image: NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: host.bounds.size))
            attachment.name = "System Monitor Tab \(tab)"
            attachment.lifetime = .keepAlways
            add(attachment)
            window.orderOut(nil)
        }
    }

    private func snapshot(uptime: Double, received: UInt64, sent: UInt64) -> SystemMonitorSnapshot {
        .init(uptime: uptime, cpuTicks: [10, 10, 80, 0], memoryUsed: nil,
              memoryWired: nil, memoryCompressed: nil, swapUsed: nil,
              networks: [.init(name: "en0", received: received, sent: sent, address: nil)], volumes: [])
    }
}
