import AppKit
import Observation

struct CollageItem: Identifiable {
    let id: UUID
    let image: CGImage
    var frame: CGRect

    init(id: UUID = UUID(), image: CGImage, frame: CGRect) {
        self.id = id
        self.image = image
        self.frame = CGRect(
            origin: frame.origin,
            size: CGSize(
                width: max(1, frame.width),
                height: max(1, frame.height)
            )
        )
    }

    var aspectRatio: CGFloat {
        max(frame.width / max(frame.height, 1), 0.01)
    }
}

enum CollageArrangement {
    case horizontal
    case vertical
}

enum CollageError: LocalizedError, Equatable {
    case emptyCanvas
    case outputTooLarge
    case renderingFailed
    case imageUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyCanvas:
            "拼图中还没有图片。"
        case .outputTooLarge:
            "拼图输出尺寸过大，请缩小图片或减少间距。"
        case .renderingFailed:
            "无法合成拼图图片。"
        case .imageUnavailable:
            "历史图片文件已丢失或无法读取。"
        }
    }
}

@MainActor
@Observable
final class CollageDocument {
    private(set) var items: [CollageItem] = []
    private(set) var selectedID: UUID?
    private(set) var canUndo = false
    private(set) var canRedo = false

    var selectedItem: CollageItem? {
        selectedID.flatMap { id in items.first { $0.id == id } }
    }

    var canDeleteSelected: Bool {
        selectedID != nil
    }

    var canBringForward: Bool {
        guard let selectedID, let index = items.firstIndex(where: { $0.id == selectedID }) else {
            return false
        }
        return index < items.count - 1
    }

    var canSendBackward: Bool {
        guard let selectedID, let index = items.firstIndex(where: { $0.id == selectedID }) else {
            return false
        }
        return index > 0
    }

    var contentBounds: CGRect {
        guard let first = items.first else { return .zero }
        return items.dropFirst().reduce(first.frame) { result, item in
            result.union(item.frame)
        }
    }

    var workspaceSize: CGSize {
        let bounds = contentBounds
        guard !bounds.isEmpty else {
            return CGSize(width: 1200, height: 800)
        }
        return CGSize(
            width: max(1200, ceil(bounds.maxX) + 120),
            height: max(800, ceil(bounds.maxY) + 120)
        )
    }

    private struct Snapshot {
        let items: [CollageItem]
        let selection: UUID?
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var pendingInteraction: Snapshot?
    private static let maximumUndoCount = 50

    @discardableResult
    func add(
        _ image: CGImage,
        at origin: CGPoint? = nil
    ) -> UUID {
        recordUndo()
        let resolvedOrigin: CGPoint
        if let origin {
            resolvedOrigin = origin
        } else if items.isEmpty {
            resolvedOrigin = CGPoint(x: 100, y: 100)
        } else {
            let bounds = contentBounds
            resolvedOrigin = CGPoint(x: bounds.maxX + 16, y: bounds.minY)
        }
        let item = CollageItem(
            image: image,
            frame: CGRect(
                origin: resolvedOrigin,
                size: CGSize(width: image.width, height: image.height)
            )
        )
        items.append(item)
        selectedID = item.id
        updateHistoryAvailability()
        return item.id
    }

    func select(_ id: UUID?) {
        selectedID = id
    }

    func beginInteraction() {
        guard pendingInteraction == nil else { return }
        pendingInteraction = snapshot
    }

    func updateFrame(_ frame: CGRect, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].frame = CGRect(
            x: frame.origin.x,
            y: frame.origin.y,
            width: max(1, frame.width),
            height: max(1, frame.height)
        )
    }

    func endInteraction() {
        guard let pendingInteraction else { return }
        self.pendingInteraction = nil
        if stateChanged(from: pendingInteraction) {
            appendUndo(pendingInteraction)
            redoStack.removeAll()
        }
        updateHistoryAvailability()
    }

    func deleteSelected() {
        guard let selectedID, items.contains(where: { $0.id == selectedID }) else { return }
        recordUndo()
        items.removeAll { $0.id == selectedID }
        self.selectedID = nil
        updateHistoryAvailability()
    }

    func bringForward() {
        guard canBringForward,
              let selectedID,
              let index = items.firstIndex(where: { $0.id == selectedID }) else {
            return
        }
        recordUndo()
        items.swapAt(index, index + 1)
        updateHistoryAvailability()
    }

    func sendBackward() {
        guard canSendBackward,
              let selectedID,
              let index = items.firstIndex(where: { $0.id == selectedID }) else {
            return
        }
        recordUndo()
        items.swapAt(index, index - 1)
        updateHistoryAvailability()
    }

    func arrange(_ arrangement: CollageArrangement) {
        guard items.count > 1 else { return }
        let bounds = contentBounds
        recordUndo()
        var cursor = CGPoint(x: bounds.minX, y: bounds.minY)
        for index in items.indices {
            let frame = items[index].frame
            switch arrangement {
            case .horizontal:
                items[index].frame.origin = CGPoint(x: cursor.x, y: bounds.minY)
                cursor.x += frame.width + 16
            case .vertical:
                items[index].frame.origin = CGPoint(x: bounds.minX, y: cursor.y)
                cursor.y += frame.height + 16
            }
        }
        updateHistoryAvailability()
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(self.snapshot)
        restore(snapshot)
        updateHistoryAvailability()
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(self.snapshot)
        restore(snapshot)
        updateHistoryAvailability()
    }

    func render() throws -> CGImage {
        guard !items.isEmpty else { throw CollageError.emptyCanvas }
        let bounds = contentBounds
        guard bounds.minX.isFinite,
              bounds.minY.isFinite,
              bounds.maxX.isFinite,
              bounds.maxY.isFinite else {
            throw CollageError.outputTooLarge
        }
        let minimumX = bounds.minX.rounded(.down)
        let minimumY = bounds.minY.rounded(.down)
        let widthValue = bounds.maxX.rounded(.up) - minimumX
        let heightValue = bounds.maxY.rounded(.up) - minimumY
        guard widthValue >= 1,
              heightValue >= 1,
              widthValue <= 20_000,
              heightValue <= 20_000 else {
            throw CollageError.outputTooLarge
        }
        let width = Int(widthValue)
        let height = Int(heightValue)
        guard width <= 20_000,
              height <= 20_000,
              width.multipliedReportingOverflow(by: height).overflow == false,
              width * height <= 100_000_000 else {
            throw CollageError.outputTooLarge
        }
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
            throw CollageError.renderingFailed
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        for item in items {
            let itemMinX = item.frame.minX.rounded(.down)
            let itemMaxX = item.frame.maxX.rounded(.up)
            let itemMinY = item.frame.minY.rounded(.down)
            let itemMaxY = item.frame.maxY.rounded(.up)
            let drawRect = CGRect(
                x: itemMinX - minimumX,
                y: CGFloat(height) - (itemMaxY - minimumY),
                width: max(1, itemMaxX - itemMinX),
                height: max(1, itemMaxY - itemMinY)
            )
            context.draw(item.image, in: drawRect)
        }
        guard let image = context.makeImage() else {
            throw CollageError.renderingFailed
        }
        return image
    }

    private var snapshot: Snapshot {
        Snapshot(items: items, selection: selectedID)
    }

    private func restore(_ snapshot: Snapshot) {
        items = snapshot.items
        selectedID = snapshot.selection
        pendingInteraction = nil
    }

    private func recordUndo() {
        appendUndo(snapshot)
        redoStack.removeAll()
    }

    private func appendUndo(_ snapshot: Snapshot) {
        undoStack.append(snapshot)
        if undoStack.count > Self.maximumUndoCount {
            undoStack.removeFirst(undoStack.count - Self.maximumUndoCount)
        }
    }

    private func stateChanged(from snapshot: Snapshot) -> Bool {
        guard snapshot.items.count == items.count else { return true }
        return zip(snapshot.items, items).contains { old, new in
            old.id != new.id || old.frame != new.frame
        }
    }

    private func updateHistoryAvailability() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }
}

struct CollageImageLoader {
    static func load(url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw CollageImageLoadError.invalidImage
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 8192
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 8192
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            throw CollageImageLoadError.invalidImage
        }
        return image
    }
}

enum CollageImageLoadError: LocalizedError, Equatable {
    case invalidImage

    var errorDescription: String? {
        "无法读取该图片。支持 PNG、JPEG 和 HEIC。"
    }
}
