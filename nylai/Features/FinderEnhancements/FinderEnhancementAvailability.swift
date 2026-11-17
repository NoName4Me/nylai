import Foundation

/// 宿主与 Finder Sync 扩展共享模块开关。
///
/// 现工程使用 ad-hoc 签名，没有可用的 App Group。扩展本身是沙盒进程，
/// 只能读取自己容器内的文件；宿主的模块开关因此写入扩展容器的
/// Application Support。文件不存在时默认开启，兼容升级前的用户。
enum FinderEnhancementAvailability {
    static let extensionBundleIdentifier = "com.noname4me.nylai.finder"
    private static let flagRelativePath = "nylai/finder-enhancements.enabled"

    static var defaultFlagURL: URL? {
        let base: URL
        if Bundle.main.bundleIdentifier == extensionBundleIdentifier {
            guard let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else { return nil }
            base = applicationSupport
        } else {
            let container = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Containers", directoryHint: .isDirectory)
                .appending(path: extensionBundleIdentifier, directoryHint: .isDirectory)
                .appending(path: "Data/Library/Application Support", directoryHint: .isDirectory)
            base = container
        }
        return base.appending(path: flagRelativePath)
    }

    static func isEnabled(at flagURL: URL? = defaultFlagURL) -> Bool {
        guard let flagURL,
              let value = try? String(contentsOf: flagURL, encoding: .utf8) else {
            return true
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines) != "0"
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool, at flagURL: URL? = defaultFlagURL) -> Bool {
        guard let flagURL else { return false }
        do {
            try FileManager.default.createDirectory(
                at: flagURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try (enabled ? "1" : "0").write(
                to: flagURL,
                atomically: true,
                encoding: .utf8
            )
            return true
        } catch {
            return false
        }
    }
}
