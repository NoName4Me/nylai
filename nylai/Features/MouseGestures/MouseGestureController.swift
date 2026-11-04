import AppKit
import Observation
import OSLog

@MainActor
@Observable
final class MouseGestureController {
    private let logger = Logger(subsystem: "com.noname4me.nylai", category: "MouseGestures")
    private struct ActiveSession {
        let revision: Int
        let targetBundleIdentifier: String
        let targetProcessIdentifier: pid_t
        let configuration: MouseGestureConfiguration
        var recognizer: GesturePathRecognizer
        var lastPoint: CGPoint
        var tracePoints: [CGPoint]
    }

    private let store: MouseGestureConfigurationStore
    private let eventMonitor: any MouseGestureEventMonitoring
    private let shortcutSender: any GestureShortcutSending
    private let isInputAccessGranted: () -> Bool
    private let requestInputAccess: () -> Bool
    private let performNylaiAction: (ShortcutAction) -> Void
    private let isNylaiActionAvailable: (ShortcutAction) -> Bool
    private let isInputSuppressed: @MainActor () -> Bool
    private let presentError: @MainActor (Error) -> Void
    private let frontmostApplication: @MainActor () -> GestureFrontmostApplication?
    private let notificationCenter: NotificationCenter
    private let traceWindow = MouseGestureTraceWindow()
    private var isActive = false
    private var isEditingRule = false
    private var session: ActiveSession?
    private var sessionRevision = 0
    private var workspaceObservers: [NSObjectProtocol] = []
    var onRuntimeStatusChange: ((ModuleRuntimeStatus, String?) -> Void)?

    private(set) var configuration: MouseGestureConfiguration?
    private(set) var loadError: String?
    private(set) var runtimeStatus: ModuleRuntimeStatus = .off
    private(set) var statusText = "已关闭"
    private(set) var monitorRunning = false

    init(
        store: MouseGestureConfigurationStore = MouseGestureConfigurationStore(
            fileURL: MouseGestureConfigurationStore.standardFileURL()
        ),
        eventMonitor: any MouseGestureEventMonitoring = CGEventTapMouseGestureMonitor(),
        shortcutSender: any GestureShortcutSending = CGEventGestureShortcutSender(),
        isInputAccessGranted: @escaping () -> Bool = {
            MouseGestureInputAccess.isTrusted
        },
        requestInputAccess: @escaping () -> Bool = {
            MouseGestureInputAccess.requestIfNeeded()
        },
        performNylaiAction: @escaping (ShortcutAction) -> Void,
        isNylaiActionAvailable: @escaping (ShortcutAction) -> Bool,
        isInputSuppressed: @escaping @MainActor () -> Bool = { false },
        frontmostApplication: @escaping @MainActor () -> GestureFrontmostApplication? = {
            NSWorkspace.shared.frontmostApplication.map {
                GestureFrontmostApplication(
                    bundleIdentifier: $0.bundleIdentifier,
                    processIdentifier: $0.processIdentifier
                )
            }
        },
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        presentError: @escaping @MainActor (Error) -> Void = ScreenshotErrorPresenter.show
    ) {
        self.store = store
        self.eventMonitor = eventMonitor
        self.shortcutSender = shortcutSender
        self.isInputAccessGranted = isInputAccessGranted
        self.requestInputAccess = requestInputAccess
        self.performNylaiAction = performNylaiAction
        self.isNylaiActionAvailable = isNylaiActionAvailable
        self.isInputSuppressed = isInputSuppressed
        self.frontmostApplication = frontmostApplication
        self.notificationCenter = notificationCenter
        self.presentError = presentError
        observeWorkspace()
    }

    isolated deinit {
        for observer in workspaceObservers {
            notificationCenter.removeObserver(observer)
        }
    }

    func start(requestPermission: Bool) {
        guard !isActive else { return }
        isActive = true
        guard loadConfigurationIfNeeded() else { return }
        if requestPermission, hasEffectiveRules {
            let inputTrusted = ensureInputAccess()
            if inputTrusted, hasEffectiveShortcutRule {
                _ = shortcutSender.requestAccess()
            }
        }
        ensureMonitorState()
    }

    func stop() {
        let wasActive = isActive || session != nil || eventMonitor.isRunning
        isActive = false
        invalidateSession()
        traceWindow.clear()
        eventMonitor.stop()
        monitorRunning = false
        guard wasActive else {
            updateRuntime(.off, text: "已关闭")
            return
        }
        updateRuntime(.off, text: "已关闭")
    }

    func setShowsTrace(_ value: Bool) throws {
        try updateConfiguration { configuration in
            configuration.showsTrace = value
        }
    }

    func addRule(_ rule: MouseGestureRule) throws {
        try validate(rule, excluding: nil)
        try updateConfiguration { configuration in
            configuration.rules.append(rule)
        }
    }

    func updateRule(_ rule: MouseGestureRule) throws {
        try validate(rule, excluding: rule.id)
        try updateConfiguration { configuration in
            guard let index = configuration.rules.firstIndex(where: { $0.id == rule.id }) else {
                throw MouseGestureConfigurationError.ruleNotFound
            }
            configuration.rules[index] = rule
        }
    }

    func removeRule(_ id: UUID) throws {
        try updateConfiguration { configuration in
            guard configuration.rules.contains(where: { $0.id == id }) else {
                throw MouseGestureConfigurationError.ruleNotFound
            }
            configuration.rules.removeAll { $0.id == id }
        }
    }

    func setRuleEnabled(_ enabled: Bool, id: UUID) throws {
        try updateConfiguration { configuration in
            guard let index = configuration.rules.firstIndex(where: { $0.id == id }) else {
                throw MouseGestureConfigurationError.ruleNotFound
            }
            configuration.rules[index].isEnabled = enabled
        }
    }

    func setApplicationDisabled(_ disabled: Bool, bundleIdentifier: String) throws {
        guard !bundleIdentifier.isEmpty else { return }
        try updateConfiguration { configuration in
            if disabled {
                configuration.disabledBundleIdentifiers.insert(bundleIdentifier)
            } else {
                configuration.disabledBundleIdentifiers.remove(bundleIdentifier)
            }
        }
    }

    func isApplicationDisabled(_ bundleIdentifier: String) -> Bool {
        configuration?.disabledBundleIdentifiers.contains(bundleIdentifier) ?? false
    }

    func retry() {
        guard isActive else {
            start(requestPermission: true)
            return
        }
        guard loadConfigurationIfNeeded() else { return }
        if hasEffectiveRules {
            let inputTrusted = ensureInputAccess()
            if inputTrusted, hasEffectiveShortcutRule {
                _ = shortcutSender.requestAccess()
            }
        }
        ensureMonitorState()
    }

    private func ensureInputAccess() -> Bool {
        if isInputAccessGranted() {
            return true
        }
        _ = requestInputAccess()
        return isInputAccessGranted()
    }

    func cancelCurrentSession() {
        cancelSession()
    }

    func setRuleEditing(_ isEditing: Bool) {
        isEditingRule = isEditing
        if isEditing { cancelSession() }
    }

    func refreshActionAvailability() {
        ensureMonitorState()
    }

    func useNewEmptyConfiguration() throws {
        let fileURL = store.fileURL
        do {
            if FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
                let backupURL = fileURL.deletingLastPathComponent().appending(
                    path: "mouse-gestures.corrupt-\(UUID().uuidString).json"
                )
                try FileManager.default.copyItem(at: fileURL, to: backupURL)
            }
            try store.save(.defaults)
            configuration = .defaults
            loadError = nil
            ensureMonitorState()
        } catch {
            loadError = error.localizedDescription
            throw error
        }
    }

    private func validate(_ rule: MouseGestureRule, excluding id: UUID?) throws {
        guard !rule.path.isEmpty else {
            throw MouseGestureConfigurationError.emptyPath
        }
        guard rule.path.directions.count <= 4 else {
            throw MouseGestureConfigurationError.tooManyDirections
        }
        if configuration?.rules.contains(where: {
            $0.id != id
                && $0.scopeBundleIdentifier == rule.scopeBundleIdentifier
                && $0.path == rule.path
        }) == true {
            throw MouseGestureConfigurationError.duplicatePath
        }
    }

    private func loadConfigurationIfNeeded() -> Bool {
        guard configuration == nil else { return true }
        do {
            configuration = try store.loadOrCreateDefaults()
            loadError = nil
            return true
        } catch {
            loadError = error.localizedDescription
            updateRuntime(.failed(error.localizedDescription), text: error.localizedDescription)
            return false
        }
    }

    private func updateConfiguration(
        _ mutation: (inout MouseGestureConfiguration) throws -> Void
    ) throws {
        var updated = configuration ?? .defaults
        try mutation(&updated)
        do {
            try store.save(updated)
            configuration = updated
            loadError = nil
            ensureMonitorState()
        } catch {
            loadError = error.localizedDescription
            throw error
        }
    }

    private func ensureMonitorState() {
        guard isActive, let configuration else {
            eventMonitor.stop()
            monitorRunning = false
            return
        }
        guard hasEffectiveRules else {
            cancelSession()
            eventMonitor.stop()
            monitorRunning = false
            updateRuntime(.available, text: "已开启，尚无可用规则")
            return
        }
        if eventMonitor.isRunning {
            monitorRunning = true
            updateRuntime(.running, text: "运行中 · \(configuration.rules.count) 条规则")
            return
        }
        do {
            try eventMonitor.start(
                handler: { [weak self] input in
                    self?.handle(input) ?? false
                },
                onFailure: { [weak self] reason in
                    self?.monitorFailed(reason)
                }
            )
            monitorRunning = true
            updateRuntime(.running, text: "运行中 · \(configuration.rules.count) 条规则")
        } catch {
            monitorRunning = false
            updateRuntime(.failed(error.localizedDescription), text: error.localizedDescription)
        }
    }

    private func handle(_ input: MouseGestureInput) -> Bool {
        if isEditingRule || isInputSuppressed() {
            cancelSession()
            return false
        }
        switch input {
        case .rightMouseDown(let point):
            return beginSession(at: point)
        case .rightMouseDragged(let point):
            return updateSession(at: point)
        case .rightMouseUp(let point):
            return endSession(at: point)
        case .escape:
            guard session != nil else { return false }
            cancelSession()
            return true
        case .tapTimedOut:
            cancelSession()
            updateRuntime(.running, text: "监听已恢复，请重新绘制手势")
            return false
        }
    }

    private func beginSession(at point: CGPoint) -> Bool {
        guard !isInputSuppressed(),
              session == nil,
              let configuration,
              let application = frontmostApplication(),
              let bundleIdentifier = application.bundleIdentifier else {
            return false
        }
        let resolver = GestureRuleResolver(
            configuration: configuration,
            applicationBundleIdentifier: bundleIdentifier,
            isActionAvailable: isGestureActionAvailable
        )
        guard resolver.hasEffectiveRules(for: bundleIdentifier) else {
            return false
        }
        sessionRevision &+= 1
        var recognizer = GesturePathRecognizer()
        recognizer.begin(at: point)
        session = ActiveSession(
            revision: sessionRevision,
            targetBundleIdentifier: bundleIdentifier,
            targetProcessIdentifier: application.processIdentifier,
            configuration: configuration,
            recognizer: recognizer,
            lastPoint: point,
            tracePoints: [point]
        )
        updateTrace()
        return true
    }

    private func updateSession(at point: CGPoint) -> Bool {
        guard !isInputSuppressed(), var session else {
            cancelSession()
            return false
        }
        _ = session.recognizer.move(to: point)
        session.lastPoint = point
        if session.tracePoints.last != point {
            session.tracePoints.append(point)
        }
        self.session = session
        updateTrace()
        return true
    }

    private func endSession(at point: CGPoint) -> Bool {
        guard var session else { return false }
        _ = session.recognizer.move(to: point)
        if session.tracePoints.last != point {
            session.tracePoints.append(point)
        }
        self.session = nil
        traceWindow.clear()

        guard let path = session.recognizer.recognizedPath() else {
            if session.recognizer.hasEnteredGesture {
                return true
            }
            eventMonitor.restoreRightClick(at: point)
            return true
        }
        let resolver = GestureRuleResolver(
            configuration: session.configuration,
            applicationBundleIdentifier: session.targetBundleIdentifier,
            isActionAvailable: isGestureActionAvailable
        )
        switch resolver.resolve(path) {
        case .passThrough:
            eventMonitor.restoreRightClick(at: point)
        case .consumedWithoutMatch:
            logger.info("Gesture ended without a matching enabled rule: \(path.display, privacy: .public)")
            break
        case .matched(let rule):
            Task { @MainActor [weak self] in
                guard let self else { return }
                await Task.yield()
                guard self.isActive,
                      self.sessionRevision == session.revision else {
                    return
                }
                self.execute(rule.action, target: session)
            }
        }
        return true
    }

    private func execute(_ action: GestureAction, target: ActiveSession) {
        switch action {
        case .nylai(let action):
            guard isNylaiActionAvailable(action) else { return }
            performNylaiAction(action)
        case .application(let target):
            performNylaiAction(.application(target))
        case .sendShortcut(let shortcut):
            logger.info("Matched gesture shortcut: keyCode=\(shortcut.keyCode, privacy: .public)")
            guard frontmostApplicationMatches(target) else {
                presentError(MouseGestureExecutionError.cannotSendShortcut)
                return
            }
            if !shortcutSender.canSend {
                _ = shortcutSender.requestAccess()
            }
            guard shortcutSender.canSend else {
                presentError(MouseGestureExecutionError.cannotSendShortcut)
                return
            }
            guard shortcutSender.send(shortcut) else {
                presentError(MouseGestureExecutionError.cannotSendShortcut)
                return
            }
            logger.info("Gesture shortcut events posted to macOS")
        }
    }

    private func frontmostApplicationMatches(_ target: ActiveSession) -> Bool {
        guard let application = frontmostApplication() else { return false }
        return application.processIdentifier == target.targetProcessIdentifier
            && application.bundleIdentifier == target.targetBundleIdentifier
    }

    private func cancelSession() {
        guard session != nil else { return }
        invalidateSession()
        traceWindow.clear()
    }

    private func invalidateSession() {
        sessionRevision &+= 1
        session = nil
    }

    private func updateTrace() {
        guard let session, configuration?.showsTrace == true else {
            traceWindow.clear()
            return
        }
        traceWindow.update(
            points: session.tracePoints,
            destination: session.lastPoint,
            isCancelled: false
        )
    }

    private func isGestureActionAvailable(_ action: GestureAction) -> Bool {
        switch action {
        case .nylai(let action):
            isNylaiActionAvailable(action)
        case .application:
            true
        case .sendShortcut:
            true
        }
    }

    private func monitorFailed(_ reason: String) {
        invalidateSession()
        traceWindow.clear()
        eventMonitor.stop()
        monitorRunning = false
        updateRuntime(.failed(reason), text: reason)
    }

    private var hasEffectiveRules: Bool {
        configuration?.rules.contains {
            guard $0.isEnabled, isGestureActionAvailable($0.action) else {
                return false
            }
            guard let scope = $0.scopeBundleIdentifier else { return true }
            return configuration?.disabledBundleIdentifiers.contains(scope) != true
        } ?? false
    }

    private var hasEffectiveShortcutRule: Bool {
        configuration?.rules.contains {
            guard $0.isEnabled, case .sendShortcut = $0.action else { return false }
            if let scope = $0.scopeBundleIdentifier,
               configuration?.disabledBundleIdentifiers.contains(scope) == true {
                return false
            }
            return true
        } ?? false
    }

    private func updateRuntime(_ status: ModuleRuntimeStatus, text: String) {
        runtimeStatus = status
        statusText = text
        onRuntimeStatusChange?(status, status == .failed(text) ? text : nil)
    }

    private func observeWorkspace() {
        let center = notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.cancelSession() }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.cancelSession() }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.ensureMonitorState() }
        })
    }
}

struct GestureFrontmostApplication: Equatable, Sendable {
    let bundleIdentifier: String?
    let processIdentifier: pid_t
}

enum MouseGestureExecutionError: LocalizedError, Equatable {
    case cannotSendShortcut

    var errorDescription: String? {
        "无法向前台应用发送快捷键。请确认系统输入事件权限，并保持原应用在前台。"
    }
}
