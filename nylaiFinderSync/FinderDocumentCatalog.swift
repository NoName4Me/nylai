import AppKit

struct FinderDocumentMenuDefinition {
    let title: String
    let image: NSImage?
    let items: [FinderDocumentMenuItem]
}

struct FinderDocumentMenuItem {
    let title: String
    let action: String
    let image: NSImage?
}

enum FinderDocumentCatalog {
    static func menus(chinese: Bool) -> [FinderDocumentMenuDefinition] {
        [
            officeMenu(chinese: chinese),
            wpsMenu(chinese: chinese),
        ].compactMap { $0 }
    }

    private static func officeMenu(chinese: Bool) -> FinderDocumentMenuDefinition? {
        let definitions: [(String, String, [String])] = [
            (
                "new-word",
                chinese ? "Word 文档" : "Word Document",
                ["com.microsoft.Word"]
            ),
            (
                "new-excel",
                chinese ? "Excel 工作簿" : "Excel Workbook",
                ["com.microsoft.Excel"]
            ),
            (
                "new-powerpoint",
                chinese ? "PowerPoint 演示文稿" : "PowerPoint Presentation",
                ["com.microsoft.Powerpoint"]
            ),
        ]
        let items = definitions.compactMap { action, title, bundleIDs -> FinderDocumentMenuItem? in
            guard let app = application(bundleIDs) else { return nil }
            return FinderDocumentMenuItem(
                title: title,
                action: action,
                image: icon(for: app)
            )
        }
        guard !items.isEmpty else { return nil }
        return FinderDocumentMenuDefinition(
            title: chinese ? "新建 Microsoft Office 文档" : "New Microsoft Office Document",
            image: items.first?.image,
            items: items
        )
    }

    private static func wpsMenu(chinese: Bool) -> FinderDocumentMenuDefinition? {
        guard let app = application(["com.kingsoft.wpsoffice.mac"]) else { return nil }
        let items = [
            (
                "new-wps-writer",
                chinese ? "WPS 文字" : "WPS Writer"
            ),
            (
                "new-wps-spreadsheet",
                chinese ? "WPS 表格" : "WPS Spreadsheet"
            ),
            (
                "new-wps-presentation",
                chinese ? "WPS 演示" : "WPS Presentation"
            ),
        ].map {
            FinderDocumentMenuItem(
                title: $0.1,
                action: $0.0,
                image: icon(for: app)
            )
        }
        return FinderDocumentMenuDefinition(
            title: chinese ? "新建 WPS 文档" : "New WPS Document",
            image: icon(for: app),
            items: items
        )
    }

    private static func application(_ bundleIdentifiers: [String]) -> URL? {
        bundleIdentifiers.lazy.compactMap {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }.first
    }

    private static func icon(for app: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: app.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}
