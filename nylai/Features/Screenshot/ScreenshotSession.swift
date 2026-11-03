import CoreGraphics
import Foundation
import Observation

struct ScreenshotAnnotation: Identifiable, Equatable {
    let id: UUID
    var kind: ScreenshotAnnotationKind
    var start: PixelPoint
    var end: PixelPoint
    var points: [PixelPoint]
    var text: String
    var stepNumber: Int?
    var style: ScreenshotAnnotationStyle

    init(
        id: UUID = UUID(),
        kind: ScreenshotAnnotationKind = .rectangle,
        start: PixelPoint,
        end: PixelPoint,
        style: ScreenshotAnnotationStyle = .default,
        points: [PixelPoint] = [],
        text: String = "",
        stepNumber: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.points = points
        self.text = text
        self.stepNumber = stepNumber
        self.style = style.validated(for: kind)
    }

    init(
        id: UUID = UUID(),
        brushPoints: [PixelPoint],
        style: ScreenshotAnnotationStyle = .default
    ) {
        let resolvedPoints = brushPoints.isEmpty
            ? [PixelPoint(x: 0, y: 0)]
            : brushPoints
        self.init(
            id: id,
            kind: .brush,
            start: resolvedPoints[0],
            end: resolvedPoints[resolvedPoints.count - 1],
            style: style,
            points: resolvedPoints,
            text: "",
            stepNumber: nil
        )
    }

    init(
        id: UUID = UUID(),
        rect: PixelRect,
        kind: ScreenshotAnnotationKind = .rectangle,
        style: ScreenshotAnnotationStyle = .default
    ) {
        self.init(
            id: id,
            kind: kind,
            start: PixelPoint(x: rect.minX, y: rect.minY),
            end: PixelPoint(x: rect.maxX, y: rect.maxY),
            style: style
        )
    }

    var rect: PixelRect {
        get {
            let samplePoints = kind == .brush && !points.isEmpty ? points : [start, end]
            let minX = samplePoints.map(\.x).min() ?? start.x
            let minY = samplePoints.map(\.y).min() ?? start.y
            let maxX = samplePoints.map(\.x).max() ?? end.x
            let maxY = samplePoints.map(\.y).max() ?? end.y
            return PixelRect(
                x: minX,
                y: minY,
                width: max(maxX - minX, 1),
                height: max(maxY - minY, 1)
            )
        }
        set {
            let oldRect = rect
            if kind == .brush, !points.isEmpty {
                self.points = points.map { transformed($0, from: oldRect, to: newValue) }
                start = points[0]
                end = points[points.count - 1]
            } else {
                start = transformed(start, from: oldRect, to: newValue)
                end = transformed(end, from: oldRect, to: newValue)
            }
        }
    }

    private func transformed(
        _ point: PixelPoint,
        from oldRect: PixelRect,
        to newRect: PixelRect
    ) -> PixelPoint {
        func mapped(_ value: Int, oldStart: Int, oldLength: Int, newStart: Int, newLength: Int) -> Int {
            guard oldLength > 1 else {
                return newStart + newLength / 2
            }
            let fraction = Double(value - oldStart) / Double(oldLength)
            return newStart + Int((fraction * Double(newLength)).rounded())
        }
        return PixelPoint(
            x: mapped(
                point.x,
                oldStart: oldRect.minX,
                oldLength: oldRect.width,
                newStart: newRect.minX,
                newLength: newRect.width
            ),
            y: mapped(
                point.y,
                oldStart: oldRect.minY,
                oldLength: oldRect.height,
                newStart: newRect.minY,
                newLength: newRect.height
            )
        )
    }
}

enum ScreenshotStepNumbering {
    static func next(after annotations: [ScreenshotAnnotation]) -> Int {
        (annotations.compactMap(\.stepNumber).max() ?? 0) + 1
    }
}

@MainActor
@Observable
final class ScreenshotSession {
    enum Phase: Equatable {
        case idle
        case selecting
        case editing
        case outputting
        case ended
    }

    enum Interaction: Equatable {
        case selectingRegion
        case movingSelection
        case resizingSelection
        case creatingAnnotation
        case annotation(UUID)
    }

    private(set) var source: ScreenshotImageSource?
    private(set) var phase = Phase.idle
    private(set) var selection: PixelRect?
    private(set) var annotations: [ScreenshotAnnotation] = []
    private(set) var interaction: Interaction?
    private(set) var targets: [ScreenshotCaptureTarget] = []
    private(set) var selectedAnnotationID: UUID?
    private(set) var outputAppearance = ScreenshotOutputAppearance.default

    private struct ContentState: Equatable {
        var selection: PixelRect?
        var annotations: [ScreenshotAnnotation]
        var selectedAnnotationID: UUID?
        var outputAppearance: ScreenshotOutputAppearance
    }

    private var undoStack: [ContentState] = []
    private var redoStack: [ContentState] = []
    private var transactionStart: ContentState?

    var isActive: Bool {
        phase != .idle && phase != .ended
    }

    var canUndo: Bool {
        !undoStack.isEmpty && interaction == nil && (phase == .selecting || phase == .editing)
    }

    var canRedo: Bool {
        !redoStack.isEmpty && interaction == nil && (phase == .selecting || phase == .editing)
    }

    var selectedAnnotation: ScreenshotAnnotation? {
        guard let selectedAnnotationID else { return nil }
        return annotations.first { $0.id == selectedAnnotationID }
    }

    var canDeleteSelectedAnnotation: Bool {
        selectedAnnotation != nil && interaction == nil && phase == .editing
    }

    func begin(with source: ScreenshotImageSource) {
        self.source = source
        selection = nil
        annotations = []
        interaction = nil
        targets = []
        selectedAnnotationID = nil
        outputAppearance = .default
        clearHistory()
        phase = .selecting
    }

    func setTargets(_ targets: [ScreenshotCaptureTarget]) {
        guard phase == .selecting || phase == .editing else { return }
        self.targets = targets
    }

    func target(at globalPoint: CGPoint) -> ScreenshotCaptureTarget? {
        targets.first { $0.frame.contains(globalPoint) }
    }

    func chooseWindow(_ windowID: CGWindowID, source: ScreenshotImageSource) throws {
        guard phase == .selecting else {
            throw ScreenshotSessionError.invalidPhase
        }
        self.source = source
        selection = PixelRect(
            x: 0,
            y: 0,
            width: source.geometry.pixelSize.width,
            height: source.geometry.pixelSize.height
        )
        annotations = []
        interaction = nil
        selectedAnnotationID = nil
        clearHistory()
        phase = .editing
    }

    func select(globalScreenRect rect: CGRect) throws {
        guard let source, phase == .selecting || phase == .editing else {
            throw ScreenshotSessionError.invalidPhase
        }
        let converted = try source.geometry.mapper.pixelRect(fromGlobalScreenRect: rect)
        guard let clamped = converted.clamped(to: source.geometry.pixelSize) else {
            throw ScreenshotGeometryError.emptySelection
        }
        mutateContent {
            selection = clamped
            phase = .editing
        }
    }

    func select(pixelRect rect: PixelRect) throws {
        guard let source, phase == .selecting || phase == .editing else {
            throw ScreenshotSessionError.invalidPhase
        }
        guard let clamped = rect.clamped(to: source.geometry.pixelSize) else {
            throw ScreenshotGeometryError.selectionOutsideSource
        }
        mutateContent {
            selection = clamped
            phase = .editing
        }
    }

    func moveSelection(to pixelRect: PixelRect) throws {
        guard source != nil, phase == .editing, interaction == nil else {
            throw ScreenshotSessionError.invalidPhase
        }
        try select(pixelRect: pixelRect)
    }

    func clearSelection() {
        guard source != nil, phase == .selecting || phase == .editing else { return }
        mutateContent {
            selection = nil
            interaction = nil
            selectedAnnotationID = nil
            phase = .selecting
        }
    }

    func beginSelectionDrag() throws {
        guard let source, phase == .selecting || phase == .editing else {
            throw ScreenshotSessionError.invalidPhase
        }
        guard source.geometry.pixelSize.width > 0, source.geometry.pixelSize.height > 0 else {
            throw ScreenshotGeometryError.invalidSourceSize
        }
        mutateContent {
            selection = nil
            selectedAnnotationID = nil
            phase = .selecting
            interaction = .selectingRegion
        }
    }

    func updateSelectionDrag(globalScreenRect: CGRect) throws {
        guard interaction == .selectingRegion, let source else {
            throw ScreenshotSessionError.invalidPhase
        }
        let converted = try source.geometry.mapper.pixelRect(fromGlobalScreenRect: globalScreenRect)
        mutateContent {
            selection = converted
            phase = .editing
        }
    }

    func endSelectionDrag() {
        if interaction == .selectingRegion {
            interaction = nil
        }
    }

    func addAnnotation(_ annotation: ScreenshotAnnotation) throws {
        guard let source, phase == .editing else {
            throw ScreenshotSessionError.invalidPhase
        }
        guard annotation.rect.clamped(to: source.geometry.pixelSize) == annotation.rect else {
            throw ScreenshotGeometryError.selectionOutsideSource
        }
        mutateContent {
            annotations.append(annotation)
            selectedAnnotationID = annotation.id
        }
    }

    func updateAnnotation(
        _ id: UUID,
        rect: PixelRect,
        style: ScreenshotAnnotationStyle? = nil
    ) throws {
        guard let source, phase == .editing,
              let index = annotations.firstIndex(where: { $0.id == id }) else {
            throw ScreenshotSessionError.invalidPhase
        }
        guard rect.clamped(to: source.geometry.pixelSize) == rect else {
            throw ScreenshotGeometryError.selectionOutsideSource
        }
        mutateContent {
            if let style {
                annotations[index].style = style.validated(for: annotations[index].kind)
            }
            annotations[index].rect = rect
        }
    }

    func updateAnnotationStyle(_ id: UUID, style: ScreenshotAnnotationStyle) throws {
        guard phase == .editing,
              let index = annotations.firstIndex(where: { $0.id == id }) else {
            throw ScreenshotSessionError.invalidPhase
        }
        mutateContent {
            annotations[index].style = style.validated(for: annotations[index].kind)
        }
    }

    func setOutputAppearance(_ appearance: ScreenshotOutputAppearance) {
        guard source != nil, phase == .selecting || phase == .editing else { return }
        mutateContent {
            outputAppearance = appearance.validated()
        }
    }

    func updateAnnotationText(_ id: UUID, text: String) throws {
        guard phase == .editing,
              let index = annotations.firstIndex(where: { $0.id == id }) else {
            throw ScreenshotSessionError.invalidPhase
        }
        mutateContent {
            annotations[index].text = text
        }
    }

    func deleteAnnotation(_ id: UUID) {
        guard phase == .editing else { return }
        mutateContent {
            annotations.removeAll { $0.id == id }
            if selectedAnnotationID == id {
                selectedAnnotationID = nil
            }
        }
    }

    func selectAnnotation(_ id: UUID?) {
        guard phase == .editing else { return }
        if let id, annotations.contains(where: { $0.id == id }) {
            selectedAnnotationID = id
        } else {
            selectedAnnotationID = nil
        }
    }

    func deleteSelectedAnnotation() {
        guard phase == .editing, let selectedAnnotationID else { return }
        mutateContent {
            annotations.removeAll { $0.id == selectedAnnotationID }
            self.selectedAnnotationID = nil
        }
    }

    func beginInteraction(_ interaction: Interaction) throws {
        guard phase == .selecting || phase == .editing, self.interaction == nil else {
            throw ScreenshotSessionError.invalidPhase
        }
        switch interaction {
        case .selectingRegion:
            break
        case .creatingAnnotation:
            guard phase == .editing else {
                throw ScreenshotSessionError.invalidPhase
            }
        case .annotation(let id):
            guard phase == .editing, annotations.contains(where: { $0.id == id }) else {
                throw ScreenshotSessionError.invalidPhase
            }
        case .movingSelection, .resizingSelection:
            guard phase == .editing else {
                throw ScreenshotSessionError.invalidPhase
            }
        }
        transactionStart = contentState
        self.interaction = interaction
    }

    func endInteraction() {
        commitTransaction()
        interaction = nil
    }

    func cancelInteraction() {
        if let transactionStart {
            restore(transactionStart)
        }
        transactionStart = nil
        interaction = nil
    }

    func undo() {
        guard canUndo, let previous = undoStack.popLast() else { return }
        redoStack.append(contentState)
        restore(previous)
    }

    func redo() {
        guard canRedo, let next = redoStack.popLast() else { return }
        undoStack.append(contentState)
        restore(next)
    }

    // 返回 true 表示整个会话已取消；false 表示只结束了当前拖动或未提交操作。
    @discardableResult
    func cancel() -> Bool {
        if interaction != nil {
            cancelInteraction()
            return false
        }
        guard isActive else { return false }
        source = nil
        selection = nil
        annotations = []
        targets = []
        selectedAnnotationID = nil
        clearHistory()
        phase = .ended
        return true
    }

    func beginOutput() throws {
        guard phase == .editing, selection != nil, interaction == nil else {
            throw ScreenshotSessionError.invalidPhase
        }
        phase = .outputting
    }

    func outputCancelled() {
        guard phase == .outputting else { return }
        phase = .editing
    }

    func outputSucceeded() {
        guard phase == .outputting else { return }
        source = nil
        selection = nil
        annotations = []
        targets = []
        interaction = nil
        selectedAnnotationID = nil
        clearHistory()
        phase = .ended
    }

    func outputSucceededKeepingEditorActive() {
        guard phase == .outputting else { return }
        phase = .editing
    }

    private var contentState: ContentState {
        ContentState(
            selection: selection,
            annotations: annotations,
            selectedAnnotationID: selectedAnnotationID,
            outputAppearance: outputAppearance
        )
    }

    private func mutateContent(_ mutation: () throws -> Void) rethrows {
        let before = contentState
        try mutation()
        guard transactionStart == nil, contentState != before else { return }
        undoStack.append(before)
        redoStack.removeAll()
    }

    private func commitTransaction() {
        guard let transactionStart else { return }
        if contentState != transactionStart {
            undoStack.append(transactionStart)
            redoStack.removeAll()
        }
        self.transactionStart = nil
    }

    private func restore(_ state: ContentState) {
        selection = state.selection
        annotations = state.annotations
        selectedAnnotationID = state.selectedAnnotationID
        outputAppearance = state.outputAppearance
        transitionPhaseAfterHistoryRestore()
    }

    private func transitionPhaseAfterHistoryRestore() {
        guard phase == .selecting || phase == .editing else { return }
        if selection == nil {
            phase = .selecting
        } else {
            phase = .editing
        }
    }

    private func clearHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        transactionStart = nil
    }
}

enum ScreenshotSessionError: LocalizedError, Equatable {
    case invalidPhase

    var errorDescription: String? {
        "当前截图状态不允许此操作。"
    }
}

extension ScreenshotSessionError: Error {}
