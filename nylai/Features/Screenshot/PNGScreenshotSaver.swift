import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
protocol ScreenshotSaving {
    // 返回 nil 表示用户取消，不是保存失败。
    func save(_ image: CGImage) async throws -> URL?
}

// 编码与磁盘写入在独立 actor 上完成，避免阻塞主线程。
actor PNGImageWriter {
    func write(_ image: CGImage, to url: URL) throws {
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ScreenshotError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ScreenshotError.encodingFailed }
        try Task.checkCancellation()
        try (data as Data).write(to: url, options: .atomic)
    }
}

@MainActor
final class PNGScreenshotSaver: ScreenshotSaving {
    private let writer = PNGImageWriter()

    func save(_ image: CGImage) async throws -> URL? {
        try Task.checkCancellation()
        let panel = NSSavePanel()
        panel.title = "保存截图"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        panel.nameFieldStringValue = "nylai-\(formatter.string(from: Date())).png"
        NSApp.activate(ignoringOtherApps: true)
        guard await panel.begin() == .OK, let url = panel.url else { return nil }
        try Task.checkCancellation()
        try await writer.write(image, to: url)
        return url
    }
}
