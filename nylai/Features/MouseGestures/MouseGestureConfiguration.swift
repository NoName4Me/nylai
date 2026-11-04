import Foundation

enum GestureAction: Codable, Equatable, Sendable {
    case nylai(ShortcutAction)
    case application(ApplicationShortcutTarget)
    case sendShortcut(ShortcutKey)

    var title: String {
        switch self {
        case .nylai(let action):
            ShortcutBindingRuntime.title(for: action)
        case .application(let target):
            target.bundleIdentifier
        case .sendShortcut(let shortcut):
            ShortcutDisplayFormatter.string(for: shortcut)
        }
    }
}

struct MouseGestureRule: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var path: GesturePath
    var action: GestureAction
    var scopeBundleIdentifier: String?
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        path: GesturePath,
        action: GestureAction,
        scopeBundleIdentifier: String? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.path = path
        self.action = action
        self.scopeBundleIdentifier = scopeBundleIdentifier
        self.isEnabled = isEnabled
    }
}

struct MouseGestureConfiguration: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var showsTrace: Bool
    var rules: [MouseGestureRule]
    var disabledBundleIdentifiers: Set<String>

    static let defaults = MouseGestureConfiguration(
        version: currentVersion,
        showsTrace: true,
        rules: [],
        disabledBundleIdentifiers: []
    )
}

enum GestureResolution: Equatable, Sendable {
    case passThrough
    case consumedWithoutMatch
    case matched(MouseGestureRule)
}

struct GestureRuleResolver {
    let configuration: MouseGestureConfiguration
    let applicationBundleIdentifier: String?
    let isActionAvailable: (GestureAction) -> Bool

    func resolve(_ path: GesturePath) -> GestureResolution {
        guard let bundleIdentifier = applicationBundleIdentifier,
              !configuration.disabledBundleIdentifiers.contains(bundleIdentifier) else {
            return .passThrough
        }
        if let scoped = configuration.rules.first(where: {
            $0.scopeBundleIdentifier == bundleIdentifier && $0.path == path
        }) {
            guard scoped.isEnabled, isActionAvailable(scoped.action) else {
                return .consumedWithoutMatch
            }
            return .matched(scoped)
        }
        if let global = configuration.rules.first(where: {
            $0.scopeBundleIdentifier == nil && $0.path == path
        }) {
            guard global.isEnabled, isActionAvailable(global.action) else {
                return .consumedWithoutMatch
            }
            return .matched(global)
        }

        let hasOtherEffectiveRule = configuration.rules.contains {
            $0.isEnabled
                && isActionAvailable($0.action)
                && ($0.scopeBundleIdentifier == nil || $0.scopeBundleIdentifier == bundleIdentifier)
        }
        return hasOtherEffectiveRule ? .consumedWithoutMatch : .passThrough
    }

    func hasEffectiveRules(for applicationBundleIdentifier: String?) -> Bool {
        guard let applicationBundleIdentifier,
              !configuration.disabledBundleIdentifiers.contains(applicationBundleIdentifier) else {
            return false
        }
        return configuration.rules.contains {
            $0.isEnabled
                && isActionAvailable($0.action)
                && ($0.scopeBundleIdentifier == nil || $0.scopeBundleIdentifier == applicationBundleIdentifier)
        }
    }
}

enum MouseGestureConfigurationError: LocalizedError, Equatable {
    case invalidVersion
    case emptyPath
    case tooManyDirections
    case duplicatePath
    case ruleNotFound

    var errorDescription: String? {
        switch self {
        case .invalidVersion:
            L10n.shared.string("鼠标手势配置版本不受支持。")
        case .emptyPath:
            L10n.shared.string("手势路径不能为空。")
        case .tooManyDirections:
            L10n.shared.string("手势最多包含四个方向。")
        case .duplicatePath:
            L10n.shared.string("当前作用域已存在相同路径。")
        case .ruleNotFound:
            L10n.shared.string("鼠标手势规则不存在。")
        }
    }
}

struct MouseGestureConfigurationStore: Sendable {
    let fileURL: URL
    private let fileWriter: any ShortcutBindingFileWriting

    init(
        fileURL: URL,
        fileWriter: any ShortcutBindingFileWriting = AtomicShortcutBindingFileWriter()
    ) {
        self.fileURL = fileURL
        self.fileWriter = fileWriter
    }

    static func standardFileURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "nylai", directoryHint: .isDirectory)
            .appending(path: "mouse-gestures.json", directoryHint: .notDirectory)
    }

    func loadOrCreateDefaults() throws -> MouseGestureConfiguration {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            try save(.defaults)
            return .defaults
        }
        return try load()
    }

    func load() throws -> MouseGestureConfiguration {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw ShortcutBindingStoreError.readFailed(error.localizedDescription)
        }
        do {
            let envelope = try JSONDecoder().decode(VersionEnvelope.self, from: data)
            guard envelope.version == MouseGestureConfiguration.currentVersion else {
                throw ShortcutBindingStoreError.unsupportedVersion(envelope.version)
            }
            return try JSONDecoder().decode(MouseGestureConfiguration.self, from: data)
        } catch let error as ShortcutBindingStoreError {
            throw error
        } catch {
            throw ShortcutBindingStoreError.corruptedData
        }
    }

    func save(_ configuration: MouseGestureConfiguration) throws {
        guard configuration.version == MouseGestureConfiguration.currentVersion else {
            throw MouseGestureConfigurationError.invalidVersion
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(configuration)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileWriter.write(data, to: fileURL)
        } catch let error as MouseGestureConfigurationError {
            throw error
        } catch {
            throw ShortcutBindingStoreError.writeFailed(error.localizedDescription)
        }
    }

    private struct VersionEnvelope: Decodable {
        let version: Int
    }
}
