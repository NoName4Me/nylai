import AppKit
import Observation

enum BoardKind: String, Codable, CaseIterable {
    case note, image, pen, marker, line, arrow, rectangle, ellipse, triangle, diamond, star
    var isStroke: Bool { self == .pen || self == .marker || self == .line || self == .arrow }
}

enum BoardColor: String, Codable, CaseIterable, Identifiable {
    case yellow, green, blue, pink, purple, gray, clear
    var id: String { rawValue }
    var title: String {
        switch self {
        case .yellow: L10n.shared.string("黄色")
        case .green: L10n.shared.string("绿色")
        case .blue: L10n.shared.string("蓝色")
        case .pink: L10n.shared.string("粉色")
        case .purple: L10n.shared.string("紫色")
        case .gray: L10n.shared.string("灰色")
        case .clear: L10n.shared.string("透明")
        }
    }
    var paper: NSColor {
        switch self {
        case .yellow: NSColor(calibratedRed: 1, green: 0.94, blue: 0.73, alpha: 1)
        case .green: NSColor(calibratedRed: 0.85, green: 0.94, blue: 0.82, alpha: 1)
        case .blue: NSColor(calibratedRed: 0.83, green: 0.91, blue: 0.99, alpha: 1)
        case .pink: NSColor(calibratedRed: 0.99, green: 0.86, blue: 0.88, alpha: 1)
        case .purple: NSColor(calibratedRed: 0.91, green: 0.86, blue: 0.98, alpha: 1)
        case .gray: NSColor(calibratedWhite: 0.91, alpha: 1)
        case .clear: .clear
        }
    }
    var ink: NSColor {
        switch self {
        case .yellow: .systemOrange
        case .green: .systemGreen
        case .blue: .systemBlue
        case .pink: .systemRed
        case .purple: .systemPurple
        case .gray, .clear: .labelColor
        }
    }
}

struct BoardItem: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: BoardKind
    var frame: CGRect
    var text = ""
    var asset: UUID?
    var color: BoardColor = .yellow
    // Points are normalized relative to frame so resizing preserves strokes.
    var points: [CGPoint] = []
    var strokeWidth: CGFloat = 3
    var locked = false
    var group: UUID?
    var recognizedText = ""
    // Optional keeps existing saved boards decodable.
    var expandedHeight: CGFloat?
    var isCollapsed: Bool { kind == .note && expandedHeight != nil }

    var searchableText: String { text + " " + recognizedText }
}

struct BoardViewport: Codable, Equatable {
    var center = CGPoint.zero
    var zoom: CGFloat = 1

    func screen(_ p: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: (p.x - center.x) * zoom + size.width / 2,
                y: (p.y - center.y) * zoom + size.height / 2)
    }

    func world(_ p: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: (p.x - size.width / 2) / zoom + center.x,
                y: (p.y - size.height / 2) / zoom + center.y)
    }

    func rect(_ frame: CGRect, in size: CGSize) -> CGRect {
        CGRect(origin: screen(frame.origin, in: size),
               size: CGSize(width: frame.width * zoom, height: frame.height * zoom))
    }

    mutating func magnify(_ factor: CGFloat, at anchor: CGPoint, in size: CGSize) {
        guard factor.isFinite, factor > 0 else { return }
        let before = world(anchor, in: size)
        zoom = max(0.08, min(5, zoom * factor))
        let after = world(anchor, in: size)
        center.x += before.x - after.x
        center.y += before.y - after.y
    }
}

struct BoardDocument: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var items: [BoardItem] = []
    var viewport = BoardViewport()
}

struct BoardLibrary: Codable, Equatable {
    var version = 1
    var boards: [BoardDocument]
    var activeID: UUID
    var defaultID: UUID

    static func initial() -> Self {
        let board = BoardDocument(title: L10n.shared.string("随手记"))
        return Self(boards: [board], activeID: board.id, defaultID: board.id)
    }

    var isValid: Bool {
        version == 1 && !boards.isEmpty
            && Set(boards.map(\.id)).count == boards.count
            && boards.contains { $0.id == activeID }
            && boards.contains { $0.id == defaultID }
            && boards.allSatisfy { board in
                board.viewport.zoom.isFinite && (0.08...5).contains(board.viewport.zoom)
                    && board.viewport.center.x.isFinite && board.viewport.center.y.isFinite
                    && Set(board.items.map(\.id)).count == board.items.count
                    && board.items.allSatisfy { item in
                        let f = item.frame
                        return f.minX.isFinite && f.minY.isFinite && f.maxX.isFinite && f.maxY.isFinite
                            && f.width > 0 && f.height > 0
                            && item.strokeWidth.isFinite && item.strokeWidth > 0
                            && (item.expandedHeight.map { $0.isFinite && $0 > 0 } ?? true)
                            && item.points.allSatisfy { $0.x.isFinite && $0.y.isFinite }
                            && (item.kind != .image || item.asset != nil)
                    }
            }
    }
}

enum BoardStoreError: LocalizedError {
    case invalidDocument, invalidImage
    var errorDescription: String? {
        L10n.shared.string(self == .invalidDocument ? "画布数据无效，原文件已保留。" : "无法导入此图片。")
    }
}

@MainActor
@Observable
final class BoardStore {
    let directory: URL
    private(set) var library: BoardLibrary
    private(set) var loadError: String?
    var error: String?
    private(set) var undoStack: [BoardLibrary] = []
    private(set) var redoStack: [BoardLibrary] = []
    @ObservationIgnored private let cache = NSCache<NSUUID, NSImage>()
    @ObservationIgnored private var viewportSave: Task<Void, Never>?
    @ObservationIgnored private var recognitionTasks: [UUID: Task<Void, Never>] = [:]

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("nylai/Boards", isDirectory: true)) {
        self.directory = directory
        self.library = .initial()
        cache.totalCostLimit = 64 * 1024 * 1024
        let url = directory.appendingPathComponent("index.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let decoded = try JSONDecoder().decode(BoardLibrary.self, from: Data(contentsOf: url))
                guard decoded.isValid else { throw BoardStoreError.invalidDocument }
                library = decoded
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    var active: BoardDocument { library.boards.first { $0.id == library.activeID } ?? library.boards[0] }

    func document(_ id: UUID) -> BoardDocument? { library.boards.first { $0.id == id } }

    private func persist(_ value: BoardLibrary) throws {
        guard loadError == nil, value.isValid else { throw BoardStoreError.invalidDocument }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
    }

    @discardableResult
    func change(undoable: Bool = true, _ edit: (inout BoardLibrary) -> Void) -> Bool {
        guard loadError == nil else { error = loadError; return false }
        var next = library
        edit(&next)
        guard next != library else { return true }
        do {
            try persist(next)
            if undoable {
                undoStack.append(library)
                if undoStack.count > 50 { undoStack.removeFirst() }
                redoStack.removeAll()
            }
            library = next
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func editBoard(_ id: UUID, _ edit: (inout BoardDocument) -> Void) {
        change { value in
            guard let i = value.boards.firstIndex(where: { $0.id == id }) else { return }
            edit(&value.boards[i])
        }
    }

    func select(_ id: UUID) { change(undoable: false) { $0.activeID = id } }
    func makeDefault(_ id: UUID) { change { $0.defaultID = id } }

    func create(_ title: String) {
        let board = BoardDocument(title: title)
        change { $0.boards.append(board); $0.activeID = board.id }
    }

    func delete(_ id: UUID) {
        guard library.boards.count > 1 else { return }
        change { value in
            value.boards.removeAll { $0.id == id }
            if value.activeID == id { value.activeID = value.boards[0].id }
            if value.defaultID == id { value.defaultID = value.boards[0].id }
        }
    }

    func undo() {
        guard let previous = undoStack.last else { return }
        do {
            try persist(previous)
            redoStack.append(library)
            undoStack.removeLast()
            library = previous
        } catch { self.error = error.localizedDescription }
    }

    func redo() {
        guard let next = redoStack.last else { return }
        do {
            try persist(next)
            undoStack.append(library)
            redoStack.removeLast()
            library = next
        } catch { self.error = error.localizedDescription }
    }

    func viewport(_ viewport: BoardViewport, boardID: UUID) {
        guard loadError == nil, let index = library.boards.firstIndex(where: { $0.id == boardID }) else { return }
        library.boards[index].viewport = viewport
        viewportSave?.cancel()
        viewportSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        viewportSave?.cancel()
        viewportSave = nil
        guard loadError == nil else { return }
        do { try persist(library) } catch { self.error = error.localizedDescription }
    }

    func stop() {
        for task in recognitionTasks.values { task.cancel() }
        recognitionTasks.removeAll()
        flush()
        cache.removeAllObjects()
    }

    private func assetURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("Images", isDirectory: true)
            .appendingPathComponent(id.uuidString + ".png")
    }

    func image(_ id: UUID) -> NSImage? {
        if let hit = cache.object(forKey: id as NSUUID) { return hit }
        guard let image = NSImage(contentsOf: assetURL(id)) else { return nil }
        let cost = Int(min(image.size.width * image.size.height * 4, CGFloat(Int32.max)))
        cache.setObject(image, forKey: id as NSUUID, cost: max(cost, 0))
        return image
    }

    @discardableResult
    func addImage(_ image: NSImage, boardID: UUID, at origin: CGPoint) -> Bool {
        guard loadError == nil, document(boardID) != nil else { error = loadError ?? BoardStoreError.invalidDocument.localizedDescription; return false }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              cg.width > 0, cg.height > 0, cg.width <= 40_000_000 / cg.height,
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            error = BoardStoreError.invalidImage.localizedDescription
            return false
        }
        let asset = UUID()
        let url = assetURL(asset)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            let scale = min(1, 420 / CGFloat(max(cg.width, cg.height)))
            let item = BoardItem(kind: .image, frame: CGRect(origin: origin,
                size: CGSize(width: CGFloat(cg.width) * scale, height: CGFloat(cg.height) * scale)), asset: asset)
            let saved = change { value in
                guard let i = value.boards.firstIndex(where: { $0.id == boardID }) else { return }
                value.boards[i].items.append(item)
            }
            if !saved { try? FileManager.default.removeItem(at: url); return false }
            let input = ClipboardContent.image(cg)
            recognitionTasks[item.id] = Task { [weak self] in
                defer { self?.recognitionTasks.removeValue(forKey: item.id) }
                guard case .image(let cg) = input else { return }
                guard let text = try? await ScreenshotTextRecognition.recognize(cg, layout: .lines),
                      !Task.isCancelled, let self, self.document(boardID)?.items.contains(where: { $0.id == item.id }) == true else { return }
                self.change(undoable: false) { value in
                    guard let b = value.boards.firstIndex(where: { $0.id == boardID }),
                          let i = value.boards[b].items.firstIndex(where: { $0.id == item.id }) else { return }
                    value.boards[b].items[i].recognizedText = text
                }
            }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func addText(_ text: String, boardID: UUID, at point: CGPoint, color: BoardColor = .yellow) -> UUID {
        let item = BoardItem(kind: .note, frame: CGRect(origin: point, size: CGSize(width: 240, height: 160)),
                             text: text, color: color)
        editBoard(boardID) { $0.items.append(item) }
        return item.id
    }

    func toggleNoteCollapse(boardID: UUID, itemID: UUID) {
        editBoard(boardID) { board in
            guard let i = board.items.firstIndex(where: { $0.id == itemID }),
                  board.items[i].kind == .note, !board.items[i].locked else { return }
            if let height = board.items[i].expandedHeight {
                board.items[i].frame.size.height = height
                board.items[i].expandedHeight = nil
            } else {
                board.items[i].expandedHeight = board.items[i].frame.height
                board.items[i].frame.size.height = 36
            }
        }
    }

    func toggleTodo(boardID: UUID, itemID: UUID, line: Int) {
        guard let item = document(boardID)?.items.first(where: { $0.id == itemID }), !item.locked else { return }
        var lines = item.text.components(separatedBy: "\n")
        guard lines.indices.contains(line) else { return }
        let value = lines[line]
        if value.hasPrefix("- [ ] ") { lines[line] = "- [x] " + value.dropFirst(6) }
        else if value.lowercased().hasPrefix("- [x] ") { lines[line] = "- [ ] " + value.dropFirst(6) }
        else { return }
        updateText(lines.joined(separator: "\n"), boardID: boardID, itemID: itemID)
    }

    func updateText(_ text: String, boardID: UUID, itemID: UUID) {
        editBoard(boardID) { board in
            guard let i = board.items.firstIndex(where: { $0.id == itemID }), !board.items[i].locked else { return }
            board.items[i].text = text
        }
    }

    func nextCapturePoint(in boardID: UUID) -> CGPoint {
        guard let board = document(boardID) else { return .zero }
        let occupied = board.items.map(\.frame)
        var point = board.viewport.center
        while occupied.contains(where: { $0.intersects(CGRect(origin: point, size: CGSize(width: 250, height: 170))) }) {
            point.x += 32
            point.y += 32
        }
        return point
    }

    // Deleted assets are intentionally retained until a later explicit cleanup:
    // undo, redo and failed document writes must never lose image bytes.
}
