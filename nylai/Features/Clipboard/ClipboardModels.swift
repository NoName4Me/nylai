import AppKit
import CryptoKit
import ImageIO

enum ClipboardContentKind: String, Codable, Sendable {
    case text
    case image
}

struct ClipboardRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var kind: ClipboardContentKind
    var contentHash: String
    var fileName: String
    var thumbnailFileName: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var sourceBundleIdentifier: String?
    var sourceName: String?
    var copiedAt: Date
    var pinnedAt: Date?

    var isPinned: Bool { pinnedAt != nil }
}

struct ClipboardIndex: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version: Int
    var records: [ClipboardRecord]

    static let empty = ClipboardIndex(version: currentVersion, records: [])
}

struct ClipboardSettings: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version: Int
    var maximumItems: Int
    var retentionEnabled: Bool
    var retentionDays: Int
    var disabledBundleIdentifiers: Set<String>

    static let defaults = ClipboardSettings(
        version: currentVersion,
        maximumItems: 200,
        retentionEnabled: false,
        retentionDays: 30,
        disabledBundleIdentifiers: []
    )

    func validated() -> ClipboardSettings {
        var value = self
        value.version = Self.currentVersion
        value.maximumItems = min(max(value.maximumItems, 1), 5_000)
        value.retentionDays = min(max(value.retentionDays, 1), 365)
        return value
    }
}

enum ClipboardContent: @unchecked Sendable {
    case text(String)
    case image(CGImage)

    var kind: ClipboardContentKind {
        switch self {
        case .text: .text
        case .image: .image
        }
    }
}

struct ClipboardCapture: @unchecked Sendable {
    let content: ClipboardContent
    let sourceBundleIdentifier: String?
    let sourceName: String?
    let contentHash: String
}

struct ClipboardObservedItem: Sendable {
    let content: ClipboardContent
    let contentHash: String
}

struct ClipboardPayloadSnapshot: Sendable {
    let changeCount: Int
    let items: [ClipboardItemPayload]
    let sourceBundleIdentifier: String?
    let frontmostBundleIdentifier: String?
    let sourceName: String?
    let isSelfWrite: Bool
    let isSensitive: Bool
}

enum ClipboardItemPayload: Sendable {
    case text(String)
    case image(Data)
}

struct ClipboardObservedChange: Sendable {
    let changeCount: Int
    let items: [ClipboardObservedItem]
    let sourceBundleIdentifier: String?
    let frontmostBundleIdentifier: String?
    let sourceName: String?
    let isSelfWrite: Bool
    let isSensitive: Bool
}

enum ClipboardLimits {
    static let maximumTextBytes = 1 * 1_024 * 1_024
    static let maximumImageBytes = 20 * 1_024 * 1_024
    static let maximumImagePixels = 40_000_000
}

enum ClipboardContentIdentifier {
    static func text(_ value: String) -> String? {
        let data = Data(value.utf8)
        guard data.count <= ClipboardLimits.maximumTextBytes else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func image(_ image: CGImage) -> String? {
        guard image.width > 0,
              image.height > 0,
              image.width <= ClipboardLimits.maximumImagePixels / image.height else {
            return nil
        }
        guard let normalized = normalizedRGBA(image) else { return nil }
        return SHA256.hash(data: normalized).map { String(format: "%02x", $0) }.joined()
    }

    static func decodedImage(from data: Data) -> CGImage? {
        guard data.count <= ClipboardLimits.maximumImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0,
              height.intValue > 0,
              width.intValue <= ClipboardLimits.maximumImagePixels / height.intValue else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func normalizedRGBA(_ image: CGImage) -> Data? {
        var bytes = Data(count: image.width * image.height * 4)
        let created = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
            return true
        }
        return created ? bytes : nil
    }
}

enum ClipboardSettingsError: LocalizedError, Equatable {
    case invalidVersion(Int)

    var errorDescription: String? {
        "剪贴板配置版本 \(caseValue) 不受支持。"
    }

    private var caseValue: Int {
        if case .invalidVersion(let value) = self { return value }
        return 0
    }
}
