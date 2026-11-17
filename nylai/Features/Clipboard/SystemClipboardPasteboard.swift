import AppKit

struct ClipboardPasteboardItemDescriptor: Equatable {
    let types: Set<String>
}

struct ClipboardPasteboardInspection: Equatable {
    let changeCount: Int
    let types: Set<String>
    let items: [ClipboardPasteboardItemDescriptor]
    let sourceBundleIdentifier: String?
}

enum ClipboardPasteboardAccessState: Equatable {
    case unknown
    case ask
    case allowed
    case denied
}

@MainActor
protocol ClipboardPasteboardAccessing: AnyObject {
    var changeCount: Int { get }
    var accessState: ClipboardPasteboardAccessState { get }
    func inspect() throws -> ClipboardPasteboardInspection
    func data(forItemAt index: Int, type: String) -> Data?
    func string(forItemAt index: Int, type: String) -> String?
    func write(_ content: ClipboardContent, sourceBundleIdentifier: String) throws
    func write(_ contents: [ClipboardContent], sourceBundleIdentifier: String) throws
    func writeRichText(
        _ richText: ClipboardRichTextPayload,
        sourceBundleIdentifier: String
    ) throws
}

extension ClipboardPasteboardAccessing {
    func write(
        _ contents: [ClipboardContent],
        sourceBundleIdentifier: String
    ) throws {
        guard contents.count == 1, let content = contents.first else {
            throw ClipboardPasteboardError.writeFailed
        }
        try write(content, sourceBundleIdentifier: sourceBundleIdentifier)
    }

    func writeRichText(
        _ richText: ClipboardRichTextPayload,
        sourceBundleIdentifier: String
    ) throws {
        try write(
            .text(richText.plainText),
            sourceBundleIdentifier: sourceBundleIdentifier
        )
    }
}

struct ClipboardRichTextPayload {
    let attributedString: NSAttributedString
    let htmlData: Data
    let plainText: String
}

@MainActor
enum ClipboardRichTextComposer {
    private static let maximumDisplayWidth: CGFloat = 520
    private static let maximumDisplayHeight: CGFloat = 640
    private static let maximumPayloadBytes = 64 * 1_024 * 1_024

    static func compose(_ contents: [ClipboardContent]) throws -> ClipboardRichTextPayload {
        guard !contents.isEmpty else {
            throw ClipboardPasteboardError.writeFailed
        }
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 8
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraph,
        ]
        var htmlBlocks: [String] = []
        var plainBlocks: [String] = []
        var totalBytes = 0

        for (index, content) in contents.enumerated() {
            switch content {
            case .text(let text):
                guard let data = text.data(using: .utf8),
                      data.count <= ClipboardLimits.maximumTextBytes else {
                    throw ClipboardPasteboardError.writeFailed
                }
                totalBytes += data.count
                result.append(NSAttributedString(
                    string: text,
                    attributes: textAttributes
                ))
                if index < contents.count - 1 {
                    result.append(NSAttributedString(
                        string: "\n",
                        attributes: textAttributes
                    ))
                }
                htmlBlocks.append(
                    "<div style=\"white-space:pre-wrap\">\(htmlEscaped(text))</div>"
                )
                plainBlocks.append(text)
            case .image(let image):
                let bitmap = NSBitmapImageRep(cgImage: image)
                guard let png = bitmap.representation(using: .png, properties: [:]),
                      png.count <= ClipboardLimits.maximumImageBytes else {
                    throw ClipboardPasteboardError.writeFailed
                }
                totalBytes += png.count
                let size = displaySize(for: image)
                let attachment = NSTextAttachment()
                let wrapper = FileWrapper(regularFileWithContents: png)
                wrapper.preferredFilename = "image-\(index + 1).png"
                attachment.fileWrapper = wrapper
                attachment.image = NSImage(cgImage: image, size: size)
                attachment.bounds = CGRect(origin: .zero, size: size)
                result.append(NSAttributedString(attachment: attachment))
                if index < contents.count - 1 {
                    result.append(NSAttributedString(
                        string: "\n",
                        attributes: textAttributes
                    ))
                }
                htmlBlocks.append(
                    """
                    <div><img src="data:image/png;base64,\(png.base64EncodedString())" \
                    style="max-width:\(Int(maximumDisplayWidth))px;\
                    max-height:\(Int(maximumDisplayHeight))px;width:auto;height:auto;"></div>
                    """
                )
                plainBlocks.append(L10n.shared.string("[图片]"))
            }
            guard totalBytes <= maximumPayloadBytes else {
                throw ClipboardPasteboardError.writeFailed
            }
        }

        let plainText = plainBlocks.joined(separator: "\n")
        guard let plainData = plainText.data(using: .utf8),
              plainData.count <= ClipboardLimits.maximumTextBytes else {
            throw ClipboardPasteboardError.writeFailed
        }
        let html = """
        <!doctype html>
        <html><head><meta charset="utf-8"></head>
        <body style="margin:0;font-family:-apple-system,BlinkMacSystemFont,sans-serif;\
        font-size:13px;line-height:1.45;color:#222;">
        \(htmlBlocks.joined(separator: "\n"))
        </body></html>
        """
        guard let htmlData = html.data(using: .utf8),
              htmlData.count <= maximumPayloadBytes else {
            throw ClipboardPasteboardError.writeFailed
        }
        return ClipboardRichTextPayload(
            attributedString: result,
            htmlData: htmlData,
            plainText: plainText
        )
    }

    private static func displaySize(for image: CGImage) -> NSSize {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0 else {
            return NSSize(width: 1, height: 1)
        }
        let scale = min(
            1,
            maximumDisplayWidth / width,
            maximumDisplayHeight / height
        )
        return NSSize(
            width: max(1, (width * scale).rounded()),
            height: max(1, (height * scale).rounded())
        )
    }

    private static func htmlEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

enum ClipboardPasteboardError: LocalizedError, Equatable {
    case readFailed
    case writeFailed
    case accessNotGranted

    var errorDescription: String? {
        switch self {
        case .readFailed:
            L10n.shared.string(
                "系统剪贴板访问被拒绝或读取失败。请在系统设置的剪贴板权限中允许 %@。",
                AppName.current
            )
        case .writeFailed:
            L10n.shared.string("无法写入系统剪贴板。")
        case .accessNotGranted:
            L10n.shared.string("系统剪贴板访问尚未允许。请在系统提示中允许后重试。")
        }
    }
}

@MainActor
final class SystemClipboardPasteboard: ClipboardPasteboardAccessing {
    static let sourceType = "org.nspasteboard.source"
    static let concealedType = "org.nspasteboard.Concealed"
    static let transientType = "org.nspasteboard.TransientType"
    static let autoGeneratedType = "org.nspasteboard.AutoGeneratedType"
    static let selfWriteType = "com.noname4me.nylai.clipboard-write"
    static let textType = NSPasteboard.PasteboardType.string.rawValue
    static let pngType = NSPasteboard.PasteboardType.png.rawValue
    static let tiffType = NSPasteboard.PasteboardType.tiff.rawValue

    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    var accessState: ClipboardPasteboardAccessState {
        guard #available(macOS 15.4, *) else { return .unknown }
        switch pasteboard.accessBehavior {
        case .default:
            return .unknown
        case .ask:
            return .ask
        case .alwaysAllow:
            return .allowed
        case .alwaysDeny:
            return .denied
        @unknown default:
            return .unknown
        }
    }

    func inspect() throws -> ClipboardPasteboardInspection {
        guard let items = pasteboard.pasteboardItems else {
            return ClipboardPasteboardInspection(
                changeCount: pasteboard.changeCount,
                types: Set((pasteboard.types ?? []).map(\.rawValue)),
                items: [],
                sourceBundleIdentifier: nil
            )
        }
        let source = pasteboard.string(forType: NSPasteboard.PasteboardType(Self.sourceType))
        return ClipboardPasteboardInspection(
            changeCount: pasteboard.changeCount,
            types: Set((pasteboard.types ?? []).map(\.rawValue)),
            items: items.map {
                ClipboardPasteboardItemDescriptor(
                    types: Set($0.types.map(\.rawValue))
                )
            },
            sourceBundleIdentifier: source
        )
    }

    func data(forItemAt index: Int, type: String) -> Data? {
        guard let items = pasteboard.pasteboardItems,
              items.indices.contains(index) else {
            return nil
        }
        return items[index].data(forType: NSPasteboard.PasteboardType(type))
    }

    func string(forItemAt index: Int, type: String) -> String? {
        guard let items = pasteboard.pasteboardItems,
              items.indices.contains(index) else {
            return nil
        }
        return items[index].string(forType: NSPasteboard.PasteboardType(type))
    }

    func write(_ content: ClipboardContent, sourceBundleIdentifier: String) throws {
        try write([content], sourceBundleIdentifier: sourceBundleIdentifier)
    }

    func write(_ contents: [ClipboardContent], sourceBundleIdentifier: String) throws {
        guard !contents.isEmpty else {
            throw ClipboardPasteboardError.writeFailed
        }
        let items = try contents.map { content -> NSPasteboardItem in
            let item = NSPasteboardItem()
            switch content {
            case .text(let text):
                guard let data = text.data(using: .utf8),
                      data.count <= ClipboardLimits.maximumTextBytes,
                      item.setData(data, forType: .string) else {
                    throw ClipboardPasteboardError.writeFailed
                }
            case .image(let image):
                let bitmap = NSBitmapImageRep(cgImage: image)
                guard let data = bitmap.representation(using: .png, properties: [:]),
                      data.count <= ClipboardLimits.maximumImageBytes,
                      item.setData(data, forType: .png) else {
                    throw ClipboardPasteboardError.writeFailed
                }
            }
            guard item.setData(
                Data(),
                forType: NSPasteboard.PasteboardType(Self.selfWriteType)
            ),
            item.setString(
                sourceBundleIdentifier,
                forType: NSPasteboard.PasteboardType(Self.sourceType)
            ) else {
                throw ClipboardPasteboardError.writeFailed
            }
            return item
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(items) else {
            throw ClipboardPasteboardError.writeFailed
        }
    }

    func writeRichText(
        _ richText: ClipboardRichTextPayload,
        sourceBundleIdentifier: String
    ) throws {
        let range = NSRange(
            location: 0,
            length: richText.attributedString.length
        )
        let item = NSPasteboardItem()
        var wroteRichRepresentation = false
        if let wrapper = richText.attributedString.rtfdFileWrapper(
            from: range,
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.rtfd,
            ]
        ),
        let data = wrapper.serializedRepresentation,
        item.setData(data, forType: .rtfd) {
            wroteRichRepresentation = true
        }
        if !richText.htmlData.isEmpty,
           item.setData(richText.htmlData, forType: .html) {
            wroteRichRepresentation = true
        }
        guard wroteRichRepresentation,
              item.setString(richText.plainText, forType: .string),
              item.setData(
                  Data(),
                  forType: NSPasteboard.PasteboardType(Self.selfWriteType)
              ),
              item.setString(
                  sourceBundleIdentifier,
                  forType: NSPasteboard.PasteboardType(Self.sourceType)
              ) else {
            throw ClipboardPasteboardError.writeFailed
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            throw ClipboardPasteboardError.writeFailed
        }
    }
}

@MainActor
struct ClipboardChangeReader {
    static func snapshot(
        from pasteboard: any ClipboardPasteboardAccessing,
        frontmostBundleIdentifier: String?,
        frontmostApplicationName: String?
    ) throws -> ClipboardPayloadSnapshot {
        let inspection = try pasteboard.inspect()
        let allTypes = inspection.types.union(
            inspection.items.reduce(into: Set<String>()) { $0.formUnion($1.types) }
        )
        let isSelfWrite = allTypes.contains(SystemClipboardPasteboard.selfWriteType)
        let isSensitive = allTypes.contains(SystemClipboardPasteboard.concealedType)
            || allTypes.contains(SystemClipboardPasteboard.transientType)
            || allTypes.contains(SystemClipboardPasteboard.autoGeneratedType)
        let source = inspection.sourceBundleIdentifier
            ?? inspection.items.indices.lazy.compactMap {
                pasteboard.string(
                    forItemAt: $0,
                    type: SystemClipboardPasteboard.sourceType
                )
            }.first
        let sourceName = source.flatMap(applicationName(for:)) ?? frontmostApplicationName
        guard !isSelfWrite, !isSensitive else {
            return ClipboardPayloadSnapshot(
                changeCount: inspection.changeCount,
                items: [],
                sourceBundleIdentifier: source,
                frontmostBundleIdentifier: frontmostBundleIdentifier,
                sourceName: sourceName,
                isSelfWrite: isSelfWrite,
                isSensitive: isSensitive
            )
        }

        var items: [ClipboardItemPayload] = []
        for (index, descriptor) in inspection.items.enumerated() {
            if descriptor.types.contains(SystemClipboardPasteboard.pngType)
                || descriptor.types.contains(SystemClipboardPasteboard.tiffType)
                || descriptor.types.contains("public.jpeg")
                || descriptor.types.contains("public.heic") {
                if let data = readImageData(
                    at: index,
                    descriptor: descriptor,
                    pasteboard: pasteboard
                ) {
                    items.append(.image(data))
                }
                continue
            }
            if let text = readText(at: index, descriptor: descriptor, pasteboard: pasteboard) {
                items.append(.text(text))
            }
        }
        return ClipboardPayloadSnapshot(
            changeCount: inspection.changeCount,
            items: items,
            sourceBundleIdentifier: source,
            frontmostBundleIdentifier: frontmostBundleIdentifier,
            sourceName: sourceName,
            isSelfWrite: false,
            isSensitive: false
        )
    }

    nonisolated static func decode(_ snapshot: ClipboardPayloadSnapshot) async -> ClipboardObservedChange {
        var items: [ClipboardObservedItem] = []
        for payload in snapshot.items {
            guard !Task.isCancelled else { break }
            switch payload {
            case .image(let data):
                guard let image = ClipboardContentIdentifier.decodedImage(from: data),
                      let hash = ClipboardContentIdentifier.image(image) else {
                    continue
                }
                items.append(ClipboardObservedItem(content: .image(image), contentHash: hash))
            case .text(let text):
                guard let hash = ClipboardContentIdentifier.text(text) else { continue }
                items.append(ClipboardObservedItem(content: .text(text), contentHash: hash))
            }
        }
        return ClipboardObservedChange(
            changeCount: snapshot.changeCount,
            items: items,
            sourceBundleIdentifier: snapshot.sourceBundleIdentifier,
            frontmostBundleIdentifier: snapshot.frontmostBundleIdentifier,
            sourceName: snapshot.sourceName,
            isSelfWrite: snapshot.isSelfWrite,
            isSensitive: snapshot.isSensitive
        )
    }

    private static func readImageData(
        at index: Int,
        descriptor: ClipboardPasteboardItemDescriptor,
        pasteboard: any ClipboardPasteboardAccessing
    ) -> Data? {
        let candidates = [
            SystemClipboardPasteboard.pngType,
            SystemClipboardPasteboard.tiffType,
            "public.jpeg",
            "public.heic",
        ]
        guard let type = candidates.first(where: descriptor.types.contains),
              let data = pasteboard.data(forItemAt: index, type: type),
              data.count <= ClipboardLimits.maximumImageBytes else {
            return nil
        }
        return data
    }

    private static func readText(
        at index: Int,
        descriptor: ClipboardPasteboardItemDescriptor,
        pasteboard: any ClipboardPasteboardAccessing
    ) -> String? {
        let candidates = [
            SystemClipboardPasteboard.textType,
            "public.utf8-plain-text",
            "NSStringPboardType",
        ]
        guard let type = candidates.first(where: descriptor.types.contains),
              let value = pasteboard.string(forItemAt: index, type: type),
              Data(value.utf8).count <= ClipboardLimits.maximumTextBytes else {
            return nil
        }
        return value
    }

    static func applicationName(for bundleIdentifier: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }
}
