import AppKit
import Foundation
import Observation

enum ApplicationLaunchResult: Equatable {
    case launched
    case activated
    case hidden
    case unchanged
}

enum ApplicationLaunchError: LocalizedError, Equatable {
    case missingApplication
    case invalidBundle
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingApplication:
            "应用已移动或不存在，请重新选择应用。"
        case .invalidBundle:
            "所选项目不是有效的应用。"
        case .launchFailed(let message):
            "无法启动应用：\(message)"
        }
    }
}

@MainActor
protocol ApplicationLaunching: AnyObject {
    func runningApplication(bundleIdentifier: String) -> RunningApplicationState?
    func openApplication(at url: URL, activates: Bool) async throws -> NSRunningApplication
}

struct RunningApplicationState: Equatable {
    let isActive: Bool
    let hide: () -> Bool
    let activate: () -> Bool

    static func == (lhs: RunningApplicationState, rhs: RunningApplicationState) -> Bool {
        lhs.isActive == rhs.isActive
    }
}

@MainActor
final class WorkspaceApplicationLauncher: ApplicationLaunching {
    func runningApplication(bundleIdentifier: String) -> RunningApplicationState? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            return nil
        }
        return RunningApplicationState(
            isActive: app.isActive,
            hide: { app.hide() },
            activate: { app.activate(options: [.activateAllWindows]) }
        )
    }

    func openApplication(at url: URL, activates: Bool) async throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        return try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                if let error {
                    continuation.resume(throwing: ApplicationLaunchError.launchFailed(error.localizedDescription))
                } else if let app {
                    continuation.resume(returning: app)
                } else {
                    continuation.resume(throwing: ApplicationLaunchError.launchFailed("系统未返回应用实例。"))
                }
            }
        }
    }
}

@MainActor
@Observable
final class ApplicationShortcutHandler {
    private let launcher: any ApplicationLaunching
    private let presentError: @MainActor (Error) -> Void
    private var pendingBundleIdentifiers: Set<String> = []

    init(
        launcher: any ApplicationLaunching = WorkspaceApplicationLauncher(),
        presentError: @escaping @MainActor (Error) -> Void = ApplicationShortcutHandler.showError
    ) {
        self.launcher = launcher
        self.presentError = presentError
    }

    func trigger(_ target: ApplicationShortcutTarget) async -> ApplicationLaunchResult? {
        guard !pendingBundleIdentifiers.contains(target.bundleIdentifier) else { return nil }
        pendingBundleIdentifiers.insert(target.bundleIdentifier)
        defer { pendingBundleIdentifiers.remove(target.bundleIdentifier) }

        if let app = launcher.runningApplication(bundleIdentifier: target.bundleIdentifier) {
            return handleRunning(app, target: target)
        }

        let url = URL(fileURLWithPath: target.path)
        guard FileManager.default.fileExists(atPath: target.path) else {
            presentError(ApplicationLaunchError.missingApplication)
            return nil
        }
        guard Bundle(url: url)?.bundleIdentifier == target.bundleIdentifier else {
            presentError(ApplicationLaunchError.invalidBundle)
            return nil
        }

        do {
            let app = try await launcher.openApplication(at: url, activates: true)
            _ = app.activate(options: [])
            return .launched
        } catch {
            presentError(error)
            return nil
        }
    }

    func locateApplication(bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    private func handleRunning(
        _ app: RunningApplicationState,
        target: ApplicationShortcutTarget
    ) -> ApplicationLaunchResult {
        if app.isActive {
            if target.hidesOnRepeatTrigger {
                _ = app.hide()
                return .hidden
            }
            return .unchanged
        }
        _ = app.activate()
        return .activated
    }

    static func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "无法切换应用"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
