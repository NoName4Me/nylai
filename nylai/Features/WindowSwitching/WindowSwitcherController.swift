import AppKit

@MainActor
final class WindowSwitcherController {
    private let monitor = WindowSwitcherEventMonitor()
    private let catalogProvider: any WindowSwitcherCatalogProviding
    private let activator: any WindowSwitcherActivating
    private let windowCapturer: any WindowCapturing
    private let panelController = WindowSwitcherPanelController()
    private let isInteractionSuppressed: @MainActor () -> Bool
    private var snapshotTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var session: WindowSwitcherSession?
    private var pendingCommands: [WindowSwitcherSessionCommand] = []
    private var confirmWhenReady = false
    private var generation = UUID()
    private var sleepObserver: NSObjectProtocol?

    var onRuntimeStatusChange: @MainActor (ModuleRuntimeStatus) -> Void = { _ in }
    var onError: @MainActor (Error) -> Void = { _ in }

    init(
        catalogProvider: any WindowSwitcherCatalogProviding = WindowSwitcherCatalogProvider(),
        activator: any WindowSwitcherActivating = WindowSwitcherActivator(),
        windowCapturer: any WindowCapturing = ScreenCaptureService(),
        isInteractionSuppressed: @escaping @MainActor () -> Bool
    ) {
        self.catalogProvider = catalogProvider
        self.activator = activator
        self.windowCapturer = windowCapturer
        self.isInteractionSuppressed = isInteractionSuppressed
        monitor.onEvent = { [weak self] event in
            self?.handle(event)
        }
        panelController.model.onSelectApplication = { [weak self] index in
            self?.selectApplication(at: index)
        }
        panelController.model.onSelectWindow = { [weak self] windowID in
            self?.selectWindow(windowID)
        }
    }

    var isActive: Bool {
        session != nil || snapshotTask != nil
    }

    func start(requestPermission: Bool) {
        observeSleepIfNeeded()
        onRuntimeStatusChange(.starting)
        let missingPermission = WindowSwitcherPermissionPolicy.firstMissing(
            accessibilityGranted: AccessibilityPermission.isGranted,
            inputMonitoringGranted: InputMonitoringPermission.isGranted,
            screenRecordingGranted: ScreenRecordingPermission.isGranted
        )
        if let missingPermission {
            if requestPermission {
                request(missingPermission)
            }
            onRuntimeStatusChange(.failed(missingPermission.error.localizedDescription))
            return
        }
        do {
            try monitor.start()
            onRuntimeStatusChange(.running)
        } catch {
            onRuntimeStatusChange(.failed(error.localizedDescription))
        }
    }

    private func request(_ permission: WindowSwitcherPermissionRequirement) {
        switch permission {
        case .accessibility:
            AccessibilityPermission.requestIfNeeded()
        case .inputMonitoring:
            InputMonitoringPermission.requestIfNeeded()
        case .screenRecording:
            _ = ScreenRecordingPermission.requestAccessIfNeeded()
        }
    }

    func stop() {
        cancelSession()
        monitor.stop()
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
        panelController.model.clear()
    }

    func cancel() {
        cancelSession()
    }

    private func handle(_ event: WindowSwitcherEvent) {
        switch event {
        case .begin(let mode, let reverse):
            guard !isInteractionSuppressed() else {
                monitor.setSessionActive(false)
                return
            }
            begin(mode: mode, reverse: reverse)
        case .command(let command):
            handleCommand(command)
        }
    }

    private func begin(mode: WindowSwitcherMode, reverse: Bool) {
        resetSessionState()
        let requestGeneration = UUID()
        generation = requestGeneration
        confirmWhenReady = false
        pendingCommands = []
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await catalogProvider.makeSnapshot()
                try Task.checkCancellation()
                guard generation == requestGeneration else {
                    closePanel()
                    return
                }
                snapshotTask = nil
                let newSession = try WindowSwitcherSession(
                    snapshot: snapshot,
                    mode: mode,
                    reverse: reverse
                )
                if confirmWhenReady {
                    finish(with: newSession)
                    return
                }
                session = newSession
                for command in pendingCommands {
                    session?.apply(command)
                }
                pendingCommands = []
                presentSession()
            } catch is CancellationError {
                if generation == requestGeneration {
                    closePanel()
                }
            } catch {
                if generation == requestGeneration {
                    monitor.setSessionActive(false)
                    closePanel()
                    if error as? WindowSwitcherError != .noCurrentApplication,
                       error as? WindowSwitcherError != .noCurrentWindows {
                        onError(error)
                    }
                }
            }
        }
    }

    private func handleCommand(_ command: WindowSwitcherSessionCommand) {
        if command == .cancel {
            cancelSession()
            return
        }
        guard session != nil else {
            if command == .confirm {
                confirmWhenReady = true
            } else if snapshotTask != nil {
                pendingCommands.append(command)
            }
            return
        }
        if command == .confirm {
            guard let session else { return }
            finish(with: session)
            return
        }
        session?.apply(command)
        guard let session else { return }
        panelController.model.update(with: session)
        loadPreviews(for: session.selectedApplication, generation: generation)
    }

    private func presentSession() {
        guard let session else { return }
        panelController.model.update(with: session)
        panelController.present()
        loadPreviews(for: session.selectedApplication, generation: generation)
    }

    private func selectApplication(at index: Int) {
        guard session != nil else { return }
        session?.apply(.selectApplication(index))
        guard let session else { return }
        panelController.model.update(with: session)
        loadPreviews(for: session.selectedApplication, generation: generation)
    }

    private func selectWindow(_ windowID: CGWindowID) {
        guard session != nil else { return }
        session?.apply(.selectWindow(windowID))
        guard let session, session.selectedWindow?.id == windowID else { return }
        panelController.model.update(with: session)
        finish(with: session)
    }

    private func loadPreviews(
        for application: WindowSwitcherApplication,
        generation requestGeneration: UUID
    ) {
        previewTask?.cancel()
        let requestedIDs = Set(application.windows.map(\.id))
        panelController.model.loadingWindowIDs = Set(
            application.windows.compactMap {
                panelController.model.previews[$0.id] == nil ? $0.id : nil
            }
        )
        previewTask = Task { [weak self] in
            guard let self else { return }
            for window in application.windows {
                guard generation == requestGeneration,
                      session?.selectedApplication.id == application.id else {
                    return
                }
                if panelController.model.previews[window.id] != nil {
                    panelController.model.loadingWindowIDs.remove(window.id)
                    continue
                }
                do {
                    let image = try await windowCapturer.captureWindow(window.id)
                    try Task.checkCancellation()
                    guard generation == requestGeneration else { return }
                    panelController.model.previews[window.id] = image
                } catch is CancellationError {
                    return
                } catch {
                    // A failed preview falls back to the window title and icon.
                }
            }
            guard generation == requestGeneration else { return }
            panelController.model.loadingWindowIDs.subtract(requestedIDs)
        }
    }

    private func finish(with session: WindowSwitcherSession) {
        let target = session.confirmationTarget
        monitor.setSessionActive(false)
        closePanel()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await activator.activate(target)
            } catch {
                onError(error)
            }
        }
    }

    private func cancelSession() {
        monitor.setSessionActive(false)
        resetSessionState()
    }

    private func resetSessionState() {
        generation = UUID()
        snapshotTask?.cancel()
        snapshotTask = nil
        previewTask?.cancel()
        previewTask = nil
        pendingCommands = []
        confirmWhenReady = false
        session = nil
        closePanel()
    }

    private func closePanel() {
        panelController.close()
        previewTask?.cancel()
        previewTask = nil
    }

    private func observeSleepIfNeeded() {
        guard sleepObserver == nil else { return }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancel()
            }
        }
    }
}
