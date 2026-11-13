import CoreGraphics
import AppKit
import SwiftUI
import XCTest
@testable import nylai

final class WindowSwitcherTests: XCTestCase {
    @MainActor
    func testEightPreviewsRender() throws {
        let model = WindowSwitcherPanelModel()
        model.applications = [
            application(id: 1, name: "Finder", windows: (1...8).map {
                WindowSwitcherWindow(id: UInt32($0), title: "Window \($0)",
                                     frame: CGRect(x: 0, y: 0, width: 800, height: 600))
            }),
            application(id: 2, name: "Mail", windows: []),
        ]
        model.selectedWindowID = 1
        let host = NSHostingView(rootView: WindowSwitcherPanelView(
            model: model, hoveredApplicationID: 2, hoveredWindowID: 2
        )
            .environment(\.colorScheme, .light))
        host.frame = CGRect(x: 0, y: 0, width: 1280, height: 740)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let attachment = XCTAttachment(image: NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: host.bounds.size))
        attachment.name = "Eight Window Previews"
        attachment.lifetime = .keepAlways
        add(attachment)
        window.orderOut(nil)
    }

    func testUpToEightPreviewsFitWithoutVerticalOverflow() {
        for count in 1...8 {
            for height: CGFloat in [280, 480, 720] {
                let layout = WindowPreviewGridLayout(windowCount: count, availableWidth: 1000, availableHeight: height)
                let rows = CGFloat((count + layout.columns.count - 1) / layout.columns.count)
                let cardHeight = (layout.itemWidth - 16) / 1.6 + 40
                XCTAssertLessThanOrEqual(rows * cardHeight + (rows - 1) * 20 + 48, height + 0.1)
            }
        }
    }

    func testApplicationSwitchStartsOnCurrentApplicationAndCycles() throws {
        let snapshot = WindowSwitcherSnapshot(
            applications: [
                application(id: 1, name: "Current", windows: [window(id: 11)]),
                application(id: 2, name: "Previous", windows: [window(id: 21)]),
                application(id: 3, name: "Other", windows: [window(id: 31)]),
            ],
            currentApplicationID: 1
        )

        var session = try WindowSwitcherSession(
            snapshot: snapshot,
            mode: .applications,
            reverse: false
        )
        XCTAssertEqual(session.selectedApplication.id, 1)
        XCTAssertEqual(session.confirmationTarget.windowID, 11)

        session.apply(.cycleApplications(1))
        XCTAssertEqual(session.selectedApplication.id, 2)

        session.apply(.cycleApplications(1))
        XCTAssertEqual(session.selectedApplication.id, 3)
    }

    func testWindowSwitchStartsOnPreviousWindowAndCycles() throws {
        let snapshot = WindowSwitcherSnapshot(
            applications: [
                application(
                    id: 1,
                    name: "Current",
                    windows: [window(id: 11), window(id: 12), window(id: 13)]
                ),
                application(id: 2, name: "Other", windows: [window(id: 21)]),
            ],
            currentApplicationID: 1
        )

        var session = try WindowSwitcherSession(
            snapshot: snapshot,
            mode: .windows,
            reverse: false
        )
        XCTAssertEqual(session.selectedWindow?.id, 12)

        session.apply(.cycleWindows(1))
        XCTAssertEqual(session.selectedWindow?.id, 13)

        session.apply(.cycleWindows(1))
        XCTAssertEqual(session.selectedWindow?.id, 11)
    }

    func testChangingApplicationResetsWindowSelection() throws {
        let snapshot = WindowSwitcherSnapshot(
            applications: [
                application(id: 1, name: "Current", windows: [window(id: 11)]),
                application(
                    id: 2,
                    name: "Previous",
                    windows: [window(id: 21), window(id: 22)]
                ),
            ],
            currentApplicationID: 1
        )
        var session = try WindowSwitcherSession(
            snapshot: snapshot,
            mode: .applications,
            reverse: false
        )

        session.apply(.cycleApplications(1))
        session.apply(.cycleWindows(1))
        XCTAssertEqual(session.selectedWindow?.id, 22)

        session.apply(.cycleApplications(1))
        XCTAssertEqual(session.selectedApplication.id, 1)
        XCTAssertEqual(session.selectedWindow?.id, 11)
    }

    func testDirectWindowSwitchRequiresCurrentWindows() {
        let snapshot = WindowSwitcherSnapshot(
            applications: [
                application(id: 1, name: "Empty", windows: []),
            ],
            currentApplicationID: 1
        )

        XCTAssertThrowsError(
            try WindowSwitcherSession(
                snapshot: snapshot,
                mode: .windows,
                reverse: false
            )
        ) { error in
            XCTAssertEqual(error as? WindowSwitcherError, .noCurrentWindows)
        }
    }

    func testKeyClassifierClaimsSystemSwitchingKeysOnly() {
        XCTAssertEqual(
            WindowSwitcherKeyClassifier.event(
                keyCode: 48,
                flags: [.maskCommand],
                unicode: "\t",
                sessionIsActive: false
            ),
            .begin(.applications, reverse: false)
        )
        XCTAssertEqual(
            WindowSwitcherKeyClassifier.event(
                keyCode: 50,
                flags: [.maskCommand],
                unicode: "`",
                sessionIsActive: false
            ),
            .begin(.windows, reverse: false)
        )
        XCTAssertEqual(
            WindowSwitcherKeyClassifier.event(
                keyCode: 48,
                flags: [.maskCommand, .maskShift],
                unicode: "\t",
                sessionIsActive: true
            ),
            .command(.cycleApplications(-1))
        )
        XCTAssertNil(
            WindowSwitcherKeyClassifier.event(
                keyCode: 13,
                flags: [.maskCommand],
                unicode: "w",
                sessionIsActive: true
            )
        )
        XCTAssertTrue(
            WindowSwitcherKeyClassifier.shouldClaim(
                keyCode: 53,
                flags: [.maskCommand],
                unicode: nil,
                sessionIsActive: true
            )
        )
        XCTAssertEqual(
            WindowSwitcherKeyClassifier.event(
                keyCode: 55,
                flags: [],
                unicode: nil,
                sessionIsActive: true
            ),
            .command(.confirm)
        )
    }

    func testSnapshotBuilderGroupsVisibleWindowsAndIncludesWindowlessApplications() {
        let display = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let snapshot = WindowSwitcherSnapshotBuilder.make(
            runningApplications: [
                WindowSwitcherRunningApplication(
                    processIdentifier: 1,
                    bundleIdentifier: "com.example.current",
                    name: "Current"
                ),
                WindowSwitcherRunningApplication(
                    processIdentifier: 2,
                    bundleIdentifier: "com.example.editor",
                    name: "Editor"
                ),
                WindowSwitcherRunningApplication(
                    processIdentifier: 3,
                    bundleIdentifier: "com.example.empty",
                    name: "Empty"
                ),
            ],
            candidates: [
                candidate(id: 21, pid: 2, title: "Front", frame: CGRect(x: 10, y: 10, width: 300, height: 200)),
                candidate(id: 22, pid: 2, title: "Back", frame: CGRect(x: 30, y: 30, width: 300, height: 200)),
                candidate(id: 11, pid: 1, title: "Current", frame: CGRect(x: 100, y: 100, width: 300, height: 200)),
                candidate(id: 999, pid: 999, title: "Nylai", frame: CGRect(x: 120, y: 120, width: 300, height: 200)),
                candidate(id: 91, pid: 9, title: "Offscreen", frame: CGRect(x: 2000, y: 2000, width: 100, height: 100)),
            ],
            currentProcessIdentifier: 999,
            currentApplicationID: 1,
            displayFrames: [display]
        )

        XCTAssertEqual(snapshot.applications.map(\.name), ["Editor", "Current", "Empty"])
        XCTAssertEqual(snapshot.applications[0].windows.map(\.id), [21, 22])
        XCTAssertEqual(snapshot.applications[1].windows.map(\.id), [11])
        XCTAssertTrue(snapshot.applications[2].windows.isEmpty)
    }

    func testPermissionPolicyRequestsOneMissingPermissionAtATime() {
        XCTAssertEqual(
            WindowSwitcherPermissionPolicy.firstMissing(
                accessibilityGranted: false,
                inputMonitoringGranted: false,
                screenRecordingGranted: false
            ),
            .accessibility
        )
        XCTAssertEqual(
            WindowSwitcherPermissionPolicy.firstMissing(
                accessibilityGranted: true,
                inputMonitoringGranted: false,
                screenRecordingGranted: false
            ),
            .inputMonitoring
        )
        XCTAssertEqual(
            WindowSwitcherPermissionPolicy.firstMissing(
                accessibilityGranted: true,
                inputMonitoringGranted: true,
                screenRecordingGranted: false
            ),
            .screenRecording
        )
        XCTAssertNil(
            WindowSwitcherPermissionPolicy.firstMissing(
                accessibilityGranted: true,
                inputMonitoringGranted: true,
                screenRecordingGranted: true
            )
        )
    }

    func testSnapshotBuilderIncludesWindowsFromEveryVisibleDisplay() {
        let snapshot = WindowSwitcherSnapshotBuilder.make(
            runningApplications: [
                WindowSwitcherRunningApplication(
                    processIdentifier: 2,
                    bundleIdentifier: "com.example.editor",
                    name: "Editor"
                ),
            ],
            candidates: [
                candidate(
                    id: 21,
                    pid: 2,
                    title: "Primary",
                    frame: CGRect(x: 100, y: 100, width: 300, height: 200)
                ),
                candidate(
                    id: 22,
                    pid: 2,
                    title: "Secondary",
                    frame: CGRect(x: 2100, y: 100, width: 300, height: 200)
                ),
            ],
            currentProcessIdentifier: 999,
            currentApplicationID: 2,
            displayFrames: [
                CGRect(x: 0, y: 0, width: 1200, height: 800),
                CGRect(x: 2000, y: 0, width: 1200, height: 800),
            ]
        )

        XCTAssertEqual(snapshot.applications[0].windows.map(\.id), [21, 22])
    }

    func testAccessibilityMatcherOnlyKeepsExistingWindowFrames() {
        let existingWindow = WindowCaptureAccessibilityWindow(
            title: "Document",
            frame: CGRect(x: 40, y: 60, width: 800, height: 600)
        )

        XCTAssertTrue(
            WindowCaptureAccessibilityMatcher.contains(
                candidateTitle: "Document",
                candidateFrame: CGRect(x: 42, y: 59, width: 799, height: 601),
                in: [existingWindow]
            )
        )
        XCTAssertFalse(
            WindowCaptureAccessibilityMatcher.contains(
                candidateTitle: nil,
                candidateFrame: CGRect(x: 40, y: 60, width: 800, height: 600),
                in: [existingWindow]
            )
        )
        let untitled = WindowCaptureAccessibilityWindow(windowID: 42, title: nil, frame: existingWindow.frame)
        XCTAssertTrue(WindowCaptureAccessibilityMatcher.contains(
            candidateID: 42, candidateTitle: nil, candidateFrame: untitled.frame, in: [untitled]
        ))
        XCTAssertFalse(WindowCaptureAccessibilityMatcher.contains(
            candidateID: 43, candidateTitle: nil, candidateFrame: untitled.frame, in: [untitled]
        ))
        XCTAssertFalse(
            WindowCaptureAccessibilityMatcher.contains(
                candidateTitle: "Closed Window",
                candidateFrame: CGRect(x: 40, y: 60, width: 800, height: 600),
                in: [existingWindow]
            )
        )
        XCTAssertFalse(
            WindowCaptureAccessibilityMatcher.contains(
                candidateTitle: "Document",
                candidateFrame: CGRect(x: 120, y: 60, width: 800, height: 600),
                in: [existingWindow]
            )
        )
    }

    @MainActor
    func testWindowFrameMatchingRejectsAReusedOrMovedWindow() {
        let expected = CGRect(x: 20, y: 30, width: 400, height: 300)
        XCTAssertTrue(
            WindowSwitcherActivator.frameMatches(
                CGRect(x: 22, y: 29, width: 401, height: 299),
                expected
            )
        )
        XCTAssertFalse(
            WindowSwitcherActivator.frameMatches(
                CGRect(x: 120, y: 30, width: 400, height: 300),
                expected
            )
        )
    }

    private func application(
        id: pid_t,
        name: String,
        windows: [WindowSwitcherWindow]
    ) -> WindowSwitcherApplication {
        WindowSwitcherApplication(
            id: id,
            bundleIdentifier: "com.example.\(id)",
            name: name,
            windows: windows
        )
    }

    private func window(id: CGWindowID) -> WindowSwitcherWindow {
        WindowSwitcherWindow(
            id: id,
            title: "Window \(id)",
            frame: CGRect(x: 0, y: 0, width: 300, height: 200)
        )
    }

    private func candidate(
        id: CGWindowID,
        pid: pid_t,
        title: String,
        frame: CGRect
    ) -> WindowCaptureCandidate {
        WindowCaptureCandidate(
            windowID: id,
            processIdentifier: pid,
            frame: frame,
            title: title,
            applicationName: nil,
            bundleIdentifier: "com.example.\(pid)"
        )
    }
}
