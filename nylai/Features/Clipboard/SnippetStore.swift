import Foundation
import Observation

struct SavedSnippet: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var group: String
    var text: String
}

enum SnippetError: LocalizedError {
    case invalid, unsupportedVersion
    var errorDescription: String? {
        L10n.shared.string(self == .invalid ? "请填写短语名称和内容。" : "常用短语的数据版本不受支持。")
    }
}

@MainActor
@Observable
final class SnippetStore {
    private struct Archive: Codable {
        var version = 1
        var snippets: [SavedSnippet]
    }
    private(set) var snippets: [SavedSnippet]
    private let fileURL: URL
    private let writer: any ShortcutBindingFileWriting

    init(fileURL: URL, writer: any ShortcutBindingFileWriting = AtomicShortcutBindingFileWriter()) throws {
        self.fileURL = fileURL
        self.writer = writer
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: fileURL))
            guard archive.version == 1 else { throw SnippetError.unsupportedVersion }
            snippets = archive.snippets
        } else { snippets = [] }
    }

    func matches(_ query: String) -> [SavedSnippet] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return snippets.filter {
            query.isEmpty || [$0.name, $0.group, $0.text].contains { $0.localizedCaseInsensitiveContains(query) }
        }.sorted {
            if $0.group != $1.group { return $0.group.localizedStandardCompare($1.group) == .orderedAscending }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func save(_ draft: SavedSnippet) throws {
        var snippet = draft
        snippet.name = snippet.name.trimmingCharacters(in: .whitespacesAndNewlines)
        snippet.group = snippet.group.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !snippet.name.isEmpty, !snippet.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SnippetError.invalid }
        var next = snippets
        if let index = next.firstIndex(where: { $0.id == snippet.id }) { next[index] = snippet }
        else { next.append(snippet) }
        try commit(next)
    }

    func delete(_ id: UUID) throws { try commit(snippets.filter { $0.id != id }) }

    private func commit(_ next: [SavedSnippet]) throws {
        let data = try JSONEncoder().encode(Archive(snippets: next))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writer.write(data, to: fileURL)
        snippets = next
    }
}
