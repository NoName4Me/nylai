import AppKit
import Observation
import SwiftUI

private final class WindowSwitcherHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
@Observable
final class WindowSwitcherPanelModel {
    var applications: [WindowSwitcherApplication] = []
    var selectedApplicationIndex = 0
    var selectedWindowID: CGWindowID?
    var previews: [CGWindowID: CGImage] = [:]
    var loadingWindowIDs: Set<CGWindowID> = []
    @ObservationIgnored var onSelectApplication: (Int) -> Void = { _ in }
    @ObservationIgnored var onSelectWindow: (CGWindowID) -> Void = { _ in }
    @ObservationIgnored var onTogglePin: (WindowSwitcherApplication) -> Void = { _ in }
    @ObservationIgnored var onMovePin: (String, Int) -> Void = { _, _ in }
    @ObservationIgnored var onConfirmApplication: () -> Void = {}

    var selectedApplication: WindowSwitcherApplication? {
        guard applications.indices.contains(selectedApplicationIndex) else {
            return nil
        }
        return applications[selectedApplicationIndex]
    }

    func update(with session: WindowSwitcherSession) {
        applications = session.snapshot.applications
        selectedApplicationIndex = session.selectedApplicationIndex
        selectedWindowID = session.selectedWindow?.id
    }

    func clear() {
        applications = []
        selectedApplicationIndex = 0
        selectedWindowID = nil
        previews = [:]
        loadingWindowIDs = []
    }

    func selectApplication(at index: Int) {
        guard applications.indices.contains(index) else { return }
        onSelectApplication(index)
    }

    func selectWindow(_ windowID: CGWindowID) {
        guard applications.contains(where: {
            $0.windows.contains(where: { $0.id == windowID })
        }) else {
            return
        }
        onSelectWindow(windowID)
    }
}

@MainActor
final class WindowSwitcherPanelController {
    let model = WindowSwitcherPanelModel()
    private let panel: NSPanel

    init() {
        let contentView = WindowSwitcherHostingView(
            rootView: WindowSwitcherPanelView(model: model).nylaiLocalized()
        )
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = contentView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = false
    }

    func present() {
        let screen = NSScreen.screens.first(where: {
            $0.frame.contains(NSEvent.mouseLocation)
        }) ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        let frame = Self.panelFrame(in: visibleFrame)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
    }

    static func panelFrame(in visibleFrame: CGRect) -> CGRect {
        let width = max(1, visibleFrame.width - 48)
        let height = max(1, visibleFrame.height - 48)
        return CGRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2,
            width: max(1, width),
            height: max(1, height)
        )
    }
}

struct WindowSwitcherPanelView: View {
    @Bindable var model: WindowSwitcherPanelModel
    @Environment(\.colorScheme) private var colorScheme
    @State var hoveredApplicationID: pid_t?
    @State var hoveredWindowID: CGWindowID?

    var body: some View {
        VStack(spacing: 0) {
            applicationStrip
            Divider().opacity(0.55)
            windowGrid
            Divider().opacity(0.55)
            footer
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 24)
        .background {
            WindowSwitcherBackdrop()
                .overlay(
                    Color.black.opacity(colorScheme == .dark ? 0.12 : 0.035)
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var applicationStrip: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(model.applications.enumerated()), id: \.element.id) { index, application in
                            applicationItem(
                                application,
                                index: index,
                                isSelected: index == model.selectedApplicationIndex
                            )
                                .id(application.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(minWidth: geometry.size.width, alignment: .center)
                }
                .onChange(of: model.selectedApplicationIndex) {
                    guard model.applications.indices.contains(model.selectedApplicationIndex) else {
                        return
                    }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(
                            model.applications[model.selectedApplicationIndex].id,
                            anchor: .center
                        )
                    }
                }
            }
        }
        .frame(height: 142)
    }

    private func applicationItem(
        _ application: WindowSwitcherApplication,
        index: Int,
        isSelected: Bool
    ) -> some View {
        let canManagePin = application.isPinned || !model.applications.contains {
            $0.isPinned && $0.bundleIdentifier == application.bundleIdentifier
        }
        return Button {
            model.selectApplication(at: index)
        } label: {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    applicationIcon(application)
                        .frame(width: 68, height: 68)
                        .padding(8)
                        .background(
                            isSelected
                                ? Color.primary.opacity(0.14)
                                : hoveredApplicationID == application.id
                                    ? Color.primary.opacity(0.06) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 18)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 18)
                                .strokeBorder(
                                    isSelected
                                        ? NylaiPalette.accent.opacity(0.95)
                                        : hoveredApplicationID == application.id
                                            ? Color.primary.opacity(0.24) : Color.clear,
                                    lineWidth: isSelected ? 2 : 1
                                )
                        }
                    if !application.windows.isEmpty {
                        Text("\(application.windows.count)")
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 6)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(.regularMaterial, in: Capsule())
                            .offset(x: 3, y: -3)
                    }
                }
                Text(application.name)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 96)
            }
            .frame(width: 100)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if canManagePin, application.bundleIdentifier != nil,
               application.isPinned || isSelected || hoveredApplicationID == application.id {
                Button { model.onTogglePin(application) } label: {
                    Image(systemName: application.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(application.isPinned ? NylaiPalette.accent : Color.secondary)
                        .frame(width: 24, height: 24)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .help(application.isPinned ? L10n.shared.string("取消固定") : L10n.shared.string("固定到前排"))
                .accessibilityLabel(application.isPinned ? L10n.shared.string("取消固定") : L10n.shared.string("固定到前排"))
                .offset(x: 0, y: 60)
            }
        }
        .contextMenu {
            if canManagePin, let identifier = application.bundleIdentifier {
                Button(application.isPinned ? L10n.shared.string("取消固定") : L10n.shared.string("固定到前排")) {
                    model.onTogglePin(application)
                }
                if let order = application.pinnedOrder {
                    Divider()
                    Button("向前移动") { model.onMovePin(identifier, -1) }.disabled(order == 0)
                    Button("向后移动") { model.onMovePin(identifier, 1) }
                        .disabled(order >= model.applications.filter(\.isPinned).count - 1)
                }
            }
        }
        .onHover { hovering in
            if hovering { hoveredApplicationID = application.id }
            else if hoveredApplicationID == application.id { hoveredApplicationID = nil }
        }
    }

    @ViewBuilder
    private var windowGrid: some View {
        if let application = model.selectedApplication, !application.windows.isEmpty {
            GeometryReader { geometry in
                let layout = WindowPreviewGridLayout(
                    windowCount: application.windows.count,
                    availableWidth: geometry.size.width,
                    availableHeight: geometry.size.height
                )
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: application.windows.count > 8) {
                        LazyVGrid(
                            columns: layout.columns,
                            alignment: .center,
                            spacing: 20
                        ) {
                            ForEach(application.windows) { window in
                                windowItem(window, isSelected: window.id == model.selectedWindowID)
                                    .frame(width: layout.itemWidth)
                                    .id(window.id)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 24)
                        .frame(maxWidth: layout.maximumWidth)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: geometry.size.height,
                            alignment: .center
                        )
                    }
                    .scrollDisabled(application.windows.count <= 8)
                    .onChange(of: model.selectedWindowID) {
                        guard let id = model.selectedWindowID else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                if let application = model.selectedApplication {
                    applicationIcon(application).frame(width: 64, height: 64)
                    Text(application.name)
                }
            } description: {
                Text(model.selectedApplication?.isRunning == false
                     ? L10n.shared.string("尚未运行") : L10n.shared.string("没有可预览的窗口"))
            } actions: {
                Button("打开应用") { model.onConfirmApplication() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func windowItem(
        _ window: WindowSwitcherWindow,
        isSelected: Bool
    ) -> some View {
        Button {
            model.selectWindow(window.id)
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.2))
                    if let preview = model.previews[window.id] {
                        Image(decorative: preview, scale: 1)
                            .resizable()
                            .scaledToFit()
                    } else if model.loadingWindowIDs.contains(window.id) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "macwindow")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                    }
                }
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                Text(window.title.flatMap { $0.isEmpty ? nil : $0 } ?? "未命名窗口")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(
                isSelected
                    ? Color.primary.opacity(0.12)
                    : hoveredWindowID == window.id ? Color.primary.opacity(0.05) : Color.clear,
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        isSelected ? NylaiPalette.accent
                            : hoveredWindowID == window.id ? Color.primary.opacity(0.24) : Color.clear,
                        lineWidth: isSelected ? 2.5 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { hoveredWindowID = window.id }
            else if hoveredWindowID == window.id { hoveredWindowID = nil }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            keycap("Tab")
            Text("切换应用")
                .padding(.trailing, 10)
            keycap("`")
            Text("切换窗口")
            Spacer()
            keycap("⌘")
            Text("松开确认")
                .padding(.trailing, 10)
            keycap("Esc")
            Text("取消")
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 24)
        .frame(height: 44)
    }

    private func keycap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: label == "⌘" || label == "`" ? 15 : 10.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(.primary)
            .padding(.horizontal, 7)
            .frame(minWidth: 24, minHeight: 21)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.13 : 0.07))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.24 : 0.16))
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.2 : 0.08), radius: 0.5, y: 1)
    }

    private func applicationIcon(_ application: WindowSwitcherApplication) -> some View {
        Group {
            if application.isRunning, let icon = NSRunningApplication(
                processIdentifier: application.id
            )?.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else if let url = application.applicationURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "app")
                    .resizable()
                    .scaledToFit()
                    .padding(7)
            }
        }
    }
}

struct WindowPreviewGridLayout {
    let columns: [GridItem]
    let maximumWidth: CGFloat
    let itemWidth: CGFloat

    init(windowCount: Int, availableWidth: CGFloat, availableHeight: CGFloat) {
        let safeWidth = max(360, availableWidth)
        let contentWidth = max(0, safeWidth - 48)
        let responsiveColumnCount = max(
            1,
            min(6, Int((contentWidth + 20) / 240))
        )
        let columnCount: Int
        switch windowCount {
        case 1:
            columnCount = 1
        case 2:
            columnCount = 2
        case 3:
            columnCount = 3
        case 4:
            columnCount = 2
        case 5...6:
            columnCount = 3
        case 7...8:
            columnCount = 4
        case 9:
            columnCount = 3
        case 10...12:
            columnCount = 4
        default:
            columnCount = max(4, responsiveColumnCount)
        }
        let rows = CGFloat(max(1, (windowCount + columnCount - 1) / columnCount))
        let widthLimit = max(1, (contentWidth - CGFloat(columnCount - 1) * 20) / CGFloat(columnCount))
        let heightLimit = max(1, (availableHeight - 48 - (rows - 1) * 20) / rows - 40) * 1.6 + 16
        itemWidth = windowCount <= 8 ? min(widthLimit, heightLimit) : widthLimit
        columns = Array(
            repeating: GridItem(.fixed(itemWidth), spacing: 20, alignment: .top),
            count: columnCount
        )
        maximumWidth = safeWidth
    }
}

private struct WindowSwitcherBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let view = NSGlassEffectView()
            view.style = .clear
            view.cornerRadius = 20
            return view
        }
#endif
        return Self.makeHUDView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
#if compiler(>=6.2)
        if #available(macOS 26.0, *),
           let glassView = nsView as? NSGlassEffectView {
            glassView.style = .clear
            glassView.cornerRadius = 20
            return
        }
#endif
        if let visualEffectView = nsView as? NSVisualEffectView {
            Self.configureHUDView(visualEffectView)
        }
    }

    private static func makeHUDView() -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configureHUDView(view)
        return view
    }

    private static func configureHUDView(_ view: NSVisualEffectView) {
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
    }
}
