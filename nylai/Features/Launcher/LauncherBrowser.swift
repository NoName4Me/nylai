import AppKit
import Foundation

struct LauncherBrowserRecord: Sendable {
    let browser: String
    let title: String
    let url: String
    let scope: LauncherScope
    var bundle: String? = nil
    var windowID: Int? = nil
    var tabIndex: Int? = nil

    var id: String {
        if let windowID, let tabIndex { return "tab:\(bundle ?? browser):\(windowID):\(tabIndex)" }
        return "\(scope.rawValue):\(browser):\(url)"
    }
}

enum LauncherBrowser {
    private struct Browser: Sendable {
        let name: String
        let bundle: String
        let directory: String
    }
    private static let chromium = [
        Browser(name: "Chrome", bundle: "com.google.Chrome", directory: "Google/Chrome"),
        Browser(name: "Edge", bundle: "com.microsoft.edgemac", directory: "Microsoft Edge"),
        Browser(name: "Brave", bundle: "com.brave.Browser", directory: "BraveSoftware/Brave-Browser")
    ]
    private static let safari = Browser(name: "Safari", bundle: "com.apple.Safari", directory: "")
    private static let delimiter = "\u{1f}"
    private static let rowDelimiter = "\u{1e}"

    static func records(config: LauncherConfiguration, runningBundles: Set<String>) async -> [LauncherBrowserRecord] {
        var results: [LauncherBrowserRecord] = []
        if config.browserTabs {
            for browser in [safari] + chromium where runningBundles.contains(browser.bundle) {
                guard !Task.isCancelled else { return [] }
                let script = listScript(browser)
                if let output = await LauncherProcess.output("/usr/bin/osascript", arguments: ["-e", script], limit: 500_000) {
                    for row in output.components(separatedBy: rowDelimiter) {
                        let fields = row.components(separatedBy: delimiter)
                        guard fields.count >= 4, let window = Int(fields[0]), let index = Int(fields[1]), !fields[3].isEmpty else { continue }
                        results.append(.init(browser: browser.name, title: fields[2], url: fields[3], scope: .tabs,
                                             bundle: browser.bundle, windowID: window, tabIndex: index))
                    }
                }
            }
        }
        if config.browserBookmarks || config.browserHistory {
            let files = Task.detached(priority: .utility) { await fileRecords(bookmarks: config.browserBookmarks, history: config.browserHistory) }
            let output = await withTaskCancellationHandler { await files.value } onCancel: { files.cancel() }
            results.append(contentsOf: output)
        }
        return results
    }

    private static func listScript(_ browser: Browser) -> String {
        let title = browser.bundle == safari.bundle ? "name" : "title"
        return """
        set rs to ASCII character 30
        set fs to ASCII character 31
        set output to ""
        tell application id "\(browser.bundle)"
            repeat with w in windows
                set n to 0
                repeat with t in tabs of w
                    set n to n + 1
                    try
                        set output to output & (id of w as text) & fs & (n as text) & fs & (\(title) of t as text) & fs & (URL of t as text) & rs
                    end try
                end repeat
            end repeat
        end tell
        return output
        """
    }

    // Use only fixed browser bundle IDs and numeric tab/window positions in code. URL is an argv value.
    static func activate(_ record: LauncherBrowserRecord) async throws {
        guard let bundle = record.bundle, let window = record.windowID, let tab = record.tabIndex,
              ([safari] + chromium).contains(where: { $0.bundle == bundle }) else { throw LauncherError.unavailable }
        let selection = bundle == safari.bundle ? "set current tab of w to tab i of w" : "set active tab index of w to i"
        let script = """
        on run argv
            set expectedURL to item 1 of argv
            tell application id "\(bundle)"
                repeat with w in windows
                    if id of w is \(window) then
                        set i to \(tab)
                        if i ≤ (count of tabs of w) then
                            if (URL of tab i of w as text) is expectedURL then
                                \(selection)
                                set index of w to 1
                                activate
                                return "ok"
                            end if
                        end if
                    end if
                end repeat
            end tell
            return "missing"
        end run
        """
        let output = await LauncherProcess.output("/usr/bin/osascript", arguments: ["-e", script, "--", record.url])
        guard output?.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" else { throw LauncherError.unavailable }
    }

    private static func fileRecords(bookmarks: Bool, history: Bool) async -> [LauncherBrowserRecord] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support")
        var rows: [LauncherBrowserRecord] = []
        if bookmarks {
            let url = home.appendingPathComponent("Library/Safari/Bookmarks.plist")
            if let data = try? Data(contentsOf: url), let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
                collectBookmarks(root, browser: "Safari", safari: true, into: &rows)
            }
        }
        if history {
            rows += await sqlite(home.appendingPathComponent("Library/Safari/History.db"), browser: "Safari",
                scope: .history, query: "SELECT COALESCE(history_visits.title, '') AS title, history_items.url AS url FROM history_visits JOIN history_items ON history_visits.history_item=history_items.id ORDER BY history_visits.visit_time DESC LIMIT 500;")
        }
        for browser in chromium {
            guard !Task.isCancelled else { return [] }
            let root = support.appendingPathComponent(browser.directory)
            let profiles = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for profile in profiles.filter({ $0.lastPathComponent == "Default" || $0.lastPathComponent.hasPrefix("Profile ") }).prefix(12) {
                if bookmarks, let data = try? Data(contentsOf: profile.appendingPathComponent("Bookmarks")),
                   let json = try? JSONSerialization.jsonObject(with: data) {
                    collectBookmarks(json, browser: browser.name, safari: false, into: &rows)
                }
                if history {
                    rows += await sqlite(profile.appendingPathComponent("History"), browser: browser.name, scope: .history,
                        query: "SELECT COALESCE(title, '') AS title, url FROM urls ORDER BY last_visit_time DESC LIMIT 500;")
                }
            }
        }
        let firefoxRoot = support.appendingPathComponent("Firefox/Profiles")
        let firefoxProfiles = (try? FileManager.default.contentsOfDirectory(at: firefoxRoot, includingPropertiesForKeys: nil)) ?? []
        for profile in firefoxProfiles.prefix(12) {
            guard !Task.isCancelled else { return [] }
            let db = profile.appendingPathComponent("places.sqlite")
            if history {
                rows += await sqlite(db, browser: "Firefox", scope: .history,
                    query: "SELECT COALESCE(title, '') AS title, url FROM moz_places WHERE last_visit_date IS NOT NULL ORDER BY last_visit_date DESC LIMIT 500;")
            }
            if bookmarks {
                rows += await sqlite(db, browser: "Firefox", scope: .bookmarks,
                    query: "SELECT COALESCE(b.title, p.title, '') AS title, p.url AS url FROM moz_bookmarks b JOIN moz_places p ON b.fk=p.id WHERE b.type=1 LIMIT 1500;")
            }
        }
        var seen = Set<String>()
        return rows.filter { seen.insert($0.id).inserted }
    }

    private static func collectBookmarks(_ root: Any, browser: String, safari: Bool, into output: inout [LauncherBrowserRecord]) {
        guard output.count < 6000 else { return }
        if let object = root as? [String: Any] {
            let url = object[safari ? "URLString" : "url"] as? String
            let title = safari ? (object["URIDictionary"] as? [String: Any])?["title"] as? String : object["name"] as? String
            if let url, !url.isEmpty {
                output.append(.init(browser: browser, title: title ?? url, url: url, scope: .bookmarks))
            }
            for (key, value) in object where key == "children" || key == "Children" || key == "roots" || (object["type"] == nil && value is [String: Any]) {
                collectBookmarks(value, browser: browser, safari: safari, into: &output)
            }
        } else if let array = root as? [Any] {
            for value in array { collectBookmarks(value, browser: browser, safari: safari, into: &output) }
        }
    }

    private static func sqlite(_ file: URL, browser: String, scope: LauncherScope, query: String) async -> [LauncherBrowserRecord] {
        guard FileManager.default.fileExists(atPath: file.path), !Task.isCancelled,
              let text = await LauncherProcess.output("/usr/bin/sqlite3", arguments: ["-readonly", "-json", file.path, query], limit: 3_000_000),
              let data = text.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let url = row["url"] as? String, !url.isEmpty else { return nil }
            let title = row["title"] as? String ?? ""
            return .init(browser: browser, title: title.isEmpty ? url : title, url: url, scope: scope)
        }
    }
}
