import AppKit
import FinderSync
import OSLog

final class FinderSync: FIFinderSync {
    private let actions = FinderMenuActionStore()

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems
                || menuKind == .contextualMenuForContainer
                || menuKind == .contextualMenuForSidebar,
              let container = FIFinderSyncController.default().targetedURL(),
              container.isFileURL else { return nil }
        let selection = menuKind == .contextualMenuForContainer ? [] :
            FIFinderSyncController.default().selectedItemURLs() ?? []
        let target = selection.count == 1 ? selection[0] : container
        let point = NSEvent.mouseLocation
        let createdAt = ProcessInfo.processInfo.systemUptime
        let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
        let menu = NSMenu()
        for (action, title) in [
            ("new-file", chinese ? "新建文件" : "New File"),
            ("copy-path", chinese ? "复制路径" : "Copy Path"),
            ("terminal", chinese ? "在此打开终端" : "Open Terminal Here"),
        ] {
            let item = NSMenuItem(title: title, action: #selector(performAction(_:)), keyEquivalent: "")
            item.target = self
            var components = URLComponents()
            components.scheme = "nylai"
            components.host = "finder"
            components.path = "/" + action
            components.queryItems = [
                URLQueryItem(name: "target", value: target.absoluteString),
                URLQueryItem(name: "context", value: menuKind == .contextualMenuForContainer ? "container" : "item"),
            ]
            if selection.count > 1,
               let data = try? JSONEncoder().encode(selection.map(\.absoluteString)) {
                components.queryItems?.append(URLQueryItem(name: "selection", value: data.base64EncodedString()))
                components.queryItems?.append(URLQueryItem(name: "point", value: "\(point.x),\(point.y)"))
                components.queryItems?.append(URLQueryItem(name: "createdAt", value: String(createdAt)))
            }
            guard let url = components.url else { continue }
            item.tag = actions.register(url)
            menu.addItem(item)
        }
        return menu
    }

    @objc private func performAction(_ sender: NSMenuItem) {
        guard let url = actions.action(for: sender) else {
            Logger(subsystem: "com.noname4me.nylai.finder", category: "handoff")
                .error("Finder menu action expired; reopen the context menu.")
            return
        }
        let host = Bundle.main.bundleURL.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.open([url], withApplicationAt: host, configuration: configuration) { _, error in
            if error != nil {
                Logger(subsystem: "com.noname4me.nylai.finder", category: "handoff")
                    .error("Unable to deliver the Finder menu action to Nylai.")
            }
        }
    }
}
