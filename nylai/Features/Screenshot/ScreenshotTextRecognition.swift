import AppKit
import Vision

enum RecognizedTextLayout: String, CaseIterable, Sendable {
    case lines, paragraph

    var title: String {
        L10n.shared.string(self == .lines ? "保留换行" : "合并为一段")
    }

    func format(_ lines: [String]) -> String {
        lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: self == .lines ? "\n" : " ")
    }
}

enum TextRecognitionError: LocalizedError {
    case noText

    var errorDescription: String? { L10n.shared.string("未识别到文字，请扩大选区或选择更清晰的图片。") }
}

enum ScreenshotTextRecognition {
    static func recognizeLines(_ image: CGImage) async throws -> [RecognizedTextLine] {
        // Keep Vision off the UI thread. The immutable image travels in the same
        // Sendable container used by the clipboard pipeline.
        let input = ClipboardContent.image(image)
        let task = Task.detached(priority: .userInitiated) {
            guard case .image(let image) = input else { throw TextRecognitionError.noText }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            try Task.checkCancellation()
            let lines = (request.results ?? []).compactMap { observation -> RecognizedTextLine? in
                guard let text = observation.topCandidates(1).first?.string,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return RecognizedTextLine(text: text, box: observation.boundingBox)
            }
            guard !lines.isEmpty else { throw TextRecognitionError.noText }
            return lines
        }
        return try await withTaskCancellationHandler {
            let text = try await task.value
            try Task.checkCancellation()
            return text
        } onCancel: { task.cancel() }
    }

    static func recognize(_ image: CGImage, layout: RecognizedTextLayout) async throws -> String {
        layout.format(try await recognizeLines(image).map(\.text))
    }

    @MainActor
    static func review(_ image: CGImage, layout: RecognizedTextLayout) async throws {
        let lines = try await recognizeLines(image)
        try Task.checkCancellation()
        ScreenshotTextReviewManager.shared.present(image: image, lines: lines, layout: layout)
    }

    @MainActor
    static func copy(_ image: CGImage, layout: RecognizedTextLayout) async throws {
        let text = try await recognize(image, layout: layout)
        try Task.checkCancellation()
        try SystemClipboardPasteboard().write(.text(text), sourceBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.noname4me.nylai")
    }
}

@MainActor
final class TextRecognitionMenu: NSObject {
    var onSelect: (RecognizedTextLayout) -> Void = { _ in }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        for (index, layout) in RecognizedTextLayout.allCases.enumerated() {
            let item = NSMenuItem(title: layout.title, action: #selector(selected(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func selected(_ sender: NSMenuItem) {
        guard RecognizedTextLayout.allCases.indices.contains(sender.tag) else { return }
        onSelect(RecognizedTextLayout.allCases[sender.tag])
    }
}
