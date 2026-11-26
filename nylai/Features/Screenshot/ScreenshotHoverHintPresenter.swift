import AppKit

enum ScreenshotHoverHintLayout {
    static let gap: CGFloat = 6
    static let edgeInset: CGFloat = 5

    static func frame(anchor: CGRect, size: CGSize, visibleFrame: CGRect) -> CGRect {
        let width = min(size.width, max(0, visibleFrame.width - edgeInset * 2))
        let height = min(size.height, max(0, visibleFrame.height - edgeInset * 2))
        var x = anchor.midX - width / 2
        var y = anchor.maxY + gap
        if y + height > visibleFrame.maxY {
            y = anchor.minY - height - gap
        }
        x = min(max(x, visibleFrame.minX + edgeInset), visibleFrame.maxX - width - edgeInset)
        y = min(max(y, visibleFrame.minY + edgeInset), visibleFrame.maxY - height - edgeInset)
        return CGRect(x: x.rounded(.down), y: y.rounded(.down), width: width, height: height)
    }
}

@MainActor
final class ScreenshotHoverHintPresenter {
    static let shared = ScreenshotHoverHintPresenter()

    private struct Request: Equatable {
        let text: String
        let anchor: CGRect
        let owner: ObjectIdentifier
    }

    private var panel: NSPanel?
    private var label: NSTextField?
    private var pendingRequest: Request?
    private var visibleRequest: Request?
    private var presentationTask: Task<Void, Never>?

    private init() {}

    func show(_ text: String, anchor: CGRect, in window: NSWindow, owner: AnyObject) {
        let request = Request(
            text: text,
            anchor: anchor.integral,
            owner: ObjectIdentifier(owner)
        )
        guard !text.isEmpty else {
            dismiss(owner: owner)
            return
        }
        if visibleRequest == request {
            pendingRequest = nil
            presentationTask?.cancel()
            presentationTask = nil
            return
        }
        guard pendingRequest != request else { return }
        pendingRequest = request
        presentationTask?.cancel()
        presentationTask = Task { @MainActor [weak self, weak window] in
            try? await Task.sleep(for: .milliseconds(360))
            guard !Task.isCancelled,
                  let self,
                  let window,
                  self.pendingRequest == request else { return }
            self.present(request, in: window)
        }
    }

    func dismiss(owner: AnyObject) {
        let identifier = ObjectIdentifier(owner)
        if pendingRequest?.owner == identifier {
            pendingRequest = nil
            presentationTask?.cancel()
            presentationTask = nil
        }
        if visibleRequest?.owner == identifier {
            hidePanel()
        }
    }

    func dismissAll() {
        pendingRequest = nil
        presentationTask?.cancel()
        presentationTask = nil
        hidePanel()
    }

    var visibleText: String? {
        visibleRequest?.text
    }

    private func present(_ request: Request, in window: NSWindow) {
        let screen = NSScreen.screens.first { $0.frame.intersects(request.anchor) }
            ?? window.screen
            ?? NSScreen.main
        guard let screen else { return }

        let panel = panel ?? makePanel()
        self.panel = panel
        let label = label ?? makeLabel()
        self.label = label
        if label.superview !== panel.contentView {
            label.removeFromSuperview()
            panel.contentView?.addSubview(label)
        }

        let appearance = window.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            panel.contentView?.layer?.backgroundColor =
                NylaiTheme.panelBackground(for: appearance).cgColor
            panel.contentView?.layer?.borderColor =
                NylaiTheme.border(for: appearance).cgColor
            label.textColor = NylaiTheme.primaryText(for: appearance)
        }

        label.stringValue = request.text
        let fittingSize = label.fittingSize
        let size = CGSize(width: fittingSize.width + 16, height: fittingSize.height + 10)
        let frame = ScreenshotHoverHintLayout.frame(
            anchor: request.anchor,
            size: size,
            visibleFrame: screen.visibleFrame
        )
        label.frame = CGRect(
            x: (frame.width - fittingSize.width) / 2,
            y: (frame.height - fittingSize.height) / 2,
            width: fittingSize.width,
            height: fittingSize.height
        )
        panel.setFrame(frame, display: true)
        panel.level = NSWindow.Level(
            rawValue: max(window.level.rawValue + 1, NSWindow.Level.floating.rawValue)
        )
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFrontRegardless()
        pendingRequest = nil
        visibleRequest = request
    }

    private func hidePanel() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        visibleRequest = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSApp.appearance
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let content = NSView()
        content.wantsLayer = true
        content.layer?.cornerRadius = 6
        content.layer?.borderWidth = 1
        panel.contentView = content
        return panel
    }

    private func makeLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.alignment = .center
        return label
    }
}
