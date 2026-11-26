import AppKit
import ApplicationServices
import Carbon
import Observation
import SwiftUI

struct ShortcutConflictApplication: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let name: String
    let applicationURL: URL?
}

struct ShortcutConflictMatch: Identifiable, Equatable, Sendable {
    let id: String
    let applicationIdentifier: String
    let applicationName: String
    let bundleIdentifier: String?
    let applicationURL: URL?
    let menuPath: [String]
    let shortcut: ShortcutKey

    var functionName: String {
        menuPath.joined(separator: " › ")
    }
}

struct ShortcutConflictReport: Sendable {
    let matches: [ShortcutConflictMatch]
    let scannedApplicationCount: Int
    let permissionRequired: Bool
    let globalShortcutOccupied: Bool
}

enum ShortcutConflictMenuScanner {
    static func scan(
        applications: [ShortcutConflictApplication],
        matching shortcut: ShortcutKey
    ) -> [ShortcutConflictMatch] {
        applications.flatMap { application -> [ShortcutConflictMatch] in
            let element = AXUIElementCreateApplication(application.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.25)
            guard let menuBar = menuBarElement(of: element) else { return [] }
            var matches: [ShortcutConflictMatch] = []
            var nodeBudget = 4_000
            walk(
                menuBar,
                path: [],
                application: application,
                shortcut: shortcut,
                depth: 0,
                nodeBudget: &nodeBudget,
                matches: &matches
            )
            return matches
        }
    }

    private static func walk(
        _ element: AXUIElement,
        path: [String],
        application: ShortcutConflictApplication,
        shortcut: ShortcutKey,
        depth: Int,
        nodeBudget: inout Int,
        matches: inout [ShortcutConflictMatch]
    ) {
        guard depth <= 8, nodeBudget > 0 else { return }
        nodeBudget -= 1

        let role = stringAttribute(element, kAXRoleAttribute)
        var currentPath = path
        if (role == kAXMenuBarItemRole || role == kAXMenuItemRole),
           let title = stringAttribute(element, kAXTitleAttribute)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            currentPath.append(title)
        }

        if role == kAXMenuItemRole,
           isEnabled(element),
           let itemShortcut = ShortcutMenuShortcutResolver.resolve(
               commandCharacter: stringAttribute(element, kAXMenuItemCmdCharAttribute),
               virtualKey: numberAttribute(element, kAXMenuItemCmdVirtualKeyAttribute),
               rawModifiers: numberAttribute(element, kAXMenuItemCmdModifiersAttribute)
           ),
           itemShortcut == shortcut {
            let path = currentPath.isEmpty
                ? [L10n.shared.string("未命名菜单项")]
                : currentPath
            let applicationID = application.bundleIdentifier
                ?? "pid.\(application.processIdentifier)"
            matches.append(ShortcutConflictMatch(
                id: "\(applicationID)|\(path.joined(separator: "›"))|\(shortcut.keyCode)|\(shortcut.modifiers.rawValue)",
                applicationIdentifier: applicationID,
                applicationName: application.name,
                bundleIdentifier: application.bundleIdentifier,
                applicationURL: application.applicationURL,
                menuPath: path,
                shortcut: itemShortcut
            ))
        }

        for child in children(of: element) {
            walk(
                child,
                path: currentPath,
                application: application,
                shortcut: shortcut,
                depth: depth + 1,
                nodeBudget: &nodeBudget,
                matches: &matches
            )
        }
    }

    private static func menuBarElement(of application: AXUIElement) -> AXUIElement? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXMenuBarAttribute as CFString,
            &rawValue
        ) == .success,
        let rawValue,
        CFGetTypeID(rawValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return (rawValue as! AXUIElement)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &rawValue
        ) == .success else {
            return []
        }
        return rawValue as? [AXUIElement] ?? []
    }

    private static func stringAttribute(
        _ element: AXUIElement,
        _ attribute: String
    ) -> String? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &rawValue
        ) == .success else {
            return nil
        }
        return rawValue as? String
    }

    private static func numberAttribute(
        _ element: AXUIElement,
        _ attribute: String
    ) -> Int? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &rawValue
        ) == .success else {
            return nil
        }
        return (rawValue as? NSNumber)?.intValue
    }

    private static func isEnabled(_ element: AXUIElement) -> Bool {
        guard let value = numberAttribute(element, kAXEnabledAttribute) else {
            return true
        }
        return value != 0
    }
}

enum ShortcutMenuShortcutResolver {
    static func resolve(
        commandCharacter: String?,
        virtualKey: Int?,
        rawModifiers: Int?
    ) -> ShortcutKey? {
        let keyCode: UInt32
        if let virtualKey, (0...127).contains(virtualKey) {
            keyCode = UInt32(virtualKey)
        } else if let commandCharacter,
                  let resolved = ShortcutDisplayFormatter.keyCode(
                      for: commandCharacter
                  ) {
            keyCode = resolved
        } else {
            return nil
        }

        let rawModifiers = rawModifiers ?? 0
        var modifiers: ShortcutModifiers = []
        if rawModifiers & (1 << 0) != 0 { modifiers.insert(.shift) }
        if rawModifiers & (1 << 1) != 0 { modifiers.insert(.option) }
        if rawModifiers & (1 << 2) != 0 { modifiers.insert(.control) }
        if rawModifiers & (1 << 3) == 0 { modifiers.insert(.command) }
        return ShortcutKey(keyCode: keyCode, modifiers: modifiers)
    }
}

@MainActor
enum ShortcutOccupancyProbe {
    static func isOccupied(_ shortcut: ShortcutKey) -> Bool {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            carbonModifiers(shortcut.modifiers),
            EventHotKeyID(signature: 0x4E594C43, id: 0xFFFF),
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &reference
        )
        if status == noErr {
            if let reference {
                UnregisterEventHotKey(reference)
            }
            return false
        }
        return status == OSStatus(eventHotKeyExistsErr)
    }

    private static func carbonModifiers(
        _ modifiers: ShortcutModifiers
    ) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}

@MainActor
final class ShortcutConflictInspector {
    private let sender = CGEventGestureShortcutSender()

    func observeResponse(to shortcut: ShortcutKey) async -> [ShortcutConflictMatch]? {
        let initialWindows = visibleWindows()
        let initialFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard sender.send(shortcut) else { return nil }

        var responses: [pid_t: String] = [:]
        for _ in 0..<10 {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return []
            }
            if let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier,
               frontmost != initialFrontmost, responses[frontmost] == nil {
                responses[frontmost] = L10n.shared.string("触发后切到前台")
            }
            for (windowID, owner) in visibleWindows() where initialWindows[windowID] != owner {
                responses[owner] = L10n.shared.string("触发后出现新窗口")
            }
        }
        return responses.compactMap { processIdentifier, evidence in
            guard processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let app = NSRunningApplication(processIdentifier: processIdentifier) else { return nil }
            let identifier = app.bundleIdentifier ?? "pid.\(processIdentifier)"
            return ShortcutConflictMatch(
                id: "observed|\(processIdentifier)",
                applicationIdentifier: identifier,
                applicationName: app.localizedName ?? identifier,
                bundleIdentifier: app.bundleIdentifier,
                applicationURL: app.bundleURL,
                menuPath: [evidence],
                shortcut: shortcut
            )
        }
    }

    private func visibleWindows() -> [CGWindowID: pid_t] {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [:] }
        var result: [CGWindowID: pid_t] = [:]
        for window in windows {
            guard let windowID = window[kCGWindowNumber as String] as? NSNumber,
                  let owner = window[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            result[windowID.uint32Value] = owner.int32Value
        }
        return result
    }

    func inspect(
        shortcut: ShortcutKey,
        ownMatches: [ShortcutConflictMatch],
        globalShortcutOccupied: Bool
    ) async -> ShortcutConflictReport {
        guard AccessibilityPermission.isGranted else {
            return ShortcutConflictReport(
                matches: ownMatches,
                scannedApplicationCount: 0,
                permissionRequired: true,
                globalShortcutOccupied: globalShortcutOccupied
            )
        }

        let applications = runningApplications()
        let scanned = await Task.detached(priority: .userInitiated) {
            ShortcutConflictMenuScanner.scan(
                applications: applications,
                matching: shortcut
            )
        }.value

        var seen = Set<String>()
        let matches = (ownMatches + scanned).filter {
            seen.insert($0.id).inserted
        }.sorted {
            if $0.applicationName == $1.applicationName {
                return $0.functionName < $1.functionName
            }
            return $0.applicationName.localizedStandardCompare(
                $1.applicationName
            ) == .orderedAscending
        }
        return ShortcutConflictReport(
            matches: matches,
            scannedApplicationCount: applications.count,
            permissionRequired: false,
            globalShortcutOccupied: globalShortcutOccupied
        )
    }

    private func runningApplications() -> [ShortcutConflictApplication] {
        NSWorkspace.shared.runningApplications.compactMap { application in
            guard application.activationPolicy == .regular,
                  !application.isTerminated else {
                return nil
            }
            return ShortcutConflictApplication(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                name: application.localizedName
                    ?? application.bundleIdentifier
                    ?? L10n.shared.string("未命名应用"),
                applicationURL: application.bundleURL
            )
        }
    }
}

@MainActor
@Observable
final class ShortcutConflictCheckerModel {
    var shortcut: ShortcutKey?
    var isRecording = false
    var isSearching = false
    var hasSearched = false
    var matches: [ShortcutConflictMatch] = []
    var scannedApplicationCount = 0
    var permissionRequired = false
    var globalShortcutOccupied = false
    var message: String?
    var errorMessage: String?

    private let beginInterception: () throws -> Void
    private let endInterception: () -> Void
    private let ownShortcuts: () -> [ShortcutConflictMatch]
    private let inspector = ShortcutConflictInspector()
    private var searchTask: Task<Void, Never>?

    init(
        beginInterception: @escaping () throws -> Void,
        endInterception: @escaping () -> Void,
        ownShortcuts: @escaping () -> [ShortcutConflictMatch] = { [] }
    ) {
        self.beginInterception = beginInterception
        self.endInterception = endInterception
        self.ownShortcuts = ownShortcuts
    }

    func beginRecording() -> Bool {
        guard !isSearching else { return false }
        guard !isRecording else { return true }
        do {
            try beginInterception()
            isRecording = true
            message = nil
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func capture(_ shortcut: ShortcutKey) {
        clear()
        self.shortcut = shortcut
    }

    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        endInterception()
    }

    func clear() {
        cancelRecording()
        searchTask?.cancel()
        searchTask = nil
        shortcut = nil
        isSearching = false
        hasSearched = false
        matches = []
        scannedApplicationCount = 0
        permissionRequired = false
        globalShortcutOccupied = false
        message = nil
        errorMessage = nil
    }

    func stop() {
        cancelRecording()
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    func startCheck() {
        guard let shortcut, !isRecording, !isSearching else { return }
        isSearching = true
        hasSearched = true
        matches = []
        scannedApplicationCount = 0
        permissionRequired = false
        globalShortcutOccupied = false
        message = nil
        errorMessage = nil
        let ownMatches = ownShortcuts().filter { $0.shortcut == shortcut }
        searchTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let occupied = ownMatches.isEmpty && ShortcutOccupancyProbe.isOccupied(shortcut)
            let observed = await inspector.observeResponse(to: shortcut)
            guard !Task.isCancelled else { return }
            if observed == nil {
                errorMessage = L10n.shared.string("未能发送快捷键，请检查辅助功能权限。仍会检查菜单和全局占用。")
            }
            let report = await inspector.inspect(
                shortcut: shortcut,
                ownMatches: ownMatches + (observed ?? []),
                globalShortcutOccupied: occupied
            )
            guard !Task.isCancelled else { return }
            matches = report.matches
            scannedApplicationCount = report.scannedApplicationCount
            permissionRequired = report.permissionRequired
            self.globalShortcutOccupied = report.globalShortcutOccupied
            isSearching = false
            searchTask = nil
        }
    }
}

private struct ShortcutConflictApplicationGroup: Identifiable {
    let id: String
    let name: String
    let bundleIdentifier: String?
    let applicationURL: URL?
    let matches: [ShortcutConflictMatch]

    static func groups(
        from matches: [ShortcutConflictMatch]
    ) -> [ShortcutConflictApplicationGroup] {
        var order: [String] = []
        var grouped: [String: [ShortcutConflictMatch]] = [:]
        for match in matches {
            if grouped[match.applicationIdentifier] == nil {
                order.append(match.applicationIdentifier)
            }
            grouped[match.applicationIdentifier, default: []].append(match)
        }
        return order.compactMap { identifier in
            guard let matches = grouped[identifier],
                  let first = matches.first else {
                return nil
            }
            return ShortcutConflictApplicationGroup(
                id: identifier,
                name: first.applicationName,
                bundleIdentifier: first.bundleIdentifier,
                applicationURL: first.applicationURL,
                matches: matches
            )
        }
    }
}

struct ShortcutConflictCheckerView: View {
    @Bindable var model: ShortcutConflictCheckerModel
    @Environment(\.colorScheme) private var colorScheme
    private var theme: SettingsTheme { SettingsTheme(colorScheme: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            recorderCard
            results
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(width: 620, height: 540)
        .background(theme.page)
        .tint(NylaiPalette.accent)
        .onDisappear {
            model.stop()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(theme.selected)
                .frame(width: 42, height: 42)
                .overlay {
                    Image(systemName: "keyboard")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(NylaiPalette.accent)
                }
            VStack(alignment: .leading, spacing: 5) {
                Text("快捷键占用检查")
                    .font(.system(size: 18, weight: .semibold))
                Text("录入时不会触发原功能。点击「开始检查」会发送一次快捷键并观察应用响应。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var recorderCard: some View {
        HStack(spacing: 12) {
            ShortcutRecorder(
                shortcut: model.shortcut,
                isRecording: model.isRecording,
                onBegin: { model.beginRecording() },
                onCapture: { model.capture($0) },
                onCancel: { model.cancelRecording() },
                onClear: { model.clear() },
                onMessage: { model.message = $0 },
                idleTitle: L10n.shared.string("录入快捷键")
            )
            .frame(width: 148, height: 34)
            .focusEffectDisabled()

            VStack(alignment: .leading, spacing: 3) {
                if let message = model.message {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                } else {
                    Text("点击后录入，按 Esc 取消。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Text(L10n.shared.string(
                    "会临时暂停 %@ 自己的全局快捷键。",
                    AppName.current
                ))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Button("开始检查") {
                model.startCheck()
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.shortcut == nil || model.isRecording || model.isSearching)
            if model.shortcut != nil {
                Button("清除") {
                    model.clear()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var results: some View {
        if !model.hasSearched, model.shortcut != nil {
            emptyState(
                icon: "magnifyingglass",
                title: "已录入快捷键",
                detail: "点击「开始检查」以触发一次。"
            )
        } else if !model.hasSearched {
            emptyState(
                icon: "magnifyingglass",
                title: "等待录入快捷键",
                detail: "检查会读取运行中应用的菜单快捷键。"
            )
        } else if model.isSearching {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("正在检查运行中的应用…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
        } else if model.permissionRequired {
            VStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                Text("需要辅助功能权限")
                    .font(.system(size: 13, weight: .semibold))
                Text("读取其他应用的菜单快捷键需要辅助功能授权。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("请求权限") {
                        _ = AccessibilityPermission.requestIfNeeded()
                    }
                    Button("打开系统设置…") {
                        _ = AccessibilityPermission.openSystemSettings()
                    }
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
        } else if model.matches.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: model.globalShortcutOccupied
                      ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(model.globalShortcutOccupied
                                     ? AnyShapeStyle(.orange)
                                     : AnyShapeStyle(NylaiPalette.accent))
                Text(model.globalShortcutOccupied
                     ? "已被系统或其他应用占用"
                     : "未发现菜单快捷键占用")
                    .font(.system(size: 13, weight: .semibold))
                Text(model.globalShortcutOccupied
                     ? "macOS 未公开这个系统级快捷键的占用方。"
                     : L10n.shared.string(
                         "已检查 %d 个运行中的应用。",
                         model.scannedApplicationCount
                     ))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(L10n.shared.string("%d 个应用", applicationCount))
                        .font(.system(size: 12, weight: .semibold))
                    Text(L10n.shared.string(
                        "· 已检查 %d 个应用",
                        model.scannedApplicationCount
                    ))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if model.globalShortcutOccupied {
                        Text("· 全局占用方未经系统确认")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                }
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(ShortcutConflictApplicationGroup.groups(
                            from: model.matches
                        )) { group in
                            applicationGroup(group)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(maxHeight: 250)
        }
    }

    private var applicationCount: Int {
        Set(model.matches.map(\.applicationIdentifier)).count
    }

    private func applicationGroup(
        _ group: ShortcutConflictApplicationGroup
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                ShortcutConflictApplicationIcon(group: group)
                Text(group.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(L10n.shared.string("%d 项", group.matches.count))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider().opacity(0.55)

            ForEach(Array(group.matches.enumerated()), id: \.element.id) { index, match in
                HStack(spacing: 10) {
                    Text(match.functionName)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(match.functionName)
                    Spacer(minLength: 8)
                    ShortcutKeycaps(shortcut: match.shortcut)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)

                if index < group.matches.count - 1 {
                    Divider()
                        .opacity(0.4)
                        .padding(.leading, 12)
                }
            }
        }
        .background(theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }

    private func emptyState(
        icon: String,
        title: String,
        detail: String
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private var footer: some View {
        Text("按键后的窗口或前台变化仅供定位参考。没有可见响应时，可能查不到全局占用方。")
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ShortcutConflictApplicationIcon: View {
    let group: ShortcutConflictApplicationGroup

    var body: some View {
        Group {
            if let url = resolvedURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "app")
                    .resizable()
                    .scaledToFit()
                    .padding(4)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 22, height: 22)
    }

    private var resolvedURL: URL? {
        if let applicationURL = group.applicationURL {
            return applicationURL
        }
        guard let identifier = group.bundleIdentifier else { return nil }
        return NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: identifier
        )
    }
}

@MainActor
final class ShortcutConflictCheckerWindowController: NSWindowController, NSWindowDelegate {
    private let model: ShortcutConflictCheckerModel

    init(
        beginInterception: @escaping () throws -> Void,
        endInterception: @escaping () -> Void,
        ownShortcuts: @escaping () -> [ShortcutConflictMatch] = { [] }
    ) {
        model = ShortcutConflictCheckerModel(
            beginInterception: beginInterception,
            endInterception: endInterception,
            ownShortcuts: ownShortcuts
        )
        let hostingController = NSHostingController(
            rootView: ShortcutConflictCheckerView(model: model)
                .nylaiLocalized()
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = L10n.shared.string("快捷键占用检查")
        window.styleMask = [.titled, .closable]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = NylaiTheme.panelBackground()
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从归档创建快捷键检查窗口")
    }

    func present(relativeTo parent: NSWindow?) {
        guard let window else { return }
        if !window.isVisible {
            if let parent {
                window.setFrameOrigin(NSPoint(
                    x: parent.frame.midX - window.frame.width / 2,
                    y: parent.frame.midY - window.frame.height / 2
                ))
            } else {
                window.center()
            }
        }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func refreshLocalization() {
        window?.title = L10n.shared.string("快捷键占用检查")
    }

    func windowDidResignKey(_ notification: Notification) {
        model.cancelRecording()
    }

    func windowWillClose(_ notification: Notification) {
        model.clear()
    }
}
