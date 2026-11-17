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
        guard FinderEnhancementAvailability.isEnabled() else { return nil }
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
        for definition in FinderDocumentCatalog.menus(chinese: chinese) {
            let parent = NSMenuItem(title: definition.title, action: nil, keyEquivalent: "")
            parent.image = definition.image
            let submenu = NSMenu(title: definition.title)
            for document in definition.items {
                guard let item = actionItem(
                    title: document.title,
                    action: document.action,
                    image: document.image,
                    target: target,
                    menuKind: menuKind,
                    selection: selection,
                    point: point,
                    createdAt: createdAt
                ) else { continue }
                submenu.addItem(item)
            }
            if !submenu.items.isEmpty {
                parent.submenu = submenu
                menu.addItem(parent)
            }
        }
        for definition in [
            (
                "new-file",
                chinese ? "新建文本文件" : "New Text File",
                symbol("doc.badge.plus")
            ),
            (
                "copy-path",
                chinese ? "复制路径" : "Copy Path",
                symbol("doc.on.doc")
            ),
            (
                "terminal",
                chinese ? "在此打开终端" : "Open Terminal Here",
                terminalIcon()
            ),
        ] {
            guard let item = actionItem(
                title: definition.1,
                action: definition.0,
                image: definition.2,
                target: target,
                menuKind: menuKind,
                selection: selection,
                point: point,
                createdAt: createdAt
            ) else { continue }
            menu.addItem(item)
        }
        return menu
    }

    private func actionItem(
        title: String,
        action: String,
        image: NSImage?,
        target: URL,
        menuKind: FIMenuKind,
        selection: [URL],
        point: CGPoint,
        createdAt: TimeInterval
    ) -> NSMenuItem? {
        let item = NSMenuItem(
            title: title,
            action: #selector(performAction(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.image = image
        var components = URLComponents()
        components.scheme = "nylai"
        components.host = "finder"
        components.path = "/" + action
        components.queryItems = [
            URLQueryItem(name: "target", value: target.absoluteString),
            URLQueryItem(
                name: "context",
                value: menuKind == .contextualMenuForContainer ? "container" : "item"
            ),
        ]
        if selection.count > 1,
           let data = try? JSONEncoder().encode(selection.map(\.absoluteString)) {
            components.queryItems?.append(URLQueryItem(
                name: "selection",
                value: data.base64EncodedString()
            ))
            components.queryItems?.append(URLQueryItem(
                name: "point",
                value: "\(point.x),\(point.y)"
            ))
            components.queryItems?.append(URLQueryItem(
                name: "createdAt",
                value: String(createdAt)
            ))
        }
        guard let url = components.url else { return nil }
        item.tag = actions.register(url)
        return item
    }

    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.size = NSSize(width: 16, height: 16)
        return image
    }

    private func terminalIcon() -> NSImage? {
        guard let app = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Terminal"
        ) else { return symbol("terminal") }
        let image = NSWorkspace.shared.icon(forFile: app.path)
        image.size = NSSize(width: 16, height: 16)
        return image
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
