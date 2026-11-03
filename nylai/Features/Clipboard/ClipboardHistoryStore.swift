import AppKit
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class ClipboardHistoryStore {
    let directoryURL: URL
    let indexURL: URL
    private let settingsStore: ClipboardSettingsStore
    private let clock: @MainActor () -> Date
    private let fileWriter: any ShortcutBindingFileWriting
    private(set) var index = ClipboardIndex.empty
    private(set) var settings = ClipboardSettings.defaults

    init(
        directoryURL: URL? = nil,
        settingsStore: ClipboardSettingsStore? = nil,
        clock: @escaping @MainActor () -> Date = Date.init,
        fileWriter: any ShortcutBindingFileWriting = AtomicShortcutBindingFileWriter()
    ) throws {
        let baseDirectory = directoryURL ?? Self.standardDirectoryURL()
        self.directoryURL = baseDirectory
        indexURL = baseDirectory.appending(path: "index.json", directoryHint: .notDirectory)
        self.settingsStore = settingsStore ?? ClipboardSettingsStore(
            fileURL: ClipboardSettingsStore.standardFileURL()
        )
        self.clock = clock
        self.fileWriter = fileWriter
        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
        index = try Self.loadIndex(from: indexURL)
        settings = try self.settingsStore.loadOrCreateDefaults()
    }

    static func standardDirectoryURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "nylai", directoryHint: .isDirectory)
            .appending(path: "clipboard", directoryHint: .isDirectory)
    }

    var pinnedRecords: [ClipboardRecord] {
        index.records
            .filter(\.isPinned)
            .sorted {
                ($0.pinnedAt ?? .distantPast) > ($1.pinnedAt ?? .distantPast)
            }
    }

    var ordinaryRecords: [ClipboardRecord] {
        index.records
            .filter { !$0.isPinned }
            .sorted { $0.copiedAt > $1.copiedAt }
    }

    var allRecords: [ClipboardRecord] {
        pinnedRecords + ordinaryRecords
    }

    @discardableResult
    func add(_ capture: ClipboardCapture) throws -> ClipboardRecord? {
        let now = clock()
        if let duplicate = try updateDuplicate(capture, now: now) {
            return duplicate
        }

        let id = UUID()
        guard let prepared = try Self.prepareFiles(
            id: id,
            capture: capture,
            directoryURL: directoryURL,
            fileWriter: fileWriter
        ) else { return nil }

        let record = ClipboardRecord(
            id: id,
            kind: capture.content.kind,
            contentHash: capture.contentHash,
            fileName: prepared.bodyName,
            thumbnailFileName: prepared.thumbnailName,
            pixelWidth: prepared.pixelSize?.0,
            pixelHeight: prepared.pixelSize?.1,
            sourceBundleIdentifier: capture.sourceBundleIdentifier,
            sourceName: capture.sourceName,
            copiedAt: now,
            pinnedAt: nil
        )
        var updated = index
        updated.records.append(record)
        do {
            try applyCleanupAndCommit(updated, now: now)
        } catch {
            removeFiles(for: prepared)
            throw error
        }
        return index.records.first { $0.id == id }
    }

    @discardableResult
    func addAsync(
        _ capture: ClipboardCapture,
        shouldCommit: @MainActor () -> Bool = { true }
    ) async throws -> ClipboardRecord? {
        let now = clock()
        guard shouldCommit() else { return nil }
        if let duplicate = try updateDuplicate(capture, now: now) {
            return duplicate
        }

        let id = UUID()
        let directoryURL = directoryURL
        let fileWriter = fileWriter
        let prepareTask = Task.detached(priority: .utility) {
            try Self.prepareFiles(
                id: id,
                capture: capture,
                directoryURL: directoryURL,
                fileWriter: fileWriter
            )
        }
        let prepared = try await withTaskCancellationHandler {
            try await prepareTask.value
        } onCancel: {
            prepareTask.cancel()
        }
        guard let prepared else { return nil }
        guard shouldCommit(), !Task.isCancelled else {
            removeFiles(for: prepared)
            return nil
        }
        if let duplicate = try updateDuplicate(capture, now: now) {
            removeFiles(for: prepared)
            return duplicate
        }

        let record = ClipboardRecord(
            id: id,
            kind: capture.content.kind,
            contentHash: capture.contentHash,
            fileName: prepared.bodyName,
            thumbnailFileName: prepared.thumbnailName,
            pixelWidth: prepared.pixelSize?.0,
            pixelHeight: prepared.pixelSize?.1,
            sourceBundleIdentifier: capture.sourceBundleIdentifier,
            sourceName: capture.sourceName,
            copiedAt: now,
            pinnedAt: nil
        )
        var updated = index
        updated.records.append(record)
        do {
            try applyCleanupAndCommit(updated, now: now)
        } catch {
            removeFiles(for: prepared)
            throw error
        }
        return index.records.first { $0.id == id }
    }

    func updateSettings(_ newSettings: ClipboardSettings) throws {
        let validated = newSettings.validated()
        try settingsStore.save(validated)
        settings = validated
        try applyCleanupAndCommit(index, now: clock())
    }

    func setPinned(_ pinned: Bool, id: UUID) throws {
        guard let recordIndex = index.records.firstIndex(where: { $0.id == id }) else {
            throw ClipboardStoreError.recordNotFound
        }
        var updated = index
        if pinned {
            if updated.records[recordIndex].pinnedAt == nil {
                updated.records[recordIndex].pinnedAt = clock()
            }
        } else {
            updated.records[recordIndex].pinnedAt = nil
        }
        try applyCleanupAndCommit(updated, now: clock())
    }

    func delete(id: UUID) throws {
        guard let record = index.records.first(where: { $0.id == id }) else { return }
        var updated = index
        updated.records.removeAll { $0.id == id }
        try commit(updated)
        removeFiles(for: record)
    }

    func clearOrdinary() throws {
        let removed = index.records.filter { !$0.isPinned }
        var updated = index
        updated.records.removeAll { !$0.isPinned }
        try commit(updated)
        removed.forEach(removeFiles)
    }

    func clearAll() throws {
        let removed = index.records
        try commit(.empty)
        removed.forEach(removeFiles)
    }

    func applyCleanupNow() throws {
        try applyCleanupAndCommit(index, now: clock())
    }

    func content(for record: ClipboardRecord) -> ClipboardContent? {
        guard let url = managedFileURL(for: record.fileName) else { return nil }
        switch record.kind {
        case .text:
            guard let data = try? Data(contentsOf: url),
                  data.count <= ClipboardLimits.maximumTextBytes else {
                return nil
            }
            return String(data: data, encoding: .utf8).map(ClipboardContent.text)
        case .image:
            guard let data = try? Data(contentsOf: url),
                  let image = ClipboardContentIdentifier.decodedImage(from: data) else {
                return nil
            }
            return .image(image)
        }
    }

    func thumbnail(for record: ClipboardRecord) -> NSImage? {
        guard let thumbnailFileName = record.thumbnailFileName,
              let url = managedFileURL(for: thumbnailFileName) else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    func text(for record: ClipboardRecord) -> String? {
        guard case .text(let value) = content(for: record) else { return nil }
        return value
    }

    private func updateDuplicate(
        _ capture: ClipboardCapture,
        now: Date
    ) throws -> ClipboardRecord? {
        guard let existingIndex = index.records.firstIndex(where: {
            $0.contentHash == capture.contentHash && $0.kind == capture.content.kind
        }) else {
            return nil
        }
        var updated = index
        updated.records[existingIndex].copiedAt = now
        updated.records[existingIndex].sourceBundleIdentifier = capture.sourceBundleIdentifier
        updated.records[existingIndex].sourceName = capture.sourceName
        try applyCleanupAndCommit(updated, now: now)
        return index.records.first {
            $0.contentHash == capture.contentHash && $0.kind == capture.content.kind
        }
    }

    private func applyCleanupAndCommit(
        _ candidate: ClipboardIndex,
        now: Date
    ) throws {
        var updated = candidate
        let pinned = updated.records.filter(\.isPinned)
        var ordinary = updated.records
            .filter { !$0.isPinned }
            .sorted { $0.copiedAt > $1.copiedAt }

        if settings.retentionEnabled {
            let cutoff = now.addingTimeInterval(-Double(settings.retentionDays) * 86_400)
            ordinary.removeAll { $0.copiedAt <= cutoff }
        }
        if ordinary.count > settings.maximumItems {
            ordinary.removeLast(ordinary.count - settings.maximumItems)
        }
        updated.records = pinned + ordinary
        let retainedIDs = Set(updated.records.map(\.id))
        let removed = index.records.filter { !retainedIDs.contains($0.id) }
        try commit(updated)
        removed.forEach(removeFiles)
    }

    private func commit(_ updated: ClipboardIndex) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                try container.encode(Self.iso8601String(from: date))
            }
            let data = try encoder.encode(updated)
            try fileWriter.write(data, to: indexURL)
            index = updated
        } catch {
            throw ClipboardStoreError.commitFailed(error.localizedDescription)
        }
    }

    private func removeFiles(for record: ClipboardRecord) {
        for fileName in [record.fileName, record.thumbnailFileName].compactMap({ $0 }) {
            guard let url = managedFileURL(for: fileName) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func managedFileURL(for fileName: String) -> URL? {
        guard !fileName.isEmpty,
              !fileName.hasPrefix("/"),
              !fileName.contains("/"),
              !fileName.contains("\\"),
              fileName != ".",
              fileName != ".." else {
            return nil
        }
        return directoryURL.appending(path: fileName)
    }

    private static func loadIndex(from url: URL) throws -> ClipboardIndex {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return .empty
        }
        do {
            let data = try Data(contentsOf: url)
            let envelope = try JSONDecoder().decode(VersionEnvelope.self, from: data)
            guard envelope.version == ClipboardIndex.currentVersion else {
                throw ClipboardStoreError.unsupportedIndexVersion(envelope.version)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let value = try container.decode(String.self)
                guard let date = Self.date(fromISO8601: value) else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "无效的剪贴板时间格式。"
                    )
                }
                return date
            }
            return try decoder.decode(ClipboardIndex.self, from: data)
        } catch let error as ClipboardStoreError {
            throw error
        } catch {
            throw ClipboardStoreError.corruptedIndex
        }
    }

    nonisolated private static func prepareFiles(
        id: UUID,
        capture: ClipboardCapture,
        directoryURL: URL,
        fileWriter: any ShortcutBindingFileWriting
    ) throws -> PreparedFile? {
        let bodyName: String
        let thumbnailName: String?
        let pixelSize: (Int, Int)?
        let bodyData: Data
        let thumbnailData: Data?
        try Task.checkCancellation()
        switch capture.content {
        case .text(let text):
            let data = Data(text.utf8)
            guard data.count <= ClipboardLimits.maximumTextBytes else { return nil }
            bodyName = "\(id.uuidString).txt"
            thumbnailName = nil
            pixelSize = nil
            bodyData = data
            thumbnailData = nil
        case .image(let image):
            guard let png = Self.pngData(image),
                  png.count <= ClipboardLimits.maximumImageBytes else {
                return nil
            }
            bodyName = "\(id.uuidString).png"
            thumbnailName = "\(id.uuidString)-thumb.png"
            pixelSize = (image.width, image.height)
            bodyData = png
            guard let thumbnail = Self.thumbnailPNG(image),
                  thumbnail.count <= ClipboardLimits.maximumImageBytes else {
                throw ClipboardStoreError.thumbnailFailed
            }
            thumbnailData = thumbnail
        }

        let bodyURL = directoryURL.appending(path: bodyName)
        let thumbnailURL = thumbnailName.map {
            directoryURL.appending(path: $0)
        }
        do {
            try Task.checkCancellation()
            try fileWriter.write(bodyData, to: bodyURL)
            if let thumbnailData, let thumbnailURL {
                try Task.checkCancellation()
                try fileWriter.write(thumbnailData, to: thumbnailURL)
            }
            return PreparedFile(
                bodyName: bodyName,
                thumbnailName: thumbnailName,
                pixelSize: pixelSize
            )
        } catch {
            try? FileManager.default.removeItem(at: bodyURL)
            if let thumbnailURL {
                try? FileManager.default.removeItem(at: thumbnailURL)
            }
            throw error
        }
    }

    nonisolated private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    nonisolated private static func thumbnailPNG(_ image: CGImage) -> Data? {
        let maximum: CGFloat = 160
        let scale = min(
            1,
            min(maximum / CGFloat(image.width), maximum / CGFloat(image.height))
        )
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let thumbnail = context.makeImage() else { return nil }
        return pngData(thumbnail)
    }

    private func removeFiles(for prepared: PreparedFile) {
        try? FileManager.default.removeItem(at: directoryURL.appending(path: prepared.bodyName))
        if let thumbnailName = prepared.thumbnailName {
            try? FileManager.default.removeItem(
                at: directoryURL.appending(path: thumbnailName)
            )
        }
    }

    nonisolated private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    nonisolated private static func date(fromISO8601 value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    private struct VersionEnvelope: Decodable {
        let version: Int
    }

    private struct PreparedFile: Sendable {
        let bodyName: String
        let thumbnailName: String?
        let pixelSize: (Int, Int)?
    }
}

enum ClipboardStoreError: LocalizedError, Equatable {
    case corruptedIndex
    case unsupportedIndexVersion(Int)
    case recordNotFound
    case commitFailed(String)
    case thumbnailFailed

    var errorDescription: String? {
        switch self {
        case .corruptedIndex:
            "剪贴板历史索引已损坏，原文件已保留。"
        case .unsupportedIndexVersion(let version):
            "剪贴板历史版本 \(version) 不受支持，原文件已保留。"
        case .recordNotFound:
            "剪贴板记录不存在。"
        case .commitFailed(let reason):
            "无法保存剪贴板历史：\(reason)"
        case .thumbnailFailed:
            "无法生成剪贴板图片缩略图。"
        }
    }
}
