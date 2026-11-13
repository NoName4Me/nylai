import AppKit

struct FinderEnhancementRequest {
    enum Action: String {
        case newFile = "new-file"
        case copyPath = "copy-path"
        case terminal
    }

    let action: Action
    var target: URL
    let isContainer: Bool
    let selection: [URL]
    let clickPoint: CGPoint?
    let menuCreatedAt: TimeInterval?

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "nylai", components.host == "finder",
              let action = Action(rawValue: String(components.path.dropFirst())),
              let items = components.queryItems, items.count == 2 || items.count == 5,
              Set(items.map(\.name)).count == items.count,
              Set(items.map(\.name)).isSubset(of: ["target", "context", "selection", "point", "createdAt"]),
              items.filter({ $0.name == "target" }).count == 1,
              items.filter({ $0.name == "context" }).count == 1,
              let context = items.first(where: { $0.name == "context" })?.value,
              context == "container" || context == "item",
              let value = items.first(where: { $0.name == "target" })?.value,
              let target = URL(string: value), target.isFileURL,
              target.host == nil || target.host == "" || target.host == "localhost",
              target.path.hasPrefix("/") else { return nil }
        self.action = action
        self.target = target.standardizedFileURL
        isContainer = context == "container"
        if items.count == 5 {
            guard let encoded = items.first(where: { $0.name == "selection" })?.value,
                  let data = Data(base64Encoded: encoded), data.count < 1_000_000,
                  let paths = try? JSONDecoder().decode([String].self, from: data),
                  paths.count > 1, paths.count <= 4096,
                  let point = items.first(where: { $0.name == "point" })?.value?.split(separator: ","),
                  point.count == 2, let horizontal = Double(point[0]), let vertical = Double(point[1]),
                  horizontal.isFinite, vertical.isFinite,
                  let timeString = items.first(where: { $0.name == "createdAt" })?.value,
                  let time = Double(timeString), time.isFinite else { return nil }
            let urls = paths.compactMap(URL.init(string:))
            guard urls.count == paths.count, urls.allSatisfy({
                $0.isFileURL && ($0.host == nil || $0.host == "" || $0.host == "localhost")
            }) else { return nil }
            selection = urls.map(\.standardizedFileURL)
            clickPoint = CGPoint(x: horizontal, y: vertical)
            menuCreatedAt = time
        } else {
            selection = []
            clickPoint = nil
            menuCreatedAt = nil
        }
    }

    func directory() throws -> URL {
        let values = try target.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        let directory = values.isDirectory == true && (isContainer || values.isPackage != true)
            ? target : target.deletingLastPathComponent()
        guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return directory
    }

    static func createFile(named name: String, in directory: URL) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains(":"), !name.contains("\0") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let destination = directory.appendingPathComponent(name, isDirectory: false)
        try Data().write(to: destination, options: .withoutOverwriting)
        return destination
    }

    static func createUntitledFile(in directory: URL, name: String) throws -> URL {
        let stem = (name as NSString).deletingPathExtension
        let suffix = (name as NSString).pathExtension
        for index in 1...1000 {
            let numbered = index == 1 ? name : "\(stem) \(index)" + (suffix.isEmpty ? "" : "." + suffix)
            do {
                return try createFile(named: numbered, in: directory)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}

@MainActor
enum FinderEnhancementAction {
    static func perform(_ incomingRequest: FinderEnhancementRequest) {
        do {
            var request = incomingRequest
            if !request.isContainer, request.selection.count > 1,
               !request.selection.contains(request.target) {
                guard let point = request.clickPoint,
                      let target = FinderRightClickTarget.resolve(
                        point: point, candidates: request.selection, menuCreatedAt: request.menuCreatedAt
                      ) else {
                    let alert = NSAlert()
                    alert.messageText = L10n.shared.string("无法确定右键项目")
                    alert.informativeText = L10n.shared.string("请仅选择一个项目后重试，或在系统设置中允许拈来的辅助功能权限。")
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                    return
                }
                request.target = target
            }
            switch request.action {
            case .copyPath:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(request.target.path, forType: .string)
            case .newFile:
                let directory = try request.directory()
                let created = try FinderEnhancementRequest.createUntitledFile(
                    in: directory, name: L10n.shared.string("未命名.txt")
                )
                NSWorkspace.shared.activateFileViewerSelecting([created])
                Task { await FinderInlineRename.begin(for: created) }
            case .terminal:
                let directory = try request.directory()
                guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                    throw CocoaError(.fileNoSuchFile)
                }
                Task {
                    do {
                        _ = try await NSWorkspace.shared.open(
                            [directory], withApplicationAt: terminal, configuration: .init()
                        )
                    } catch {
                        show(error)
                    }
                }
            }
        } catch {
            show(error)
        }
    }

    private static func show(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}
