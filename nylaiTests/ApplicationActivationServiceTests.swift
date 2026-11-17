import AppKit
import XCTest
@testable import nylai

@MainActor
final class ApplicationActivationServiceTests: XCTestCase {
    func testVisibleApplicationIsBroughtToFrontWithoutOpening() async throws {
        var activationCount = 0
        var openCount = 0
        let service = ApplicationActivationService(
            openApplication: { _ in openCount += 1 },
            windowState: { _ in .visible }
        )
        let target = makeTarget { _ in
            activationCount += 1
            return true
        }

        let outcome = try await service.activate(target)

        XCTAssertEqual(outcome, ApplicationActivationOutcome.broughtToFront)
        XCTAssertEqual(activationCount, 1)
        XCTAssertEqual(openCount, 0)
    }

    func testMinimizedWindowIsRestoredBeforeActivation() async throws {
        var events: [String] = []
        let service = ApplicationActivationService(
            openApplication: { _ in events.append("open") },
            windowState: { _ in
                .minimized(ApplicationWindowHandle(
                    unminimize: {
                        events.append("unminimize")
                        return true
                    },
                    focusAndRaise: {
                        events.append("focus")
                        return true
                    }
                ))
            }
        )
        let target = makeTarget { _ in
            events.append("activate")
            return true
        }

        let outcome = try await service.activate(target)

        XCTAssertEqual(outcome, ApplicationActivationOutcome.restoredWindow)
        XCTAssertEqual(events, ["unminimize", "activate", "focus"])
    }

    func testApplicationWithoutWindowsReopensBundleLikeDockClick() async throws {
        var activated = false
        var openedURL: URL?
        let service = ApplicationActivationService(
            openApplication: { openedURL = $0 },
            windowState: { _ in .none }
        )
        let url = URL(fileURLWithPath: "/Applications/Test.app")
        let target = ApplicationActivationTarget(
            processIdentifier: 42,
            bundleURL: url,
            activate: { _ in
                activated = true
                return true
            }
        )

        let outcome = try await service.activate(target)

        XCTAssertEqual(outcome, ApplicationActivationOutcome.openedWindow)
        XCTAssertEqual(openedURL, url)
        XCTAssertFalse(activated)
    }

    func testFrontmostApplicationWithoutWindowsStillReopensBundle() async throws {
        var openedURL: URL?
        let service = ApplicationActivationService(
            openApplication: { openedURL = $0 },
            windowState: { _ in .none }
        )
        let url = URL(fileURLWithPath: "/Applications/Finder.app")
        let target = ApplicationActivationTarget(
            processIdentifier: 42,
            bundleURL: url,
            activate: { _ in true }
        )

        let outcome = try await service.activate(target)

        XCTAssertEqual(outcome, .openedWindow)
        XCTAssertEqual(openedURL, url)
    }

    func testFailedMinimizedRestoreFallsBackToReopening() async throws {
        var openedURL: URL?
        let service = ApplicationActivationService(
            openApplication: { openedURL = $0 },
            windowState: { _ in
                .minimized(ApplicationWindowHandle(
                    unminimize: { false },
                    focusAndRaise: { true }
                ))
            }
        )
        let url = URL(fileURLWithPath: "/Applications/Test.app")
        let target = ApplicationActivationTarget(
            processIdentifier: 42,
            bundleURL: url,
            activate: { _ in true }
        )

        _ = try await service.activate(target)

        XCTAssertEqual(openedURL, url)
    }

    func testActivationFailureIsReported() async throws {
        let service = ApplicationActivationService(
            openApplication: { _ in },
            windowState: { _ in .visible }
        )
        let target = makeTarget { _ in false }

        do {
            _ = try await service.activate(target)
            XCTFail("A failed activation must be reported.")
        } catch {
            XCTAssertEqual(error as? ApplicationActivationError, .activationFailed)
        }
    }

    func testVisibleWindowDetectionOnlyAcceptsVisibleState() {
        let visible = ApplicationActivationService(
            openApplication: { _ in },
            windowState: { _ in .visible }
        )
        let minimized = ApplicationActivationService(
            openApplication: { _ in },
            windowState: { _ in
                .minimized(ApplicationWindowHandle(
                    unminimize: { true },
                    focusAndRaise: { true }
                ))
            }
        )
        let windowless = ApplicationActivationService(
            openApplication: { _ in },
            windowState: { _ in .none }
        )

        XCTAssertTrue(visible.hasVisibleWindow(processIdentifier: 42))
        XCTAssertFalse(minimized.hasVisibleWindow(processIdentifier: 42))
        XCTAssertFalse(windowless.hasVisibleWindow(processIdentifier: 42))
    }

    private func makeTarget(
        activate: @escaping @MainActor (NSApplication.ActivationOptions) -> Bool
    ) -> ApplicationActivationTarget {
        ApplicationActivationTarget(
            processIdentifier: 42,
            bundleURL: URL(fileURLWithPath: "/Applications/Test.app"),
            activate: activate
        )
    }
}
