import AppKit

@MainActor
protocol WindowSwitcherCatalogProviding {
    func makeSnapshot() async throws -> WindowSwitcherSnapshot
}

@MainActor
final class WindowSwitcherCatalogProvider: WindowSwitcherCatalogProviding {
    private let windowCapturer: any WindowCapturing
    private let pinnedApplications: WindowSwitcherPinnedApplications

    init(windowCapturer: any WindowCapturing = ScreenCaptureService(),
         pinnedApplications: WindowSwitcherPinnedApplications = WindowSwitcherPinnedApplications()) {
        self.windowCapturer = windowCapturer
        self.pinnedApplications = pinnedApplications
    }

    func makeSnapshot() async throws -> WindowSwitcherSnapshot {
        let candidates = try await windowCapturer.switchableWindowCandidates()
        let runningApplications = NSWorkspace.shared.runningApplications.compactMap { application -> WindowSwitcherRunningApplication? in
            guard application.activationPolicy == .regular,
                  application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                return nil
            }
            return WindowSwitcherRunningApplication(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                name: application.localizedName ?? application.bundleIdentifier ?? "未命名应用",
                applicationURL: application.bundleURL
            )
        }
        let currentApplication = NSWorkspace.shared.frontmostApplication
        let snapshot = WindowSwitcherSnapshotBuilder.make(
            runningApplications: runningApplications,
            candidates: candidates,
            currentProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
            currentApplicationID: currentApplication?.processIdentifier,
            displayFrames: NSScreen.screens.map(\.frame)
        )
        return pinnedApplications.applying(to: snapshot) { pin in
            if Bundle(url: pin.applicationURL)?.bundleIdentifier == pin.bundleIdentifier { return pin.applicationURL }
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: pin.bundleIdentifier)
        }
    }
}
