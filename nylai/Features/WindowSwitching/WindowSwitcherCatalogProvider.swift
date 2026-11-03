import AppKit

@MainActor
protocol WindowSwitcherCatalogProviding {
    func makeSnapshot() async throws -> WindowSwitcherSnapshot
}

@MainActor
final class WindowSwitcherCatalogProvider: WindowSwitcherCatalogProviding {
    private let windowCapturer: any WindowCapturing

    init(windowCapturer: any WindowCapturing = ScreenCaptureService()) {
        self.windowCapturer = windowCapturer
    }

    func makeSnapshot() async throws -> WindowSwitcherSnapshot {
        let candidates = try await windowCapturer.windowCandidates()
        let runningApplications = NSWorkspace.shared.runningApplications.compactMap { application -> WindowSwitcherRunningApplication? in
            guard application.activationPolicy == .regular,
                  application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                return nil
            }
            return WindowSwitcherRunningApplication(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                name: application.localizedName ?? application.bundleIdentifier ?? "未命名应用"
            )
        }
        let currentApplication = NSWorkspace.shared.frontmostApplication
        return WindowSwitcherSnapshotBuilder.make(
            runningApplications: runningApplications,
            candidates: candidates,
            currentProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
            currentApplicationID: currentApplication?.processIdentifier,
            displayFrames: NSScreen.screens.map(\.frame)
        )
    }
}
