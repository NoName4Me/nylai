import Foundation

struct ClipboardSettingsStore: Sendable {
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
            .appending(path: "clipboard-settings.json", directoryHint: .notDirectory)
    }

    func loadOrCreateDefaults() throws -> ClipboardSettings {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            try save(.defaults)
            return .defaults
        }
        return try load()
    }

    func load() throws -> ClipboardSettings {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw ShortcutBindingStoreError.readFailed(error.localizedDescription)
        }
        do {
            let envelope = try JSONDecoder().decode(VersionEnvelope.self, from: data)
            guard envelope.version == ClipboardSettings.currentVersion else {
                throw ClipboardSettingsError.invalidVersion(envelope.version)
            }
            return try JSONDecoder().decode(ClipboardSettings.self, from: data).validated()
        } catch let error as ClipboardSettingsError {
            throw error
        } catch let error as ShortcutBindingStoreError {
            throw error
        } catch {
            throw ShortcutBindingStoreError.corruptedData
        }
    }

    func save(_ settings: ClipboardSettings) throws {
        let validated = settings.validated()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(validated)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileWriter.write(data, to: fileURL)
        } catch {
            throw ShortcutBindingStoreError.writeFailed(error.localizedDescription)
        }
    }

    private struct VersionEnvelope: Decodable {
        let version: Int
    }
}
