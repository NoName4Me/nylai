import AppKit
import Foundation
import Observation

enum LauncherScope: String, CaseIterable, Identifiable, Codable, Sendable {
    case all, applications, commands, files, windows, clipboard, boards, screenshots, links, tabs, bookmarks, history
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: L10n.shared.string("全部")
        case .applications: L10n.shared.string("应用")
        case .commands: L10n.shared.string("命令")
        case .files: L10n.shared.string("文件")
        case .windows: L10n.shared.string("窗口")
        case .clipboard: L10n.shared.string("剪贴板")
        case .boards: L10n.shared.string("画布")
        case .screenshots: L10n.shared.string("截图")
        case .links: L10n.shared.string("快捷入口")
        case .tabs: L10n.shared.string("标签页")
        case .bookmarks: L10n.shared.string("书签")
        case .history: L10n.shared.string("浏览历史")
        }
    }
    var alias: String {
        switch self {
        case .all: "all"
        case .applications: "app"
        case .commands: "cmd"
        case .files: "file"
        case .windows: "win"
        case .clipboard: "clip"
        case .boards: "board"
        case .screenshots: "img"
        case .links: "link"
        case .tabs: "tab"
        case .bookmarks: "bookmark"
        case .history: "history"
        }
    }
    var symbol: String {
        switch self {
        case .all: "magnifyingglass"
        case .applications: "app.dashed"
        case .commands: "command"
        case .files: "doc"
        case .windows: "macwindow"
        case .clipboard: "doc.on.clipboard"
        case .boards: "note.text"
        case .screenshots: "photo"
        case .links: "link"
        case .tabs: "rectangle.on.rectangle"
        case .bookmarks: "bookmark"
        case .history: "clock.arrow.circlepath"
        }
    }
}

struct LauncherQuery: Equatable, Sendable {
    var scope: LauncherScope
    var text: String

    init(_ input: String, scope: LauncherScope) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        self.scope = scope
        text = trimmed
        guard scope == .all, let split = trimmed.firstIndex(where: { $0 == ":" || $0.isWhitespace }),
              let resolved = LauncherScope.allCases.first(where: { $0.alias == trimmed[..<split].lowercased() }) else { return }
        self.scope = resolved
        text = String(trimmed[trimmed.index(after: split)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct LauncherQuicklink: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var alias: String
    var target: String

    func resolve(argument: String) -> URL? {
        let value = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let escaped = argument.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        let resolved = value.replacingOccurrences(of: "{query}", with: escaped)
        if resolved.hasPrefix("/") || resolved.hasPrefix("~/") {
            return URL(fileURLWithPath: (resolved as NSString).expandingTildeInPath)
        }
        guard let url = URL(string: resolved), let scheme = url.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme) else { return nil }
        if scheme != "file", url.host?.isEmpty != false { return nil }
        return url
    }
}

struct LauncherConfiguration: Codable, Equatable, Sendable {
    var version = 1
    var links: [LauncherQuicklink] = []
    var aliases: [String: String] = [:]
    var usage: [String: Int] = [:]
    var favorites: [String] = []
    var searchRoots: [String] = []
    var browserTabs = false
    var browserBookmarks = false
    var browserHistory = false
}

@MainActor
@Observable
final class LauncherPreferences {
    private(set) var configuration = LauncherConfiguration()
    private(set) var loadError: String?
    var error: String?
    let directory: URL

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("nylai/Launcher", isDirectory: true)) {
        self.directory = directory
        let url = directory.appendingPathComponent("settings.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let decoded = try JSONDecoder().decode(LauncherConfiguration.self, from: Data(contentsOf: url))
                guard decoded.version == 1 else { throw LauncherError.invalidConfiguration }
                configuration = decoded
            } catch { loadError = error.localizedDescription }
        }
    }

    func update(_ edit: (inout LauncherConfiguration) -> Void) {
        guard loadError == nil else { error = loadError; return }
        var next = configuration
        edit(&next)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: directory.appendingPathComponent("settings.json"), options: .atomic)
            configuration = next
        } catch { self.error = error.localizedDescription }
    }

    func record(_ id: String) {
        // Do not store clipboard text, browser URLs or individual private notes in usage.
        guard id.hasPrefix("app:") || id.hasPrefix("cmd:") || id.hasPrefix("link:") else { return }
        update { config in
            config.usage[id] = min(1000, config.usage[id, default: 0] + 1)
            if config.usage.count > 500 {
                config.usage = Dictionary(uniqueKeysWithValues: config.usage.sorted { $0.value > $1.value }.prefix(400).map { ($0.key, $0.value) })
            }
        }
    }
}

struct LauncherAction: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var restoresPreviousApplication = false
    let run: @MainActor () async throws -> Void
}

struct LauncherResult: Identifiable {
    let id: String
    let scope: LauncherScope
    let title: String
    var subtitle = ""
    var keywords = ""
    var symbol: String? = nil
    var icon: NSImage? = nil
    var preview: NSImage? = nil
    var priority: Int = 0
    var actions: [LauncherAction]
}

enum LauncherError: LocalizedError {
    case unavailable, invalidConfiguration, invalidLink, commandFailed, clipboardUnavailable, invalidInput
    var errorDescription: String? {
        switch self {
        case .unavailable: L10n.shared.string("目标已不可用。")
        case .invalidConfiguration: L10n.shared.string("Launcher 配置无效，原文件已保留。")
        case .invalidLink: L10n.shared.string("快捷入口目标无效。")
        case .commandFailed: L10n.shared.string("操作失败，请检查系统权限。")
        case .clipboardUnavailable: L10n.shared.string("剪贴板内容已不可用。")
        case .invalidInput: L10n.shared.string("输入格式无效。")
        }
    }
}

enum LauncherRank {
    static func folded(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current).lowercased()
    }

    static func romanized(_ value: String) -> (full: String, initials: String) {
        let transformed = value.applyingTransform(.toLatin, reverse: false) ?? value
        let words = folded(transformed).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return (words.joined(), words.compactMap(\.first).map(String.init).joined())
    }

    static func score(query: String, title: String, keywords: String, subtitle: String, alias: String? = nil) -> Int? {
        let q = folded(query)
        guard !q.isEmpty else { return 0 }
        let name = folded(title), aliases = folded(alias ?? "")
        let key = folded(keywords), secondary = folded(subtitle)
        if name == q || aliases.split(whereSeparator: \.isWhitespace).contains(where: { $0 == q }) { return 1000 }
        if name.hasPrefix(q) { return 800 - min(80, name.count - q.count) }
        if aliases.split(whereSeparator: \.isWhitespace).contains(where: { $0.hasPrefix(q) }) { return 760 }
        if name.contains(q) { return 650 }
        let roman = romanized(title)
        let compact = q.filter { $0.isLetter || $0.isNumber }
        if !compact.isEmpty {
            if roman.full == compact || roman.initials == compact { return 790 }
            if roman.full.hasPrefix(compact) || roman.initials.hasPrefix(compact) { return 690 }
        }
        let tokens = q.split(whereSeparator: \.isWhitespace)
        let combined = name + " " + key + " " + secondary
        if !tokens.isEmpty, tokens.allSatisfy({ combined.contains($0) }) { return 500 }
        if key.contains(q) || secondary.contains(q) { return 460 }
        if q.count >= 2, let distance = subsequenceGap(needle: q, haystack: name) { return 350 - min(130, distance) }
        return nil
    }

    private static func subsequenceGap(needle: String, haystack: String) -> Int? {
        var remaining = ArraySlice(needle)
        var gap = 0
        var started = false
        for c in haystack {
            if remaining.first == c {
                remaining = remaining.dropFirst()
                started = true
                if remaining.isEmpty { return gap }
            } else if started { gap += 1 }
        }
        return nil
    }
}
