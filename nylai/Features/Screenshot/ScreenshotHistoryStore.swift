import AppKit
import Foundation
import Observation

protocol ScreenshotHistoryFileManaging {
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool) throws
    func fileExists(atPath path: String) -> Bool
    func contents(atPath path: String) -> Data?
    func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws
    func removeItem(at url: URL) throws
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws
}

extension FileManager: ScreenshotHistoryFileManaging {
    func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool
    ) throws {
        try createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: nil
        )
    }

    func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        try data.write(to: url, options: options)
    }
}

struct ScreenshotHistoryRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let imageFileName: String
    let thumbnailFileName: String
    let createdAt: Date
    let width: Int
    let height: Int
}

enum ScreenshotHistoryStoreError: LocalizedError, Equatable {
    case invalidImage
    case indexWriteFailed
    case imageWriteFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            L10n.shared.string("无法编码截图历史图片。")
        case .indexWriteFailed:
            L10n.shared.string("无法写入截图历史索引。")
        case .imageWriteFailed:
            L10n.shared.string("无法写入截图历史图片。")
        }
    }
}

@MainActor
@Observable
final class ScreenshotHistoryStore {
    static let maximumRecordCount = 50
    private static let indexName = "index.json"
    private static let indexVersion = 1

    let directory: URL
    private let fileManager: any ScreenshotHistoryFileManaging
    private let now: () -> Date
    private(set) var records: [ScreenshotHistoryRecord] = []
    private(set) var loadError: String?

    init(
        directory: URL = ScreenshotHistoryStore.defaultDirectory(),
        fileManager: any ScreenshotHistoryFileManaging = FileManager.default,
        now: @escaping () -> Date = Date.init
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.now = now
        reload()
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("nylai", isDirectory: true)
            .appendingPathComponent("ScreenshotHistory", isDirectory: true)
    }

    func reload() {
        records = []
        loadError = nil
        let url = directory.appendingPathComponent(Self.indexName)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            guard let data = fileManager.contents(atPath: url.path) else {
                throw CocoaError(.fileReadUnknown)
            }
            let index = try JSONDecoder().decode(IndexFile.self, from: data)
            guard index.version == Self.indexVersion else {
                loadError = L10n.shared.string("截图历史索引版本不受支持。")
                preserveCorruptIndex(at: url)
                return
            }
            records = Array(index.records.prefix(Self.maximumRecordCount))
        } catch {
            loadError = L10n.shared.string(
                "截图历史索引损坏：%@",
                error.localizedDescription
            )
            preserveCorruptIndex(at: url)
        }
    }

    @discardableResult
    func add(_ image: CGImage) throws -> ScreenshotHistoryRecord? {
        try ensureDirectory()
        let id = UUID()
        let imageName = "\(id.uuidString).png"
        let thumbnailName = "\(id.uuidString)-thumb.png"
        let imageURL = directory.appendingPathComponent(imageName)
        let thumbnailURL = directory.appendingPathComponent(thumbnailName)
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let imageData = bitmap.representation(using: .png, properties: [:]) else {
            throw ScreenshotHistoryStoreError.invalidImage
        }
        let thumbnail = try thumbnailImage(from: image)
        guard let thumbnailData = NSBitmapImageRep(cgImage: thumbnail)
            .representation(using: .png, properties: [:]) else {
            throw ScreenshotHistoryStoreError.invalidImage
        }
        do {
            try fileManager.write(imageData, to: imageURL, options: .atomic)
            try fileManager.write(thumbnailData, to: thumbnailURL, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: imageURL)
            try? fileManager.removeItem(at: thumbnailURL)
            throw ScreenshotHistoryStoreError.imageWriteFailed
        }

        let record = ScreenshotHistoryRecord(
            id: id,
            imageFileName: imageName,
            thumbnailFileName: thumbnailName,
            createdAt: now(),
            width: image.width,
            height: image.height
        )
        let keptCount = max(0, Self.maximumRecordCount - 1)
        let kept = Array(records.prefix(keptCount))
        let evicted = Array(records.dropFirst(keptCount))
        do {
            try writeIndex([record] + kept)
        } catch {
            try? fileManager.removeItem(at: imageURL)
            try? fileManager.removeItem(at: thumbnailURL)
            throw ScreenshotHistoryStoreError.indexWriteFailed
        }
        records = [record] + kept
        for old in evicted {
            removeFiles(for: old)
        }
        return record
    }

    func image(for record: ScreenshotHistoryRecord) -> NSImage? {
        guard let url = managedFileURL(for: record.imageFileName) else { return nil }
        return NSImage(contentsOf: url)
    }

    func thumbnail(for record: ScreenshotHistoryRecord) -> NSImage? {
        guard let url = managedFileURL(for: record.thumbnailFileName) else { return nil }
        return NSImage(contentsOf: url)
    }

    func delete(_ record: ScreenshotHistoryRecord) throws {
        let updated = records.filter { $0.id != record.id }
        try writeIndex(updated)
        records = updated
        removeFiles(for: record)
    }

    func clear() throws {
        let removed = records
        try writeIndex([])
        records = []
        for record in removed {
            removeFiles(for: record)
        }
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    private func writeIndex(_ records: [ScreenshotHistoryRecord]) throws {
        try ensureDirectory()
        let url = directory.appendingPathComponent(Self.indexName)
        let index = IndexFile(version: Self.indexVersion, records: records)
        let data = try JSONEncoder().encode(index)
        try fileManager.write(data, to: url, options: .atomic)
    }

    private func preserveCorruptIndex(at url: URL) {
        let backup = directory.appendingPathComponent(
            "index.corrupt-\(Int(Date().timeIntervalSince1970)).json"
        )
        try? fileManager.copyItem(at: url, to: backup)
    }

    private func removeFiles(for record: ScreenshotHistoryRecord) {
        for fileName in [record.imageFileName, record.thumbnailFileName] {
            guard let url = managedFileURL(for: fileName) else { continue }
            try? fileManager.removeItem(at: url)
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
        return directory.appendingPathComponent(fileName)
    }

    private func thumbnailImage(from image: CGImage) throws -> CGImage {
        let maximumSize = CGSize(width: 400, height: 260)
        let scale = min(
            maximumSize.width / CGFloat(image.width),
            maximumSize.height / CGFloat(image.height),
            1
        )
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ScreenshotHistoryStoreError.invalidImage
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let output = context.makeImage() else {
            throw ScreenshotHistoryStoreError.invalidImage
        }
        return output
    }

    private struct IndexFile: Codable {
        let version: Int
        let records: [ScreenshotHistoryRecord]
    }
}
