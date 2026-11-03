import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class CollageViewModel {
    let document = CollageDocument()
    private let historyStore: ScreenshotHistoryStore?
    private let isHistoryEnabled: @MainActor () -> Bool
    private let paster: any ScreenshotPasting
    private let saver: any ScreenshotSaving
    private(set) var revision = 0
    private(set) var errorMessage: String?

    init(
        historyStore: ScreenshotHistoryStore?,
        isHistoryEnabled: @escaping @MainActor () -> Bool,
        paster: any ScreenshotPasting = PasteboardScreenshotPaster(),
        saver: any ScreenshotSaving = PNGScreenshotSaver()
    ) {
        self.historyStore = historyStore
        self.isHistoryEnabled = isHistoryEnabled
        self.paster = paster
        self.saver = saver
    }

    var historyRecords: [ScreenshotHistoryRecord] {
        historyStore?.records ?? []
    }

    var canOutput: Bool {
        !document.items.isEmpty
    }

    func canvasDidChange() {
        revision &+= 1
    }

    func addHistoryRecord(_ record: ScreenshotHistoryRecord) {
        guard let image = historyStore?.image(for: record),
              let cgImage = image.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
              ) else {
            show(CollageError.imageUnavailable)
            return
        }
        addImage(cgImage)
    }

    func addImage(_ image: CGImage) {
        document.add(image)
        canvasDidChange()
    }

    func importImages() {
        Task { [weak self] in
            guard let self else { return }
            let panel = NSOpenPanel()
            panel.title = "导入拼图图片"
            panel.allowedContentTypes = [.png, .jpeg, .heic]
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            guard await panel.begin() == .OK else { return }
            do {
                for url in panel.urls {
                    addImage(try CollageImageLoader.load(url: url))
                }
            } catch {
                show(error)
            }
        }
    }

    func arrange(_ arrangement: CollageArrangement) {
        document.arrange(arrangement)
        canvasDidChange()
    }

    func bringForward() {
        document.bringForward()
        canvasDidChange()
    }

    func sendBackward() {
        document.sendBackward()
        canvasDidChange()
    }

    func deleteSelected() {
        document.deleteSelected()
        canvasDidChange()
    }

    func undo() {
        document.undo()
        canvasDidChange()
    }

    func redo() {
        document.redo()
        canvasDidChange()
    }

    func copyImage() {
        do {
            let image = try document.render()
            try paster.copy(image)
            recordHistory(image)
        } catch {
            show(error)
        }
    }

    func saveImage() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let image = try document.render()
                guard try await saver.save(image) != nil else { return }
                recordHistory(image)
            } catch {
                show(error)
            }
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func recordHistory(_ image: CGImage) {
        guard isHistoryEnabled(), let historyStore else { return }
        do {
            try historyStore.add(image)
            revision &+= 1
        } catch {
            show(error)
        }
    }

    private func show(_ error: Error) {
        errorMessage = error.localizedDescription
    }
}

@MainActor
final class CollageWindowController: NSWindowController {
    let viewModel: CollageViewModel

    init(
        historyStore: ScreenshotHistoryStore?,
        isHistoryEnabled: @escaping @MainActor () -> Bool,
        paster: any ScreenshotPasting = PasteboardScreenshotPaster(),
        saver: any ScreenshotSaving = PNGScreenshotSaver()
    ) {
        viewModel = CollageViewModel(
            historyStore: historyStore,
            isHistoryEnabled: isHistoryEnabled,
            paster: paster,
            saver: saver
        )
        let hostingController = NSHostingController(
            rootView: CollageView(model: viewModel)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "自由拼图"
        window.identifier = NSUserInterfaceItemIdentifier("nylai.collage")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1060, height: 760))
        window.minSize = NSSize(width: 760, height: 520)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从归档创建拼图窗口")
    }

    func present(adding image: CGImage? = nil) {
        if let image {
            viewModel.addImage(image)
        }
        guard let window else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private struct CollageView: View {
    @Bindable var model: CollageViewModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.65)
            canvas
            Divider().opacity(0.65)
            statusBar
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("无法完成操作", isPresented: errorPresented) {
            Button("好", role: .cancel) { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.3.group.fill")
                    .foregroundStyle(.orange)
                Text("自由拼图")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .padding(.trailing, 4)

            Divider().frame(height: 22)

            Menu {
                if model.historyRecords.isEmpty {
                    Text("没有最近截图")
                } else {
                    ForEach(model.historyRecords) { record in
                        Button {
                            model.addHistoryRecord(record)
                        } label: {
                            Text(
                                "\(record.createdAt.formatted(date: .abbreviated, time: .shortened))  ·  \(record.width) × \(record.height)"
                            )
                        }
                    }
                }
            } label: {
                toolbarLabel("最近截图", symbol: "photo.stack")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            toolbarButton("导入", symbol: "folder.badge.plus") {
                model.importImages()
            }

            Divider().frame(height: 22)

            toolbarButton("横排", symbol: "rectangle.split.3x1") {
                model.arrange(.horizontal)
            }
            .disabled(model.document.items.count < 2)
            toolbarButton("竖排", symbol: "rectangle.split.1x2") {
                model.arrange(.vertical)
            }
            .disabled(model.document.items.count < 2)

            Divider().frame(height: 22)

            toolbarButton("上移", symbol: "square.2.layers.3d.top.filled") {
                model.bringForward()
            }
            .disabled(!model.document.canBringForward)
            toolbarButton("下移", symbol: "square.2.layers.3d.bottom.filled") {
                model.sendBackward()
            }
            .disabled(!model.document.canSendBackward)
            toolbarButton("删除", symbol: "trash") {
                model.deleteSelected()
            }
            .disabled(!model.document.canDeleteSelected)

            Divider().frame(height: 22)

            toolbarButton("撤销", symbol: "arrow.uturn.backward") {
                model.undo()
            }
            .disabled(!model.document.canUndo)
            toolbarButton("重做", symbol: "arrow.uturn.forward") {
                model.redo()
            }
            .disabled(!model.document.canRedo)

            Spacer(minLength: 8)

            Button("复制") { model.copyImage() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!model.canOutput)
            Button("保存") { model.saveImage() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!model.canOutput)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var canvas: some View {
        ZStack {
            CollageScrollCanvas(document: model.document) {
                model.canvasDidChange()
            }

            if model.document.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("添加图片开始拼图")
                        .font(.system(size: 15, weight: .medium))
                    Text("从最近截图、PNG、JPEG 或 HEIC 导入")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("导入图片") { model.importImages() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        if !model.historyRecords.isEmpty {
                            Menu("最近截图") {
                                ForEach(model.historyRecords) { record in
                                    Button(
                                        record.createdAt.formatted(
                                            date: .abbreviated,
                                            time: .shortened
                                        )
                                    ) {
                                        model.addHistoryRecord(record)
                                    }
                                }
                            }
                            .fixedSize()
                        }
                    }
                }
                .padding(28)
                .background(.regularMaterial, in: RoundedRectangle(
                    cornerRadius: 16,
                    style: .continuous
                ))
                .allowsHitTesting(true)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text("\(model.document.items.count) 张图片")
            if let selected = model.document.selectedItem {
                Text("当前 \(Int(selected.frame.width.rounded())) × \(Int(selected.frame.height.rounded()))")
            }
            Spacer()
            Text("拖动图片移动，拖动边角等比缩放；滚轮或触控板可缩放画布")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial)
    }

    private func toolbarButton(
        _ title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            toolbarLabel(title, symbol: symbol)
        }
        .buttonStyle(.borderless)
        .help(title)
    }

    private func toolbarLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 11.5, weight: .medium))
            .labelStyle(.iconOnly)
            .frame(width: 26, height: 24)
            .contentShape(Rectangle())
            .help(title)
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.clearError() } }
        )
    }
}

private struct CollageScrollCanvas: NSViewRepresentable {
    let document: CollageDocument
    let onChanged: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(calibratedWhite: 0.9, alpha: 1)
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 4

        let canvas = CollageCanvasView(frame: CGRect(origin: .zero, size: document.workspaceSize))
        canvas.document = document
        canvas.onDocumentChanged = onChanged
        scrollView.documentView = canvas
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let canvas = scrollView.documentView as? CollageCanvasView else { return }
        canvas.document = document
        canvas.onDocumentChanged = onChanged
        canvas.reloadDocument()
    }
}
