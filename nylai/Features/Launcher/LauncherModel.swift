import AppKit
import Observation

@MainActor
@Observable
final class LauncherModel {
    let preferences: LauncherPreferences
    let sources: LauncherSources
    var input = "" { didSet { if oldValue != input { schedule() } } }
    var scope: LauncherScope = .all { didSet { if oldValue != scope { schedule() } } }
    private(set) var results: [LauncherResult] = []
    var selectedID: String?
    var showingActions = false
    var actionIndex = 0
    var searching = false
    var indexing = false
    var settingsPresented = false
    var focusToken = 0
    var onRun: ((LauncherResult, LauncherAction) -> Void)?
    var onDismiss: (() -> Void)?
    @ObservationIgnored private var fileResults: [LauncherResult] = []
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var active = false

    init(preferences: LauncherPreferences, sources: LauncherSources) {
        self.preferences = preferences
        self.sources = sources
        sources.onIndexChanged = { [weak self] in self?.refresh() }
    }

    var query: LauncherQuery { LauncherQuery(input, scope: scope) }
    var selected: LauncherResult? { results.first { $0.id == selectedID } }
    var actions: [LauncherAction] {
        guard let result = selected else { return [] }
        var list = result.actions
        if result.scope == .applications || result.scope == .commands || result.scope == .links {
            let favorite = preferences.configuration.favorites.contains(result.id)
            list.append(.init(id: "favorite", title: L10n.shared.string(favorite ? "取消收藏" : "收藏"), symbol: favorite ? "star.slash" : "star") { [weak self] in
                self?.preferences.update { config in
                    if favorite { config.favorites.removeAll { $0 == result.id } }
                    else { config.favorites.append(result.id) }
                }
            })
            list.append(.init(id: "alias", title: L10n.shared.string("自定义搜索别名"), symbol: "textformat.abc") { [weak self] in
                guard let self else { return }
                let alert = NSAlert()
                alert.messageText = L10n.shared.string("自定义搜索别名")
                alert.informativeText = result.title
                alert.addButton(withTitle: L10n.shared.string("保存"))
                alert.addButton(withTitle: L10n.shared.string("取消"))
                let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 280, height: 24))
                field.stringValue = self.preferences.configuration.aliases[result.id] ?? ""
                alert.accessoryView = field
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                self.preferences.update { config in
                    let alias = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if alias.isEmpty { config.aliases.removeValue(forKey: result.id) }
                    else { config.aliases[result.id] = alias }
                }
            })
        }
        return list
    }

    func begin(target: NSRunningApplication?) {
        stopSearch()
        active = false
        input = ""; scope = .all
        selectedID = nil; showingActions = false; actionIndex = 0; settingsPresented = false
        active = true
        sources.prepare(target: target)
        schedule()
        startIndex()
        focusToken += 1
    }

    func restartIndex() {
        guard active else { return }
        let target = sources.previousApplication
        sources.prepare(target: target)
        schedule()
        startIndex()
        focusToken += 1
    }

    private func startIndex() {
        indexTask?.cancel()
        indexing = true
        indexTask = Task { [weak self] in
            guard let self else { return }
            await sources.enrich()
            if !Task.isCancelled { indexing = false; refresh() }
        }
    }

    func stopSearch() {
        active = false
        revision += 1
        searchTask?.cancel(); searchTask = nil
        indexTask?.cancel(); indexTask = nil
        searching = false; indexing = false
    }

    func clear() {
        stopSearch()
        results = []; fileResults = []; selectedID = nil
        sources.release()
    }

    func selectScope(_ value: LauncherScope) {
        if scope != value { scope = value }
        focusToken += 1
    }

    private func schedule() {
        guard active else { return }
        revision += 1
        let currentRevision = revision
        searchTask?.cancel()
        fileResults = []
        showingActions = false
        actionIndex = 0
        refresh()
        let q = query
        guard !q.text.isEmpty, q.scope == .all || q.scope == .files else { searching = false; return }
        searching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(130))
            guard let self, !Task.isCancelled else { return }
            let values = await sources.files(q.text)
            guard !Task.isCancelled, active, currentRevision == revision else { return }
            fileResults = values
            searching = false
            refresh()
        }
    }

    private func refresh() {
        guard active else { return }
        let q = query, config = preferences.configuration
        var entries = sources.local(q)
        if q.scope == .all || q.scope == .files { entries += fileResults }
        if q.scope == .all, q.text.isEmpty {
            entries = entries.filter { [.applications, .commands, .links].contains($0.scope) || config.favorites.contains($0.id) }
        }
        var seen = Set<String>()
        let ranked: [(LauncherResult, Int)] = entries.compactMap { entry in
            guard seen.insert(entry.id).inserted else { return nil }
            guard let score = LauncherRank.score(query: q.text, title: entry.title,
                    keywords: entry.keywords, subtitle: entry.subtitle, alias: config.aliases[entry.id]) else { return nil }
            let usage = min(config.usage[entry.id, default: 0], 70)
            let favorite = config.favorites.contains(entry.id) ? 120 : 0
            return (entry, score + entry.priority + usage + favorite)
        }
        let limit = q.scope == .all ? 35 : 120
        results = Array(ranked.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.title.localizedStandardCompare($1.0.title) == .orderedAscending
        }.prefix(limit).map(\.0))
        if selectedID == nil || !results.contains(where: { $0.id == selectedID }) {
            selectedID = results.first?.id
            actionIndex = 0
        }
    }

    func select(_ id: String) {
        selectedID = id
        actionIndex = 0
    }

    func move(_ delta: Int) {
        if showingActions {
            let count = actions.count
            guard count > 0 else { return }
            actionIndex = min(max(0, actionIndex + delta), count - 1)
            return
        }
        guard !results.isEmpty else { return }
        let index = selectedID.flatMap { id in results.firstIndex(where: { $0.id == id }) } ?? 0
        select(results[min(max(0, index + delta), results.count - 1)].id)
    }

    func cycleScope(reverse: Bool) {
        let options = LauncherScope.allCases
        let index = options.firstIndex(of: scope) ?? 0
        selectScope(options[(index + (reverse ? options.count - 1 : 1)) % options.count])
    }

    func toggleActions() {
        guard selected != nil else { return }
        showingActions.toggle(); actionIndex = 0
    }

    func confirm() {
        if let result = selected {
            if showingActions {
                let options = actions
                if options.indices.contains(actionIndex) { onRun?(result, options[actionIndex]) }
            } else if let first = result.actions.first {
                onRun?(result, first)
            }
        } else if scope == .all, let mode = LauncherScope.allCases.first(where: { $0.alias == input.lowercased() && $0 != .all }) {
            input = ""; selectScope(mode)
        }
    }

    func escape() {
        if showingActions { showingActions = false; focusToken += 1 }
        else if scope != .all { scope = .all; input = ""; focusToken += 1 }
        else { onDismiss?() }
    }
}
