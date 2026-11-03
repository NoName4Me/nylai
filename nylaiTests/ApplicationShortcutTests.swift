import AppKit
import XCTest
@testable import nylai

final class ApplicationShortcutTests: XCTestCase {
    @MainActor
    func testNotRunningLaunchesAndActivates() async throws {
        let fixture = try ApplicationFixture()
        let handler = ApplicationShortcutHandler(launcher: fixture.launcher, presentError: { _ in })
        let result = await handler.trigger(fixture.target)
        XCTAssertEqual(result, .launched)
        XCTAssertEqual(fixture.launcher.openCount, 1)
        XCTAssertTrue(fixture.launcher.lastOpenActivates)
    }

    @MainActor
    func testBackgroundApplicationActivates() async throws {
        let fixture = try ApplicationFixture(isRunning: true, isActive: false)
        let handler = ApplicationShortcutHandler(launcher: fixture.launcher, presentError: { _ in })
        let result = await handler.trigger(fixture.target)
        XCTAssertEqual(result, .activated)
        XCTAssertEqual(fixture.launcher.activateCount, 1)
    }

    @MainActor
    func testActiveApplicationHidesWhenOptionEnabled() async throws {
        let fixture = try ApplicationFixture(isRunning: true, isActive: true, hidesOnRepeatTrigger: true)
        let handler = ApplicationShortcutHandler(launcher: fixture.launcher, presentError: { _ in })
        let result = await handler.trigger(fixture.target)
        XCTAssertEqual(result, .hidden)
        XCTAssertEqual(fixture.launcher.hideCount, 1)
        XCTAssertEqual(fixture.launcher.activateCount, 0)
    }

    @MainActor
    func testActiveApplicationStaysVisibleWhenOptionDisabled() async throws {
        let fixture = try ApplicationFixture(isRunning: true, isActive: true, hidesOnRepeatTrigger: false)
        let handler = ApplicationShortcutHandler(launcher: fixture.launcher, presentError: { _ in })
        let result = await handler.trigger(fixture.target)
        XCTAssertEqual(result, .unchanged)
        XCTAssertEqual(fixture.launcher.hideCount, 0)
        XCTAssertEqual(fixture.launcher.activateCount, 0)
    }

    @MainActor
    func testMissingApplicationReportsErrorWithoutLaunching() async throws {
        let fixture = try ApplicationFixture(path: "/tmp/nylai-missing-\(UUID().uuidString).app")
        var errors: [Error] = []
        let handler = ApplicationShortcutHandler(launcher: fixture.launcher) { errors.append($0) }
        let result = await handler.trigger(fixture.target)
        XCTAssertNil(result)
        XCTAssertEqual(errors.first as? ApplicationLaunchError, .missingApplication)
        XCTAssertEqual(fixture.launcher.openCount, 0)
    }

    @MainActor
    func testConcurrentLaunchIsCoalesced() async throws {
        let fixture = try ApplicationFixture()
        fixture.launcher.launchDelay = .milliseconds(20)
        let handler = ApplicationShortcutHandler(launcher: fixture.launcher, presentError: { _ in })
        async let first = handler.trigger(fixture.target)
        async let second = handler.trigger(fixture.target)
        let results = await [first, second]
        XCTAssertEqual(fixture.launcher.openCount, 1)
        XCTAssertEqual(results.compactMap(\.self).count, 1)
    }
}

@MainActor
private final class FakeApplicationLauncher: ApplicationLaunching {
    var running: RunningApplicationState?
    var openCount = 0
    var lastOpenActivates = false
    var hideCount = 0
    var activateCount = 0
    var launchDelay: Duration = .zero

    func runningApplication(bundleIdentifier: String) -> RunningApplicationState? {
        running
    }

    func openApplication(at url: URL, activates: Bool) async throws -> NSRunningApplication {
        openCount += 1
        lastOpenActivates = activates
        if launchDelay != .zero {
            try await Task.sleep(for: launchDelay)
        }
        guard let app = NSRunningApplication.current as NSRunningApplication? else {
            throw ApplicationLaunchError.launchFailed("测试环境缺少运行实例。")
        }
        return app
    }
}

private struct ApplicationFixture {
    let launcher: FakeApplicationLauncher
    let target: ApplicationShortcutTarget

    @MainActor
    init(
        isRunning: Bool = false,
        isActive: Bool = false,
        hidesOnRepeatTrigger: Bool = true,
        path: String? = nil
    ) throws {
        launcher = FakeApplicationLauncher()
        let bundle = Bundle(for: ApplicationShortcutTests.self)
        let bundleIdentifier = bundle.bundleIdentifier ?? "com.noname4me.nylai.tests"
        let appPath = path ?? bundle.bundlePath
        target = ApplicationShortcutTarget(
            bundleIdentifier: bundleIdentifier,
            path: appPath,
            hidesOnRepeatTrigger: hidesOnRepeatTrigger
        )
        if isRunning {
            launcher.running = RunningApplicationState(
                isActive: isActive,
                hide: { [weak launcher] in
                    launcher?.hideCount += 1
                    return true
                },
                activate: { [weak launcher] in
                    launcher?.activateCount += 1
                    return true
                }
            )
        }
    }
}
