import AppKit
import CoreGraphics

struct WindowSwitcherWindow: Identifiable, Equatable, Sendable {
    let id: CGWindowID
    let title: String?
    let frame: CGRect
}

struct WindowSwitcherApplication: Identifiable, Equatable, Sendable {
    let id: pid_t
    let bundleIdentifier: String?
    let name: String
    let windows: [WindowSwitcherWindow]
}

struct WindowSwitcherSnapshot: Equatable, Sendable {
    let applications: [WindowSwitcherApplication]
    let currentApplicationID: pid_t?
}

struct WindowSwitcherTarget: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let applicationName: String
    let windowID: CGWindowID?
    let windowTitle: String?
    let windowFrame: CGRect?
}

struct WindowSwitcherRunningApplication: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let name: String
}

enum WindowSwitcherMode: Equatable, Sendable {
    case applications
    case windows
}

enum WindowSwitcherSessionCommand: Equatable, Sendable {
    case cycleApplications(Int)
    case cycleWindows(Int)
    case selectApplication(Int)
    case selectWindow(CGWindowID)
    case confirm
    case cancel
}

struct WindowSwitcherSession: Equatable, Sendable {
    let mode: WindowSwitcherMode
    let snapshot: WindowSwitcherSnapshot
    private(set) var selectedApplicationIndex: Int
    private(set) var selectedWindowIndex: Int

    init(
        snapshot: WindowSwitcherSnapshot,
        mode: WindowSwitcherMode,
        reverse: Bool
    ) throws {
        guard !snapshot.applications.isEmpty else {
            throw WindowSwitcherError.noApplications
        }
        self.mode = mode
        self.snapshot = snapshot
        selectedApplicationIndex = 0
        selectedWindowIndex = 0

        let currentIndex = snapshot.currentApplicationID.flatMap { currentApplicationID in
            snapshot.applications.firstIndex { $0.id == currentApplicationID }
        }
        guard let currentIndex else {
            if mode == .windows {
                throw WindowSwitcherError.noCurrentApplication
            }
            return
        }

        switch mode {
        case .applications:
            selectedApplicationIndex = moved(
                from: currentIndex,
                offset: reverse ? -1 : 1,
                count: snapshot.applications.count
            )
        case .windows:
            selectedApplicationIndex = currentIndex
            let windows = snapshot.applications[currentIndex].windows
            guard !windows.isEmpty else {
                throw WindowSwitcherError.noCurrentWindows
            }
            selectedWindowIndex = windows.count > 1 ? 1 : 0
            if reverse, windows.count > 1 {
                selectedWindowIndex = windows.count - 1
            }
        }
    }

    var selectedApplication: WindowSwitcherApplication {
        snapshot.applications[selectedApplicationIndex]
    }

    var selectedWindow: WindowSwitcherWindow? {
        let windows = selectedApplication.windows
        guard windows.indices.contains(selectedWindowIndex) else { return nil }
        return windows[selectedWindowIndex]
    }

    var confirmationTarget: WindowSwitcherTarget {
        let application = selectedApplication
        let window = selectedWindow
        return WindowSwitcherTarget(
            processIdentifier: application.id,
            bundleIdentifier: application.bundleIdentifier,
            applicationName: application.name,
            windowID: window?.id,
            windowTitle: window?.title,
            windowFrame: window?.frame
        )
    }

    mutating func apply(_ command: WindowSwitcherSessionCommand) {
        switch command {
        case .cycleApplications(let offset):
            selectedApplicationIndex = moved(
                from: selectedApplicationIndex,
                offset: offset,
                count: snapshot.applications.count
            )
            selectedWindowIndex = 0
        case .cycleWindows(let offset):
            let count = selectedApplication.windows.count
            guard count > 0 else {
                selectedWindowIndex = 0
                return
            }
            selectedWindowIndex = moved(
                from: selectedWindowIndex,
                offset: offset,
                count: count
            )
        case .selectApplication(let index):
            guard snapshot.applications.indices.contains(index) else { return }
            selectedApplicationIndex = index
            selectedWindowIndex = 0
        case .selectWindow(let windowID):
            guard let index = selectedApplication.windows.firstIndex(where: {
                $0.id == windowID
            }) else {
                return
            }
            selectedWindowIndex = index
        case .confirm, .cancel:
            break
        }
    }

    private func moved(from index: Int, offset: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (index + offset % count + count) % count
    }
}

enum WindowSwitcherError: LocalizedError, Equatable {
    case noApplications
    case noCurrentApplication
    case noCurrentWindows
    case inputTapUnavailable
    case accessibilityUnavailable
    case accessibilityPermissionRequired
    case inputMonitoringPermissionRequired
    case screenRecordingPermissionRequired
    case targetUnavailable
    case windowUnavailable

    var errorDescription: String? {
        switch self {
        case .noApplications:
            L10n.shared.string("没有可切换的应用。")
        case .noCurrentApplication:
            L10n.shared.string("无法识别当前应用。")
        case .noCurrentWindows:
            L10n.shared.string("当前应用没有可切换的窗口。")
        case .inputTapUnavailable:
            L10n.shared.string(
                "无法接管键盘切换。请在系统设置中允许 %@ 使用辅助功能和输入监控。",
                AppName.current
            )
        case .accessibilityUnavailable:
            L10n.shared.string(
                "无法定位目标窗口。请在系统设置中允许 %@ 使用辅助功能。",
                AppName.current
            )
        case .accessibilityPermissionRequired:
            L10n.shared.string("窗口切换需要辅助功能权限，请按系统提示完成授权。")
        case .inputMonitoringPermissionRequired:
            L10n.shared.string("窗口切换需要输入监控权限，请按系统提示完成授权。")
        case .screenRecordingPermissionRequired:
            L10n.shared.string(
                "窗口预览需要屏幕录制权限，请按系统提示完成授权并重新启动 %@。",
                AppName.current
            )
        case .targetUnavailable:
            L10n.shared.string("目标应用已关闭，未执行切换。")
        case .windowUnavailable:
            L10n.shared.string("目标窗口已关闭或无法激活。")
        }
    }
}

enum WindowSwitcherPermissionRequirement: Equatable, Sendable {
    case accessibility
    case inputMonitoring
    case screenRecording

    var error: WindowSwitcherError {
        switch self {
        case .accessibility:
            .accessibilityPermissionRequired
        case .inputMonitoring:
            .inputMonitoringPermissionRequired
        case .screenRecording:
            .screenRecordingPermissionRequired
        }
    }
}

enum WindowSwitcherPermissionPolicy {
    static func firstMissing(
        accessibilityGranted: Bool,
        inputMonitoringGranted: Bool,
        screenRecordingGranted: Bool
    ) -> WindowSwitcherPermissionRequirement? {
        if !accessibilityGranted {
            return .accessibility
        }
        if !inputMonitoringGranted {
            return .inputMonitoring
        }
        if !screenRecordingGranted {
            return .screenRecording
        }
        return nil
    }
}

enum WindowSwitcherEvent: Equatable, Sendable {
    case begin(WindowSwitcherMode, reverse: Bool)
    case command(WindowSwitcherSessionCommand)
}

enum WindowSwitcherKeyClassifier {
    static func event(
        keyCode: UInt16,
        flags: CGEventFlags,
        unicode: String?,
        sessionIsActive: Bool
    ) -> WindowSwitcherEvent? {
        let commandIsDown = flags.contains(.maskCommand)
        let reverse = flags.contains(.maskShift)

        if sessionIsActive, !commandIsDown {
            return .command(.confirm)
        }
        guard commandIsDown else { return nil }

        if keyCode == 53 {
            return sessionIsActive ? .command(.cancel) : nil
        }
        if keyCode == 48 {
            return sessionIsActive
                ? .command(.cycleApplications(reverse ? -1 : 1))
                : .begin(.applications, reverse: reverse)
        }
        if isWindowKey(keyCode: keyCode, unicode: unicode) {
            return sessionIsActive
                ? .command(.cycleWindows(reverse ? -1 : 1))
                : .begin(.windows, reverse: reverse)
        }
        if sessionIsActive {
            switch keyCode {
            case 123:
                return .command(.cycleWindows(-1))
            case 124:
                return .command(.cycleWindows(1))
            default:
                break
            }
        }
        return nil
    }

    static func shouldClaim(
        keyCode: UInt16,
        flags: CGEventFlags,
        unicode: String?,
        sessionIsActive: Bool
    ) -> Bool {
        guard flags.contains(.maskCommand) else { return false }
        if keyCode == 48 || isWindowKey(keyCode: keyCode, unicode: unicode) {
            return true
        }
        return sessionIsActive && (keyCode == 53 || keyCode == 123 || keyCode == 124)
    }

    private static func isWindowKey(keyCode: UInt16, unicode: String?) -> Bool {
        keyCode == 50 || keyCode == 10 || unicode == "`" || unicode == "~"
    }
}

enum WindowSwitcherSnapshotBuilder {
    static func make(
        runningApplications: [WindowSwitcherRunningApplication],
        candidates: [WindowCaptureCandidate],
        currentProcessIdentifier: pid_t,
        currentApplicationID: pid_t?,
        displayFrames: [CGRect]
    ) -> WindowSwitcherSnapshot {
        let visibleCandidates = candidates.filter { candidate in
            candidate.processIdentifier > 0
                && candidate.bundleIdentifier != Bundle.main.bundleIdentifier
                && displayFrames.contains { displayFrame in
                    displayFrame.contains(
                        CGPoint(
                            x: candidate.frame.midX,
                            y: candidate.frame.midY
                        )
                    )
                }
        }
        var applicationsByProcess: [pid_t: WindowSwitcherRunningApplication] = [:]
        for application in runningApplications {
            applicationsByProcess[application.processIdentifier] = application
        }
        for candidate in visibleCandidates {
            let processIdentifier = candidate.processIdentifier
            guard processIdentifier != currentProcessIdentifier,
                  applicationsByProcess[processIdentifier] == nil else {
                continue
            }
            applicationsByProcess[processIdentifier] = WindowSwitcherRunningApplication(
                processIdentifier: processIdentifier,
                bundleIdentifier: candidate.bundleIdentifier,
                name: candidate.applicationName ?? "未命名应用"
            )
        }

        let candidateOrder = visibleCandidates.map(\.processIdentifier)
        let applicationOrder = candidateOrder + applicationsByProcess.keys.sorted()
        var seen = Set<pid_t>()
        let orderedApplications = applicationOrder.compactMap { processIdentifier -> WindowSwitcherApplication? in
            guard seen.insert(processIdentifier).inserted,
                  let running = applicationsByProcess[processIdentifier] else {
                return nil
            }
            let windows = visibleCandidates.compactMap { candidate -> WindowSwitcherWindow? in
                guard candidate.processIdentifier == processIdentifier else {
                    return nil
                }
                return WindowSwitcherWindow(
                    id: candidate.windowID,
                    title: candidate.title,
                    frame: candidate.frame
                )
            }
            return WindowSwitcherApplication(
                id: processIdentifier,
                bundleIdentifier: running.bundleIdentifier,
                name: running.name,
                windows: windows
            )
        }
        return WindowSwitcherSnapshot(
            applications: orderedApplications,
            currentApplicationID: currentApplicationID
        )
    }
}
