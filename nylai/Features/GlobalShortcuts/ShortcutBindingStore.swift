import Carbon
import Foundation

protocol ShortcutBindingFileWriting: Sendable {
    func write(_ data: Data, to fileURL: URL) throws
}

struct AtomicShortcutBindingFileWriter: ShortcutBindingFileWriting {
    func write(_ data: Data, to fileURL: URL) throws {
        try data.write(to: fileURL, options: .atomic)
    }
}

struct ShortcutBindingStore: Sendable {
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
            .appending(path: "shortcut-bindings.json", directoryHint: .notDirectory)
    }

    func loadOrCreateDefaults() throws -> ShortcutBindingConfiguration {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            let configuration = ShortcutBindingConfiguration.defaults
            try save(configuration)
            return configuration
        }
        return try load()
    }

    func load() throws -> ShortcutBindingConfiguration {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw ShortcutBindingStoreError.readFailed(error.localizedDescription)
        }

        let version = try readVersion(from: data)
        switch version {
        case ShortcutBindingConfiguration.currentVersion:
            do {
                return try JSONDecoder().decode(ShortcutBindingConfiguration.self, from: data)
            } catch {
                throw ShortcutBindingStoreError.corruptedData
            }
        case 1, 2:
            do {
                let decoded = try JSONDecoder().decode(ShortcutBindingConfiguration.self, from: data)
                let configuration = Self.addingBuiltInActions(
                    to: Self.migratedCaptureBindings(decoded)
                )
                try save(configuration)
                return configuration
            } catch let error as ShortcutBindingStoreError {
                throw error
            } catch {
                throw ShortcutBindingStoreError.corruptedData
            }
        case 3, 4, 5, 6:
            do {
                let decoded = try JSONDecoder().decode(ShortcutBindingConfiguration.self, from: data)
                let configuration = Self.addingBuiltInActions(to: decoded)
                try save(configuration)
                return configuration
            } catch let error as ShortcutBindingStoreError {
                throw error
            } catch {
                throw ShortcutBindingStoreError.corruptedData
            }
        case 7:
            do {
                let decoded = try JSONDecoder().decode(ShortcutBindingConfiguration.self, from: data)
                let configuration = Self.addingBuiltInActions(
                    to: Self.migratingVersionSevenDefaults(decoded)
                )
                try save(configuration)
                return configuration
            } catch let error as ShortcutBindingStoreError {
                throw error
            } catch {
                throw ShortcutBindingStoreError.corruptedData
            }
        default:
            throw ShortcutBindingStoreError.unsupportedVersion(version)
        }
    }

    func save(_ configuration: ShortcutBindingConfiguration) throws {
        guard configuration.version == ShortcutBindingConfiguration.currentVersion else {
            throw ShortcutBindingStoreError.unsupportedVersion(configuration.version)
        }

        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(configuration)
        } catch {
            throw ShortcutBindingStoreError.writeFailed(error.localizedDescription)
        }

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileWriter.write(data, to: fileURL)
        } catch {
            throw ShortcutBindingStoreError.writeFailed(error.localizedDescription)
        }
    }

    private func readVersion(from data: Data) throws -> Int {
        struct VersionEnvelope: Decodable {
            let version: Int
        }

        do {
            return try JSONDecoder().decode(VersionEnvelope.self, from: data).version
        } catch {
            throw ShortcutBindingStoreError.corruptedData
        }
    }

    private static func migratedCaptureBindings(
        _ configuration: ShortcutBindingConfiguration
    ) -> ShortcutBindingConfiguration {
        let legacyMain = configuration.bindings.first {
            $0.id == .captureMainDisplay || $0.action == .captureMainDisplay
        }
        let currentInteractive = configuration.bindings.first {
            $0.id == .captureInteractive || $0.action == .captureInteractive
        }

        var unified: ShortcutBinding?
        if let currentInteractive {
            var binding = currentInteractive
            if binding.shortcut == nil, let legacyMain {
                binding.shortcut = legacyMain.shortcut
                binding.isEnabled = legacyMain.isEnabled
            }
            unified = ShortcutBinding(
                id: .captureInteractive,
                action: .captureInteractive,
                shortcut: binding.shortcut,
                isEnabled: binding.isEnabled
            )
        } else if let legacyMain {
            unified = ShortcutBinding(
                id: .captureInteractive,
                action: .captureInteractive,
                shortcut: legacyMain.shortcut,
                isEnabled: legacyMain.isEnabled
            )
        } else {
            unified = ShortcutBinding(
                id: .captureInteractive,
                action: .captureInteractive,
                shortcut: nil,
                isEnabled: true
            )
        }

        var bindings: [ShortcutBinding] = []
        var insertedUnified = false
        for binding in configuration.bindings {
            let isLegacyCapture = binding.id == .captureMainDisplay
                || binding.action == .captureMainDisplay
                || binding.id == .captureInteractive
                || binding.action == .captureInteractive
            if isLegacyCapture {
                if !insertedUnified, let unified {
                    bindings.append(unified)
                    insertedUnified = true
                }
            } else {
                bindings.append(binding)
            }
        }
        if !insertedUnified, let unified {
            bindings.append(unified)
        }

        return ShortcutBindingConfiguration(
            version: ShortcutBindingConfiguration.currentVersion,
            isEnabled: configuration.isEnabled,
            bindings: bindings
        )
    }

    private static func addingBuiltInActions(
        to configuration: ShortcutBindingConfiguration
    ) -> ShortcutBindingConfiguration {
        var bindings = configuration.bindings
        if !bindings.contains(where: {
            $0.id == .screenshotHistory || $0.action == .screenshotHistory
        }) {
            bindings.append(ShortcutBinding(
                id: .screenshotHistory,
                action: .screenshotHistory,
                shortcut: nil,
                isEnabled: true
            ))
        }
        if !bindings.contains(where: {
            $0.id == .collage || $0.action == .openCollage
        }) {
            bindings.append(ShortcutBinding(
                id: .collage,
                action: .openCollage,
                shortcut: nil,
                isEnabled: true
            ))
        }
        if !bindings.contains(where: {
            $0.id == .scrollCapture || $0.action == .scrollCapture
        }) {
            bindings.append(ShortcutBinding(
                id: .scrollCapture,
                action: .scrollCapture,
                shortcut: nil,
                isEnabled: true
            ))
        }
        if !bindings.contains(where: {
            $0.id == .clipboardHistory || $0.action == .clipboardHistory
        }) {
            bindings.append(ShortcutBinding(
                id: .clipboardHistory,
                action: .clipboardHistory,
                shortcut: nil,
                isEnabled: true
            ))
        }
        return ShortcutBindingConfiguration(
            version: ShortcutBindingConfiguration.currentVersion,
            isEnabled: configuration.isEnabled,
            bindings: bindings
        )
    }

    private static func migratingVersionSevenDefaults(
        _ configuration: ShortcutBindingConfiguration
    ) -> ShortcutBindingConfiguration {
        let legacyOpenSettings = ShortcutKey(
            keyCode: UInt32(kVK_ANSI_N),
            modifiers: [.control, .option]
        )
        let legacyScreenshot = ShortcutKey(
            keyCode: UInt32(kVK_ANSI_S),
            modifiers: [.control, .option]
        )
        let screenshot = ShortcutKey(
            keyCode: UInt32(kVK_ANSI_A),
            modifiers: [.option]
        )
        let hadOnlyLegacyDefaults = configuration.bindings.count == 6
            && configuration.bindings.allSatisfy { $0.isEnabled }
            && configuration.bindings.first {
                $0.id == .openSettings
            }?.shortcut == legacyOpenSettings
            && configuration.bindings.first {
                $0.id == .captureInteractive
            }?.shortcut == legacyScreenshot
            && configuration.bindings
                .filter { $0.id != .openSettings && $0.id != .captureInteractive }
                .allSatisfy { $0.shortcut == nil }
            && !configuration.bindings.contains {
                if case .application = $0.action { return true }
                return false
            }

        let bindings = configuration.bindings.map { binding in
            var updated = binding
            if binding.id == .openSettings, binding.shortcut == legacyOpenSettings {
                updated.shortcut = nil
            } else if binding.id == .captureInteractive,
                      binding.shortcut == legacyScreenshot {
                updated.shortcut = screenshot
            }
            return updated
        }
        return ShortcutBindingConfiguration(
            version: ShortcutBindingConfiguration.currentVersion,
            isEnabled: hadOnlyLegacyDefaults ? false : configuration.isEnabled,
            bindings: bindings
        )
    }
}

enum ShortcutBindingStoreError: LocalizedError, Equatable {
    case readFailed(String)
    case corruptedData
    case unsupportedVersion(Int)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .readFailed(let message):
            "无法读取快捷键配置：\(message)"
        case .corruptedData:
            "快捷键配置文件已损坏，原文件已保留。"
        case .unsupportedVersion(let version):
            "快捷键配置版本 \(version) 不受支持，原文件已保留。"
        case .writeFailed(let message):
            "无法保存快捷键配置：\(message)"
        }
    }
}
