import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class ScreenshotHistoryViewModel {
    let store: ScreenshotHistoryStore
    private let paster: any ScreenshotPasting
    private let saver: any ScreenshotSaving
    private let pinnedImageManager: PinnedImageManager
    private let onAddToCollage: @MainActor (CGImage) -> Void
    private(set) var errorMessage: String?

    init(
        store: ScreenshotHistoryStore,
        paster: any ScreenshotPasting = PasteboardScreenshotPaster(),
        saver: any ScreenshotSaving = PNGScreenshotSaver(),
        pinnedImageManager: PinnedImageManager,
        onAddToCollage: @escaping @MainActor (CGImage) -> Void = { _ in }
    ) {
        self.store = store
        self.paster = paster
        self.saver = saver
        self.pinnedImageManager = pinnedImageManager
        self.onAddToCollage = onAddToCollage
    }

    func reload() {
        store.reload()
    }

    func thumbnail(for record: ScreenshotHistoryRecord) -> NSImage? {
        store.thumbnail(for: record)
    }

    func copy(_ record: ScreenshotHistoryRecord) {
        do {
            let image = try loadImage(for: record)
            try paster.copy(image)
        } catch {
            show(error)
        }
    }

    func save(_ record: ScreenshotHistoryRecord) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let image = try loadImage(for: record)
                _ = try await saver.save(image)
            } catch {
                show(error)
            }
        }
    }

    func pin(_ record: ScreenshotHistoryRecord) {
        do {
            pinnedImageManager.pin(try loadImage(for: record))
        } catch {
            show(error)
        }
    }

    func addToCollage(_ record: ScreenshotHistoryRecord) {
        do {
            onAddToCollage(try loadImage(for: record))
        } catch {
            show(error)
        }
    }

    func delete(_ record: ScreenshotHistoryRecord) {
        do {
            try store.delete(record)
        } catch {
            show(error)
        }
    }

    func clear() {
        do {
            try store.clear()
        } catch {
            show(error)
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func loadImage(for record: ScreenshotHistoryRecord) throws -> CGImage {
        guard let image = store.image(for: record),
              let cgImage = image.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
              ) else {
            throw ScreenshotHistoryWindowError.imageUnavailable
        }
        return cgImage
    }

    private func show(_ error: Error) {
        errorMessage = error.localizedDescription
    }
}

@MainActor
final class ScreenshotHistoryWindowController: NSWindowController {
    let viewModel: ScreenshotHistoryViewModel

    init(
        store: ScreenshotHistoryStore,
        preferences: AppPreferences,
        paster: any ScreenshotPasting = PasteboardScreenshotPaster(),
        saver: any ScreenshotSaving = PNGScreenshotSaver(),
        pinnedImageManager: PinnedImageManager,
        onAddToCollage: @escaping @MainActor (CGImage) -> Void = { _ in }
    ) {
        viewModel = ScreenshotHistoryViewModel(
            store: store,
            paster: paster,
            saver: saver,
            pinnedImageManager: pinnedImageManager,
            onAddToCollage: onAddToCollage
        )
        let view = ScreenshotHistoryView(
            preferences: preferences,
            model: viewModel
        ).nylaiLocalized()
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = L10n.shared.string("最近截图")
        window.identifier = NSUserInterfaceItemIdentifier("nylai.screenshot-history")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 820, height: 620))
        window.minSize = NSSize(width: 640, height: 460)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从归档创建截图历史窗口")
    }

    func present() {
        viewModel.reload()
        guard let window else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func refreshLocalization() {
        window?.title = L10n.shared.string("最近截图")
    }
}

private struct ScreenshotHistoryView: View {
    @Bindable var preferences: AppPreferences
    @Bindable var model: ScreenshotHistoryViewModel
    @State private var confirmsClear = false

    private let columns = [
        GridItem(.adaptive(minimum: 190, maximum: 250), spacing: 16),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.65)

            if model.store.records.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        ForEach(model.store.records) { record in
                            ScreenshotHistoryCard(
                                record: record,
                                image: model.thumbnail(for: record),
                                onCopy: { model.copy(record) },
                                onSave: { model.save(record) },
                                onPin: { model.pin(record) },
                                onAddToCollage: { model.addToCollage(record) },
                                onDelete: { model.delete(record) }
                            )
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("无法完成操作", isPresented: errorPresented) {
            Button("好", role: .cancel) { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog(
            "清空全部最近截图？",
            isPresented: $confirmsClear,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) { model.clear() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(L10n.shared.string(
                "这会删除 %@ 管理的全部历史图片，不会删除已保存到其他位置的文件。",
                AppName.current
            ))
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("最近截图")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text("保留最近 50 张完成输出的截图")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let loadError = model.store.loadError {
                Label(loadError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .frame(maxWidth: 220, alignment: .trailing)
            }

            Toggle("记录新截图", isOn: $preferences.screenshotHistoryEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 11.5))

            Button {
                confirmsClear = true
            } label: {
                Label("清空", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.store.records.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("还没有完成的截图")
                .font(.system(size: 14, weight: .medium))
            Text(
                preferences.screenshotHistoryEnabled
                    ? L10n.shared.string("复制、保存或置顶截图后会自动出现在这里。")
                    : L10n.shared.string("最近截图记录已关闭，仍保留已有历史。")
            )
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.clearError() } }
        )
    }
}

private struct ScreenshotHistoryCard: View {
    let record: ScreenshotHistoryRecord
    let image: NSImage?
    let onCopy: () -> Void
    let onSave: () -> Void
    let onPin: () -> Void
    let onAddToCollage: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.045))

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(7)
                } else {
                    Label("图片不可用", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 118)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.primary.opacity(isHovering ? 0.14 : 0.07))
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(record.createdAt.formatted(
                    Date.FormatStyle(date: .abbreviated, time: .shortened)
                        .locale(L10n.shared.locale)
                ))
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(record.width) × \(record.height)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 9)
            .padding(.horizontal, 2)

            HStack(spacing: 4) {
                actionButton("复制", symbol: "doc.on.doc", action: onCopy)
                actionButton("保存", symbol: "square.and.arrow.down", action: onSave)
                actionButton("置顶", symbol: "pin", action: onPin)
                actionButton("加入拼图", symbol: "rectangle.3.group", action: onAddToCollage)
                Spacer(minLength: 0)
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("删除")
                .accessibilityLabel("删除截图")
            }
            .padding(.top, 7)
        }
        .padding(9)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(isHovering ? 1 : 0.72))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(.primary.opacity(isHovering ? 0.11 : 0.055))
        }
        .onHover { isHovering = $0 }
    }

    private func actionButton(
        _ title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        let localizedTitle = L10n.shared.string(title)
        return Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help(localizedTitle)
        .accessibilityLabel(localizedTitle)
    }
}

private enum ScreenshotHistoryWindowError: LocalizedError {
    case imageUnavailable

    var errorDescription: String? {
        L10n.shared.string("历史图片文件已丢失或无法读取。")
    }
}
