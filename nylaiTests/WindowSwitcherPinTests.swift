import AppKit
import SwiftUI
import XCTest
@testable import nylai

@MainActor
final class WindowSwitcherPinTests: XCTestCase {
    func testPinnedApplicationKeepsOtherRunningInstancesReachable() throws {
        let suite = "nylai-fixed-apps-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pins = WindowSwitcherPinnedApplications(defaults: defaults)
        let first = application(2)
        let second = WindowSwitcherApplication(id: 22, bundleIdentifier: first.bundleIdentifier,
                                              name: first.name, windows: [WindowSwitcherWindow(id: 221, title: "Second Instance", frame: .zero)])
        try pins.toggle(first)
        let result = pins.applying(to: WindowSwitcherSnapshot(applications: [second, first, application(1)], currentApplicationID: 22))
        XCTAssertEqual(result.applications.map(\.id), [22, 2, 1])
        XCTAssertEqual(result.applications[0].windows.first?.id, 221)
        XCTAssertEqual(result.applications[1].id, first.id)
    }

    func testOfflinePinnedApplicationRendersLaunchEntry() throws {
        let model = WindowSwitcherPanelModel()
        let url = try XCTUnwrap(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit"))
        model.applications = [WindowSwitcherApplication(id: -1, bundleIdentifier: "com.apple.TextEdit", name: "文本编辑",
                                                        windows: [], applicationURL: url, pinnedOrder: 0), application(1)]
        let host = NSHostingView(rootView: WindowSwitcherPanelView(model: model).nylaiLocalized())
        host.frame = CGRect(x: 0, y: 0, width: 1280, height: 740)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/tmp/nylai-fixed-apps-preview.png"))
        let attachment = XCTAttachment(image: NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: host.bounds.size))
        attachment.name = "Inactive Pinned Application"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testFixedOrderSurvivesMRUChangesAndReload() throws {
        let suite = "nylai-fixed-apps-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pins = WindowSwitcherPinnedApplications(defaults: defaults)
        let apps = [application(1), application(2), application(3)]
        try pins.toggle(apps[1])
        try pins.toggle(apps[2])
        let first = pins.applying(to: WindowSwitcherSnapshot(applications: apps, currentApplicationID: 1))
        let reordered = WindowSwitcherSnapshot(applications: [apps[2], apps[0], apps[1]], currentApplicationID: 3)
        let reloaded = WindowSwitcherPinnedApplications(defaults: defaults).applying(to: reordered)
        XCTAssertEqual(first.applications.map(\.id), [2, 3, 1])
        XCTAssertEqual(reloaded.applications.map(\.id), [2, 3, 1])
        XCTAssertEqual(reloaded.currentApplicationID, 3)
        try pins.move("com.example.3", offset: -1)
        XCTAssertEqual(pins.applying(to: reordered).applications.map(\.id), [3, 2, 1])
    }

    func testExitedPinRemainsLaunchableAndUnpinRemovesPlaceholder() throws {
        let suite = "nylai-fixed-apps-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pins = WindowSwitcherPinnedApplications(defaults: defaults)
        try pins.toggle(application(2))
        let snapshot = pins.applying(to: WindowSwitcherSnapshot(applications: [application(1)], currentApplicationID: 1))
        XCTAssertEqual(snapshot.applications.count, 2)
        let offline = snapshot.applications[0]
        XCTAssertTrue(offline.isPinned)
        XCTAssertFalse(offline.isRunning)
        var session = try WindowSwitcherSession(snapshot: snapshot, mode: .applications, reverse: false)
        session.apply(.selectApplication(0))
        XCTAssertTrue(session.confirmationTarget.launchIfNeeded)
        XCTAssertEqual(session.confirmationTarget.applicationURL, application(2).applicationURL)
        XCTAssertNil(session.confirmationTarget.windowID)
        try pins.toggle(offline)
        XCTAssertEqual(pins.applying(to: snapshot).applications.map(\.id), [1])
    }

    func testReorderingInactivePinsProducesDistinctTargets() throws {
        let suite = "nylai-fixed-apps-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pins = WindowSwitcherPinnedApplications(defaults: defaults)
        try pins.toggle(application(2))
        try pins.toggle(application(3))
        let snapshot = pins.applying(to: WindowSwitcherSnapshot(applications: [application(1)], currentApplicationID: 1))
        try pins.move("com.example.3", offset: -1)
        let updated = pins.applying(to: snapshot)
        XCTAssertEqual(updated.applications.map(\.bundleIdentifier), ["com.example.3", "com.example.2", "com.example.1"])
        XCTAssertEqual(Set(updated.applications.map(\.id)).count, 3)
    }

    func testInactiveFixedTargetLaunchesSavedApplicationAndValidatesIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("Pinned.app")
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let info = ["CFBundleIdentifier": "com.example.pinned", "CFBundleName": "Pinned", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        var launched: [URL] = []
        let activator = WindowSwitcherActivator(isAccessibilityGranted: { false }, openApplication: { launched.append($0) })
        var target = WindowSwitcherTarget(processIdentifier: -1, bundleIdentifier: "com.example.pinned", applicationName: "Pinned",
                                          windowID: nil, windowTitle: nil, windowFrame: nil, applicationURL: url, launchIfNeeded: true)
        try await activator.activate(target)
        XCTAssertEqual(launched, [url])
        target.launchIfNeeded = false
        do { try await activator.activate(target); XCTFail("An unpinned expired target must not launch") }
        catch { XCTAssertEqual(error as? WindowSwitcherError, .targetUnavailable) }
        let wrongIdentity = WindowSwitcherTarget(processIdentifier: -1, bundleIdentifier: "com.example.other", applicationName: "Other",
                                                 windowID: nil, windowTitle: nil, windowFrame: nil, applicationURL: url, launchIfNeeded: true)
        do { try await activator.activate(wrongIdentity); XCTFail("Must not launch a different application at the saved path") }
        catch { XCTAssertEqual(error as? WindowSwitcherError, .targetUnavailable) }
        XCTAssertEqual(launched, [url])
    }

    private func application(_ id: pid_t) -> WindowSwitcherApplication {
        WindowSwitcherApplication(id: id, bundleIdentifier: "com.example.\(id)", name: "App \(id)", windows: [],
                                  applicationURL: URL(fileURLWithPath: "/Applications/App\(id).app"))
    }
}
