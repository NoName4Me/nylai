import AppKit
import ApplicationServices
import Foundation

@MainActor
final class LauncherSources {
    let preferences: LauncherPreferences
    private let isEnabled: (NylaiModuleID) -> Bool
    private let isActionAvailable: (ShortcutAction) -> Bool
    private let perform: (ShortcutAction) -> Void
    private let clipboard: () -> ClipboardHistoryStore?
    private let board: () -> BoardWindowController?
    private let screenshots: ScreenshotHistoryStore
    private let pinImage: (CGImage) -> Void
    var previousApplication: NSRunningApplication?
    var previousFocus: ClipboardFocusSnapshot?
    private var applicationResults: [LauncherResult] = []
    private var clipboardResults: [LauncherResult] = []
    private var screenshotText: [String: String] = [:]
    private var browserResults: [LauncherResult] = []
    private var windowResults: [LauncherResult] = []
    var onIndexChanged: (() -> Void)?

    init(preferences: LauncherPreferences, isEnabled: @escaping (NylaiModuleID) -> Bool,
         isActionAvailable: @escaping (ShortcutAction) -> Bool, perform: @escaping (ShortcutAction) -> Void,
         clipboard: @escaping () -> ClipboardHistoryStore?, board: @escaping () -> BoardWindowController?,
         screenshots: ScreenshotHistoryStore, pinImage: @escaping (CGImage) -> Void) {
        self.preferences = preferences
        self.isEnabled = isEnabled
        self.isActionAvailable = isActionAvailable
        self.perform = perform
        self.clipboard = clipboard
        self.board = board
        self.screenshots = screenshots
        self.pinImage = pinImage
        let url = preferences.directory.appendingPathComponent("screenshot-ocr.json")
        if let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode([String: String].self, from: data) {
            screenshotText = value
        }
    }

    func prepare(target: NSRunningApplication?) {
        previousApplication = target
        previousFocus = ClipboardFocusedElementCapture.capture(processIdentifier: target?.processIdentifier)
        applicationResults = applications()
        clipboardResults = isEnabled(.clipboard) ? clipboardEntries() : []
        browserResults = []
        windowResults = []
        if isEnabled(.screenshot) { screenshots.reload() }
    }

    func release() {
        previousApplication = nil
        previousFocus = nil
        applicationResults = []; clipboardResults = []; browserResults = []; windowResults = []
    }

    func enrich() async {
        let bundles = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let config = preferences.configuration
        async let browsers = LauncherBrowser.records(config: config, runningBundles: bundles)
        if AXIsProcessTrusted(), CGPreflightScreenCaptureAccess(),
           let snapshot = try? await WindowSwitcherCatalogProvider().makeSnapshot(), !Task.isCancelled {
            windowResults = snapshot.applications.flatMap { app in
                app.windows.map { window in
                    let target = WindowSwitcherTarget(processIdentifier: app.id, bundleIdentifier: app.bundleIdentifier,
                        applicationName: app.name, windowID: window.id, windowTitle: window.title, windowFrame: window.frame,
                        applicationURL: app.applicationURL)
                    return LauncherResult(id: "window:\(app.id):\(window.id)", scope: .windows,
                        title: window.title ?? app.name, subtitle: app.name, keywords: app.bundleIdentifier ?? "",
                        priority: 10, actions: [action("activate", "切换窗口", "macwindow") {
                            try await WindowSwitcherActivator().activate(target)
                        }])
                }
            }
            onIndexChanged?()
        }
        let records = await browsers
        guard !Task.isCancelled else { return }
        browserResults = records.map(browserEntry)
        onIndexChanged?()
        guard isEnabled(.screenshot) else { return }
        let valid = Set(screenshots.records.map { $0.id.uuidString })
        screenshotText = screenshotText.filter { valid.contains($0.key) }
        for record in screenshots.records where screenshotText[record.id.uuidString] == nil {
            guard !Task.isCancelled, isEnabled(.screenshot) else { return }
            guard let image = screenshotImage(record) else { continue }
            if let text = try? await ScreenshotTextRecognition.recognize(image, layout: .lines), !Task.isCancelled {
                screenshotText[record.id.uuidString] = text
            } else if !Task.isCancelled { screenshotText[record.id.uuidString] = "" }
            onIndexChanged?()
        }
        guard !Task.isCancelled else { return }
        do {
            try FileManager.default.createDirectory(at: preferences.directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(screenshotText).write(to: preferences.directory.appendingPathComponent("screenshot-ocr.json"), options: .atomic)
        } catch { preferences.error = error.localizedDescription }
    }

    func local(_ query: LauncherQuery) -> [LauncherResult] {
        var output: [LauncherResult] = []
        let scope = query.scope
        func includes(_ value: LauncherScope) -> Bool { scope == .all || scope == value }
        if includes(.applications) { output += applicationResults }
        if includes(.commands) { output += commands(); output += utilityEntries(query.text) }
        if includes(.links) { output += linkEntries(query.text) }
        if includes(.windows) { output += windowResults }
        if includes(.clipboard), isEnabled(.clipboard) { output += clipboardResults }
        if includes(.boards), isEnabled(.board) { output += boardEntries() }
        if includes(.screenshots), isEnabled(.screenshot) { output += screenshotEntries() }
        output += browserResults.filter { includes($0.scope) }
        return output
    }

    func files(_ query: String) async -> [LauncherResult] {
        let urls = await LauncherFileSearch.search(query, roots: preferences.configuration.searchRoots)
        guard !Task.isCancelled else { return [] }
        return urls.map { fileEntry($0, matchedQuery: query) }
    }

    private func action(_ id: String, _ title: String, _ symbol: String, restore: Bool = false,
                        _ run: @escaping @MainActor () async throws -> Void) -> LauncherAction {
        .init(id: id, title: L10n.shared.string(title), symbol: symbol, restoresPreviousApplication: restore, run: run)
    }

    private func copy(_ text: String, title: String = "复制") -> LauncherAction {
        action("copy:\(title)", title, "doc.on.doc", restore: true) {
            try SystemClipboardPasteboard().write(.text(text), sourceBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.noname4me.nylai")
        }
    }

    private func open(_ url: URL) throws {
        guard NSWorkspace.shared.open(url) else { throw LauncherError.unavailable }
    }

    private func applications() -> [LauncherResult] {
        let fm = FileManager.default
        var urls: [URL] = []
        let roots = ["/Applications", "/System/Applications", "/System/Library/CoreServices/Applications",
                     fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        for root in roots {
            guard let iterator = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in iterator {
                if url.pathExtension.lowercased() == "app" { urls.append(url); iterator.skipDescendants() }
            }
        }
        urls += NSWorkspace.shared.runningApplications.compactMap(\.bundleURL)
        var ids = Set<String>()
        return urls.compactMap { url in
            guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier,
                  ids.insert(identifier).inserted else { return nil }
            let name = fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            return LauncherResult(id: "app:\(identifier)", scope: .applications, title: name, subtitle: url.path,
                keywords: identifier, icon: NSWorkspace.shared.icon(forFile: url.path), priority: 45,
                actions: [
                    action("open", "打开 / 切换应用", "arrow.up.right.square") {
                        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first {
                            try await ApplicationActivationService().activate(ApplicationActivationTarget(app))
                        } else {
                            _ = try await WorkspaceApplicationLauncher().openApplication(at: url, activates: true)
                        }
                    },
                    action("reveal", "在访达中显示", "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) },
                    copy(url.path, title: "复制路径")
                ])
        }
    }

    private func commands() -> [LauncherResult] {
        let list: [(String, ShortcutAction, String)] = [
            ("settings", .openSettings, "settings preferences 设置"),
            ("capture", .captureInteractive, "screenshot capture 截屏"),
            ("screenshots", .screenshotHistory, "image recent 截图历史"),
            ("collage", .openCollage, "collage 图片拼接"),
            ("clipboard", .clipboardHistory, "clipboard paste 剪贴板"),
            ("board", .openBoard, "board canvas 白板"),
            ("quick-note", .quickCapture, "note capture 记录")
        ]
        return list.compactMap { key, command, words in
            guard isActionAvailable(command) else { return nil }
            return LauncherResult(id: "cmd:\(key)", scope: .commands, title: ShortcutBindingRuntime.title(for: command),
                subtitle: L10n.shared.string("Nylai 命令"), keywords: words, priority: 35,
                actions: [action("run", "执行", "command", restore: command == .captureInteractive || command == .clipboardHistory) { [weak self] in
                    guard let self, self.isActionAvailable(command) else { throw LauncherError.unavailable }
                    self.perform(command)
                }])
        }
    }

    private func linkEntries(_ query: String) -> [LauncherResult] {
        preferences.configuration.links.map { link in
            let words = query.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            let matched = words.first.map { LauncherRank.folded(String($0)) == LauncherRank.folded(link.alias) } ?? false
            let argument = matched && words.count > 1 ? String(words[1]) : ""
            return LauncherResult(id: "link:\(link.id)", scope: .links, title: link.title, subtitle: link.target,
                keywords: link.alias + (matched ? " " + query : ""), priority: matched ? 200 : 30,
                actions: [action("open", "打开", "link") { [weak self] in
                    guard let self, let url = link.resolve(argument: argument) else { throw LauncherError.invalidLink }
                    try self.open(url)
                }, copy(link.target, title: "复制链接")])
        }
    }

    private func fileEntry(_ url: URL, matchedQuery: String) -> LauncherResult {
        let path = url.path
        let folder = url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        return LauncherResult(id: "file:\(path)", scope: .files, title: url.lastPathComponent, subtitle: path,
            keywords: matchedQuery, symbol: folder ? "folder" : "doc",
            actions: [
                action("open", "打开", "arrow.up.right.square") { [weak self] in try self?.open(url) },
                action("reveal", "在访达中显示", "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) },
                action("preview", "快速预览", "eye") {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
                    process.arguments = ["-p", path]
                    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                    try process.run()
                },
                action("terminal", "在终端打开", "terminal") {
                    guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { throw LauncherError.unavailable }
                    let target = folder ? url : url.deletingLastPathComponent()
                    _ = try await NSWorkspace.shared.open([target], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
                },
                copy(path, title: "复制路径")
            ])
    }

    private func clipboardEntries() -> [LauncherResult] {
        guard let store = clipboard() else { return [] }
        return store.allRecords.map { record in
            let text = record.kind == .text ? store.text(for: record) ?? "" : ""
            let title = record.kind == .image ? L10n.shared.string("图片") : String(text.prefix(140)).replacingOccurrences(of: "\n", with: " ")
            var actions = [
                action("copy", "复制", "doc.on.doc", restore: true) {
                    guard let content = store.content(for: record) else { throw LauncherError.clipboardUnavailable }
                    try SystemClipboardPasteboard().write(content, sourceBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.noname4me.nylai")
                },
                action("paste", "粘贴到原应用", "doc.on.clipboard") { [weak self] in
                    guard let self, let target = self.previousApplication, let bundle = target.bundleIdentifier,
                          let content = store.content(for: record) else { throw LauncherError.clipboardUnavailable }
                    let pasteboard = SystemClipboardPasteboard()
                    try pasteboard.write(content, sourceBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.noname4me.nylai")
                    try await SystemClipboardDirectPaster().pasteAfterActivating(target: target, expectedBundleIdentifier: bundle,
                        expectedChangeCount: pasteboard.changeCount, pasteboard: pasteboard, focusSnapshot: self.previousFocus).get()
                }
            ]
            if isEnabled(.board) {
                actions.append(action("board", "发送到画布", "note.text") { [weak self] in
                    guard let content = store.content(for: record), let controller = self?.board() else { throw LauncherError.unavailable }
                    controller.chooseDestination(for: [content])
                })
            }
            return LauncherResult(id: "clip:\(record.id)", scope: .clipboard, title: title,
                subtitle: (record.sourceName ?? "") + " · " + record.copiedAt.formatted(date: .abbreviated, time: .shortened),
                keywords: String(text.prefix(32_768)), symbol: record.kind == .image ? "photo" : "doc.on.clipboard",
                priority: record.isPinned ? 10 : 0, actions: actions)
        }
    }

    private func boardEntries() -> [LauncherResult] {
        guard let controller = board(), controller.store.loadError == nil else { return [] }
        return controller.store.library.boards.flatMap { document in
            let main = LauncherResult(id: "board:\(document.id)", scope: .boards, title: document.title,
                subtitle: L10n.shared.string("无限画布"), priority: 20,
                actions: [action("open", "打开画布", "note.text") { controller.present(boardID: document.id) }])
            let items = document.items.compactMap { item -> LauncherResult? in
                guard item.kind == .note || item.kind == .image else { return nil }
                let title = item.kind == .image ? L10n.shared.string("图片") + " " + String(item.recognizedText.prefix(100))
                    : String(item.text.prefix(140)).replacingOccurrences(of: "\n", with: " ")
                var actions = [action("locate", "定位到画布", "scope") { controller.present(boardID: document.id, itemID: item.id) }]
                if item.kind == .note { actions.append(copy(item.text)) }
                else if let asset = item.asset {
                    actions.append(action("copy", "复制图片", "doc.on.doc", restore: true) {
                        guard let image = controller.store.image(asset) else { throw LauncherError.unavailable }
                        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image])
                    })
                    if !item.recognizedText.isEmpty { actions.append(copy(item.recognizedText, title: "复制识别文字")) }
                }
                return LauncherResult(id: "board:\(document.id):\(item.id)", scope: .boards, title: title,
                    subtitle: document.title, keywords: item.searchableText, symbol: item.kind == .note ? "note.text" : "photo",
                    actions: actions)
            }
            return [main] + items
        }
    }

    private func screenshotImage(_ record: ScreenshotHistoryRecord) -> CGImage? {
        guard let image = screenshots.image(for: record) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private func screenshotEntries() -> [LauncherResult] {
        screenshots.records.map { record in
            let text = screenshotText[record.id.uuidString] ?? ""
            var actions = [action("preview", "预览截图", "eye") { [weak self] in
                guard let self, let image = self.screenshotImage(record) else { throw LauncherError.unavailable }
                self.pinImage(image)
            }, action("copy", "复制图片", "doc.on.doc", restore: true) { [weak self] in
                guard let image = self?.screenshotImage(record) else { throw LauncherError.unavailable }
                try SystemClipboardPasteboard().write(.image(image), sourceBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.noname4me.nylai")
            }]
            if !text.isEmpty { actions.append(copy(text, title: "复制识别文字")) }
            if isEnabled(.board) {
                actions.append(action("board", "发送到画布", "note.text") { [weak self] in
                    guard let self, let image = self.screenshotImage(record), let controller = self.board() else { throw LauncherError.unavailable }
                    controller.chooseDestination(for: [.image(image)])
                })
            }
            return LauncherResult(id: "img:\(record.id)", scope: .screenshots,
                title: text.isEmpty ? L10n.shared.string("截图") : String(text.prefix(120)).replacingOccurrences(of: "\n", with: " "),
                subtitle: record.createdAt.formatted(date: .abbreviated, time: .shortened), keywords: text,
                symbol: "photo", preview: screenshots.thumbnail(for: record), actions: actions)
        }
    }

    private func browserEntry(_ record: LauncherBrowserRecord) -> LauncherResult {
        var actions = [action("open", record.scope == .tabs ? "切换标签页" : "打开链接", "globe") { [weak self] in
            if record.scope == .tabs { try await LauncherBrowser.activate(record) }
            else {
                guard let self, let url = URL(string: record.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw LauncherError.invalidLink }
                try self.open(url)
            }
        }, copy(record.url, title: "复制链接"), copy(record.title + "\n" + record.url, title: "复制标题与链接")]
        if isEnabled(.board) {
            actions.append(action("board", "发送到画布", "note.text") { [weak self] in
                guard let controller = self?.board() else { throw LauncherError.unavailable }
                controller.chooseDestination(for: [.text(record.title + "\n" + record.url)])
            })
        }
        return .init(id: record.id, scope: record.scope, title: record.title.isEmpty ? record.url : record.title,
                     subtitle: record.browser + " · " + record.url, keywords: record.url, actions: actions)
    }

    private func utilityEntries(_ query: String) -> [LauncherResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = q.lowercased()
        var result: [LauncherResult] = []
        if let value = LauncherCalculation.evaluate(q) ?? LauncherCalculation.convert(q) ?? LauncherCalculation.color(q) {
            result.append(.init(id: "utility:result", scope: .commands, title: value, subtitle: q, keywords: q,
                                symbol: "equal.circle", priority: 1000, actions: [copy(value)]))
        }
        if lower == "uuid" {
            result.append(.init(id: "utility:uuid", scope: .commands, title: L10n.shared.string("生成 UUID"), keywords: q, priority: 500,
                actions: [action("generate", "生成并复制", "doc.on.doc", restore: true) {
                    try SystemClipboardPasteboard().write(.text(UUID().uuidString.lowercased()), sourceBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.noname4me.nylai")
                }]))
        }
        if lower == "now" || lower == "timestamp" {
            result.append(.init(id: "utility:timestamp", scope: .commands, title: String(Int(Date().timeIntervalSince1970)),
                                subtitle: L10n.shared.string("当前时间戳"), keywords: q, priority: 500,
                                actions: [copy(String(Int(Date().timeIntervalSince1970)))]))
        }
        let transforms = [("json format", "格式化 JSON"), ("base64 encode", "Base64 编码"), ("base64 decode", "Base64 解码")]
        for (key, title) in transforms where !q.isEmpty && key.hasPrefix(lower) {
            result.append(.init(id: "utility:\(key)", scope: .commands, title: L10n.shared.string(title), subtitle: L10n.shared.string("处理当前剪贴板"),
                keywords: key, priority: 50, actions: [action("transform", "处理并复制", "doc.on.doc", restore: true) {
                    guard let text = NSPasteboard.general.string(forType: .string), text.utf8.count <= 1_048_576 else { throw LauncherError.invalidInput }
                    let value: String
                    switch key {
                    case "json format":
                        let object = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
                        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
                        value = String(decoding: data, as: UTF8.self)
                    case "base64 encode": value = Data(text.utf8).base64EncodedString()
                    default:
                        guard let data = Data(base64Encoded: text), let decoded = String(data: data, encoding: .utf8) else { throw LauncherError.invalidInput }
                        value = decoded
                    }
                    try SystemClipboardPasteboard().write(.text(value), sourceBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.noname4me.nylai")
                }]))
        }
        return result
    }
}
