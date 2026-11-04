import AppKit
import Observation

struct ClipboardMonitorFrontmostApplication: Equatable, Sendable {
    let bundleIdentifier: String?
    let localizedName: String?
}

@MainActor
@Observable
final class ClipboardMonitor {
    private let pasteboard: any ClipboardPasteboardAccessing
    private let store: ClipboardHistoryStore
    private let pollInterval: Duration
    private let decoder: @Sendable (ClipboardPayloadSnapshot) async -> ClipboardObservedChange
    nonisolated private let notificationCenter: NotificationCenter
    private let frontmostApplication: @MainActor () -> ClipboardMonitorFrontmostApplication?
    private var pollingTask: Task<Void, Never>?
    private var isProcessingChange = false
    private var generation = 0
    private var baselineChangeCount = 0
    private(set) var isSleeping = false
    private var lastCleanupAt: Date?
    @ObservationIgnored
    nonisolated(unsafe) private var workspaceObservers: [NSObjectProtocol] = []
    var onRuntimeStatusChange: ((ModuleRuntimeStatus, String?) -> Void)?

    private(set) var isActive = false
    private(set) var runtimeStatus: ModuleRuntimeStatus = .off
    private(set) var statusText = "已关闭"

    init(
        store: ClipboardHistoryStore,
        pasteboard: any ClipboardPasteboardAccessing = SystemClipboardPasteboard(),
        pollInterval: Duration = .milliseconds(500),
        decoder: @escaping @Sendable (ClipboardPayloadSnapshot) async -> ClipboardObservedChange = {
            await ClipboardChangeReader.decode($0)
        },
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        frontmostApplication: @escaping @MainActor () -> ClipboardMonitorFrontmostApplication? = {
            NSWorkspace.shared.frontmostApplication.map {
                ClipboardMonitorFrontmostApplication(
                    bundleIdentifier: $0.bundleIdentifier,
                    localizedName: $0.localizedName
                )
            }
        }
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.pollInterval = pollInterval
        self.decoder = decoder
        self.notificationCenter = notificationCenter
        self.frontmostApplication = frontmostApplication
        observeWorkspace()
    }

    deinit {
        for observer in workspaceObservers {
            notificationCenter.removeObserver(observer)
        }
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        isSleeping = false
        generation &+= 1
        baselineChangeCount = pasteboard.changeCount
        do {
            try store.applyCleanupNow()
            lastCleanupAt = Date()
        } catch {
            fail(error.localizedDescription)
            return
        }
        guard preparePasteboardAccess() else {
            return
        }
        updateRuntime(.running, text: "正在观察剪贴板变化")
        startPollingTask(generation: generation)
    }

    func stop() {
        let wasActive = isActive || pollingTask != nil
        isActive = false
        generation &+= 1
        pollingTask?.cancel()
        pollingTask = nil
        guard wasActive else {
            updateRuntime(.off, text: "已关闭")
            return
        }
        updateRuntime(.off, text: "已关闭")
    }

    func retry() {
        guard isActive else {
            start()
            return
        }
        guard preparePasteboardAccess() else {
            return
        }
        baselineChangeCount = pasteboard.changeCount
        updateRuntime(.running, text: "正在观察剪贴板变化")
        startPollingTask(generation: generation)
    }

    func pollNow() async {
        guard isActive, !isSleeping, !isProcessingChange else { return }
        isProcessingChange = true
        defer { isProcessingChange = false }
        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != baselineChangeCount else { return }
        if pasteboard.accessState == .denied {
            fail(ClipboardPasteboardError.readFailed.localizedDescription)
            return
        }
        let frontmost = frontmostApplication()
        do {
            let snapshot = try ClipboardChangeReader.snapshot(
                from: pasteboard,
                frontmostBundleIdentifier: frontmost?.bundleIdentifier,
                frontmostApplicationName: frontmost?.localizedName
            )
            guard pasteboard.changeCount == snapshot.changeCount else {
                // 保留旧基线，让下一轮重新读取最终稳定版本；否则当前
                // 版本的正文可能永远无法被记录。
                return
            }
            baselineChangeCount = snapshot.changeCount
            guard !snapshot.isSelfWrite, !snapshot.isSensitive else { return }
            guard !isBlacklisted(snapshot) else { return }

            let generationAtStart = generation
            let decodeTask = Task.detached(priority: .utility) { [decoder, snapshot] in
                await decoder(snapshot)
            }
            let observed = await withTaskCancellationHandler {
                await decodeTask.value
            } onCancel: {
                decodeTask.cancel()
            }
            guard !Task.isCancelled,
                  isActive,
                  !isSleeping,
                  generation == generationAtStart else {
                return
            }
            for item in observed.items {
                guard !Task.isCancelled,
                      isActive,
                      !isSleeping,
                      generation == generationAtStart else {
                    return
                }
                _ = try await store.addAsync(
                    ClipboardCapture(
                        content: item.content,
                        sourceBundleIdentifier: observed.sourceBundleIdentifier
                            ?? observed.frontmostBundleIdentifier,
                        sourceName: observed.sourceName,
                        contentHash: item.contentHash
                    ),
                    shouldCommit: { [weak self] in
                        guard let self else { return false }
                        return self.isActive
                            && !self.isSleeping
                            && self.generation == generationAtStart
                    }
                )
            }
            updateRuntime(.running, text: "正在观察剪贴板变化")
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func isBlacklisted(_ snapshot: ClipboardPayloadSnapshot) -> Bool {
        let disabled = store.settings.disabledBundleIdentifiers
        guard !disabled.isEmpty else { return false }
        let candidates = [
            snapshot.sourceBundleIdentifier,
            snapshot.frontmostBundleIdentifier,
        ].compactMap { $0 }
        guard !candidates.isEmpty else { return true }
        return candidates.contains { disabled.contains($0) }
    }

    private func startPollingTask(generation: Int) {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, generation == self.generation, isActive {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled, generation == self.generation else { return }
                await pollNow()
                performPeriodicCleanupIfNeeded()
            }
        }
    }

    private func performPeriodicCleanupIfNeeded() {
        let now = Date()
        if let lastCleanupAt,
           now.timeIntervalSince(lastCleanupAt) < 3_600 {
            return
        }
        do {
            try store.applyCleanupNow()
            lastCleanupAt = now
        } catch {
            updateRuntime(.failed(error.localizedDescription), text: error.localizedDescription)
        }
    }

    private func fail(_ reason: String) {
        pollingTask?.cancel()
        pollingTask = nil
        isActive = false
        generation &+= 1
        updateRuntime(.failed(reason), text: reason)
    }

    private func updateRuntime(_ status: ModuleRuntimeStatus, text: String) {
        runtimeStatus = status
        statusText = text
        onRuntimeStatusChange?(status, status == .failed(text) ? text : nil)
    }

    private func observeWorkspace() {
        let center = notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isSleeping = true
                self.generation &+= 1
                self.pollingTask?.cancel()
                self.pollingTask = nil
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.isSleeping = false
                self.generation &+= 1
                self.baselineChangeCount = self.pasteboard.changeCount
                guard self.preparePasteboardAccess() else { return }
                self.startPollingTask(generation: self.generation)
            }
        })
    }

    private func preparePasteboardAccess() -> Bool {
        switch pasteboard.accessState {
        case .denied:
            fail(ClipboardPasteboardError.readFailed.localizedDescription)
            return false
        case .ask:
            do {
                _ = try pasteboard.inspect()
            } catch {
                fail(ClipboardPasteboardError.readFailed.localizedDescription)
                return false
            }
            guard pasteboard.accessState != .ask,
                  pasteboard.accessState != .denied else {
                fail(ClipboardPasteboardError.accessNotGranted.localizedDescription)
                return false
            }
            return true
        case .unknown, .allowed:
            return true
        }
    }
}
