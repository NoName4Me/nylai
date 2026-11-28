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
    var pinnedAt: [UUID: Date]?
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
    var memberIDs: Set<UUID> {
        groups.reduce(into: []) { $0.formUnion($1.recordIDs) }
    }

    func group(for recordID: UUID) -> ClipboardGroup? {
        groups.first { $0.recordIDs.contains(recordID) }
    }

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
        if let index = next.groups.firstIndex(where: { $0.id == group.id }) {
            next.groups[index].name = group.name
            next.groups[index].color = group.color
        } else {
            next.groups.append(ClipboardGroup(id: group.id, name: group.name, color: group.color))
        }
        try commit(next)
    }

    func setMembership(_ ids: Set<UUID>, groupID: UUID, included: Bool, history: ClipboardHistoryStore) throws {
        guard let index = archive.groups.firstIndex(where: { $0.id == groupID }) else { return }
        var next = archive
        if included && !ids.isSubset(of: Set(history.index.records.map(\.id))) {
            throw ClipboardStoreError.recordNotFound
        }
        for position in next.groups.indices where included ? position != index : position == index {
            next.groups[position].recordIDs.subtract(ids)
            next.groups[position].pinnedAt = next.groups[position].pinnedAt?.filter { !ids.contains($0.key) }
        }
        if included { next.groups[index].recordIDs.formUnion(ids) }
        try commit(next)
    }

    func setPinned(_ pinned: Bool, recordID: UUID, groupID: UUID, at date: Date) throws {
        guard let index = groups.firstIndex(where: { $0.id == groupID && $0.recordIDs.contains(recordID) }) else {
            throw ClipboardStoreError.recordNotFound
        }
        var next = archive
        var pins = next.groups[index].pinnedAt ?? [:]
        if pinned { pins[recordID] = pins[recordID] ?? date }
        else { pins.removeValue(forKey: recordID) }
        next.groups[index].pinnedAt = pins.isEmpty ? nil : pins
        try commit(next)
    }

    func delete(_ id: UUID) throws {
        var next = archive
        next.groups.removeAll { $0.id == id }
        try commit(next)
    }

    func clearMembers(of id: UUID, history: ClipboardHistoryStore) throws {
        guard let index = archive.groups.firstIndex(where: { $0.id == id }) else { return }
        let members = archive.groups[index].recordIDs
        guard !members.isEmpty else { return }
        try history.delete(ids: members)
        var next = archive
        next.groups[index].recordIDs = []
        next.groups[index].pinnedAt = nil
        next.names = next.names.filter { !members.contains($0.key) }
        next.aliases = next.aliases?.filter { !members.contains($0.key) }
        try commit(next)
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
            group.pinnedAt = nil
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
            let index = groupIndex(snippet.group.isEmpty ? L10n.shared.string("常用") : snippet.group, color: .blue)
            next.groups[index].recordIDs.insert(record.id)
            keepName(snippet.name, for: record.id)
        }
        next.migratedLegacyItems = true
        next.reconciledLegacyNames = true
        try commit(next)
    }

    func migrateGroupPins(_ legacyPins: [UUID: Date]) throws {
        var next = archive
        var assigned: Set<UUID> = []
        for index in next.groups.indices {
            let members = next.groups[index].recordIDs.subtracting(assigned)
            next.groups[index].recordIDs = members
            assigned.formUnion(members)
            var pins = (next.groups[index].pinnedAt ?? [:]).filter { members.contains($0.key) }
            for id in members where pins[id] == nil {
                pins[id] = legacyPins[id]
            }
            next.groups[index].pinnedAt = pins.isEmpty ? nil : pins
        }
        if next.groups != archive.groups { try commit(next) }
    }

    private func commit(_ next: Archive) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writer.write(JSONEncoder().encode(next), to: fileURL)
        archive = next
    }
}
