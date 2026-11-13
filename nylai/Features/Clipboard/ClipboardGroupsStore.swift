import Foundation
import Observation

enum ClipboardGroupColor: String, Codable, CaseIterable, Sendable {
    case red, orange, yellow, green, blue, purple, gray
}

struct ClipboardGroup: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var color: ClipboardGroupColor = .blue
    var recordIDs: Set<UUID> = []
}

enum ClipboardGroupError: LocalizedError {
    case invalidName, unsupportedVersion
    var errorDescription: String? {
        L10n.shared.string(self == .invalidName ? "请输入不重复的分组名称。" : "剪贴板分组的数据版本不受支持。")
    }
}

@MainActor
@Observable
final class ClipboardGroupsStore {
    private struct Archive: Codable {
        var version = 1
        var migratedLegacyItems = false
        var groups: [ClipboardGroup] = []
        var names: [UUID: String] = [:]
        var aliases: [UUID: [String]]?
        var reconciledLegacyNames: Bool?
    }
    private var archive: Archive
    private let fileURL: URL
    private let writer: any ShortcutBindingFileWriting
    var groups: [ClipboardGroup] { archive.groups }
    func name(for id: UUID) -> String? {
        let names = [archive.names[id]].compactMap { $0 } + (archive.aliases?[id] ?? [])
        return names.isEmpty ? nil : names.joined(separator: " · ")
    }

    init(fileURL: URL, writer: any ShortcutBindingFileWriting = AtomicShortcutBindingFileWriter()) throws {
        self.fileURL = fileURL
        self.writer = writer
        if FileManager.default.fileExists(atPath: fileURL.path) {
            archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: fileURL))
            guard archive.version == 1 else { throw ClipboardGroupError.unsupportedVersion }
        } else { archive = Archive() }
    }

    func save(_ group: ClipboardGroup) throws {
        var group = group
        group.name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !group.name.isEmpty, !groups.contains(where: { $0.id != group.id && $0.name.localizedCaseInsensitiveCompare(group.name) == .orderedSame }) else {
            throw ClipboardGroupError.invalidName
        }
        var next = archive
        if let index = next.groups.firstIndex(where: { $0.id == group.id }) { next.groups[index] = group }
        else { next.groups.append(group) }
        try commit(next)
    }

    func setMembership(_ ids: Set<UUID>, groupID: UUID, included: Bool, history: ClipboardHistoryStore) throws {
        guard let index = archive.groups.firstIndex(where: { $0.id == groupID }) else { return }
        var next = archive
        if included {
            // Grouped records reuse history's existing retention protection.
            // Protect bodies before publishing memberships, so a write failure
            // never leaves a saved group pointing at an evicted record.
            for id in ids { try history.setPinned(true, id: id) }
            next.groups[index].recordIDs.formUnion(ids)
        } else { next.groups[index].recordIDs.subtract(ids) }
        try commit(next)
        if !included { try releaseUnassigned(ids, history: history) }
    }

    func delete(_ id: UUID, history: ClipboardHistoryStore) throws {
        let members = archive.groups.first { $0.id == id }?.recordIDs ?? []
        var next = archive
        next.groups.removeAll { $0.id == id }
        try commit(next)
        try releaseUnassigned(members, history: history)
    }

    func clearMembers(of id: UUID, history: ClipboardHistoryStore) throws {
        guard let index = archive.groups.firstIndex(where: { $0.id == id }) else { return }
        let members = archive.groups[index].recordIDs
        guard !members.isEmpty else { return }
        let retainedByOtherGroups = archive.groups
            .filter { $0.id != id }
            .reduce(into: Set<UUID>()) { $0.formUnion($1.recordIDs) }
        let removable = members.subtracting(retainedByOtherGroups)
        var next = archive
        next.groups[index].recordIDs = []
        next.names = next.names.filter { !removable.contains($0.key) }
        next.aliases = next.aliases?.filter { !removable.contains($0.key) }
        try commit(next)
        try history.delete(ids: removable)
    }

    func clearAllMemberships() throws {
        guard archive.groups.contains(where: { !$0.recordIDs.isEmpty })
                || !archive.names.isEmpty
                || archive.aliases?.isEmpty == false else {
            return
        }
        var next = archive
        next.groups = next.groups.map { group in
            var group = group
            group.recordIDs = []
            return group
        }
        next.names = [:]
        next.aliases = nil
        try commit(next)
    }

    func migrateLegacyItems(history: ClipboardHistoryStore, snippets: SnippetStore) throws {
        var next = archive
        func keepName(_ name: String, for id: UUID) {
            if next.names[id] == nil { next.names[id] = name }
            else if next.names[id] != name, !(next.aliases?[id] ?? []).contains(name) {
                var aliases = next.aliases ?? [:]
                aliases[id, default: []].append(name)
                next.aliases = aliases
            }
        }
        if archive.migratedLegacyItems {
            guard archive.reconciledLegacyNames != true else { return }
            // Recover names from an earlier migration without recreating any
            // group or item the user has since removed.
            for snippet in snippets.snippets {
                if let hash = ClipboardContentIdentifier.text(snippet.text),
                   let record = history.allRecords.first(where: { $0.contentHash == hash }) {
                    keepName(snippet.name, for: record.id)
                }
            }
            next.reconciledLegacyNames = true
            try commit(next)
            return
        }
        func groupIndex(_ name: String, color: ClipboardGroupColor) -> Int {
            if let index = next.groups.firstIndex(where: { $0.name == name }) { return index }
            next.groups.append(ClipboardGroup(name: name, color: color))
            return next.groups.count - 1
        }
        let pinned = Set(history.pinnedRecords.map(\.id))
        if !pinned.isEmpty {
            let index = groupIndex(L10n.shared.string("收藏"), color: .yellow)
            next.groups[index].recordIDs.formUnion(pinned)
        }
        for snippet in snippets.snippets {
            guard let hash = ClipboardContentIdentifier.text(snippet.text),
                  let record = try history.add(ClipboardCapture(content: .text(snippet.text), sourceBundleIdentifier: nil,
                                                              sourceName: L10n.shared.string("常用短语"), contentHash: hash), retained: true) else { continue }
            try history.setPinned(true, id: record.id)
            let index = groupIndex(snippet.group.isEmpty ? L10n.shared.string("常用") : snippet.group, color: .blue)
            next.groups[index].recordIDs.insert(record.id)
            keepName(snippet.name, for: record.id)
        }
        next.migratedLegacyItems = true
        next.reconciledLegacyNames = true
        try commit(next)
    }

    private func releaseUnassigned(_ ids: Set<UUID>, history: ClipboardHistoryStore) throws {
        let retained = groups.reduce(into: Set<UUID>()) { $0.formUnion($1.recordIDs) }
        for id in ids.subtracting(retained) where history.allRecords.contains(where: { $0.id == id }) {
            try history.setPinned(false, id: id, cleanup: false)
        }
    }

    private func commit(_ next: Archive) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writer.write(JSONEncoder().encode(next), to: fileURL)
        archive = next
    }
}
