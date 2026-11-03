import AppKit
import Carbon
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: ShortcutKey?
    let isRecording: Bool
    let onBegin: () -> Bool
    let onCapture: (ShortcutKey) -> Void
    let onCancel: () -> Void
    let onClear: () -> Void
    let onMessage: (String?) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        update(view)
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        update(view)
    }

    private func update(_ view: ShortcutRecorderView) {
        view.shortcut = shortcut
        view.isRecording = isRecording
        view.onBegin = onBegin
        view.onCapture = onCapture
        view.onCancel = onCancel
        view.onClear = onClear
        view.onMessage = onMessage
        if isRecording, view.window?.firstResponder !== view {
            view.window?.makeFirstResponder(view)
        } else if !isRecording, view.window?.firstResponder === view {
            view.window?.makeFirstResponder(nil)
        }
    }
}

final class ShortcutRecorderView: NSView {
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    var shortcut: ShortcutKey? {
        didSet { needsDisplay = true }
    }
    var isRecording = false {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            if !isRecording, window?.firstResponder === self {
                window?.makeFirstResponder(nil)
            }
        }
    }
    var onBegin: () -> Bool = { false }
    var onCapture: (ShortcutKey) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onClear: () -> Void = {}
    var onMessage: (String?) -> Void = { _ in }

    override var acceptsFirstResponder: Bool { isRecording }
    override var focusRingMaskBounds: NSRect { .zero }
    override var intrinsicContentSize: NSSize { NSSize(width: 112, height: 28) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从归档创建快捷键录入控件")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isRecording ? .arrow : .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 7, yRadius: 7)

        let fillColor: NSColor
        if isRecording {
            fillColor = NSColor.controlAccentColor.withAlphaComponent(0.10)
        } else if isHovered {
            fillColor = NSColor.labelColor.withAlphaComponent(0.07)
        } else {
            fillColor = NSColor.labelColor.withAlphaComponent(0.04)
        }
        fillColor.setFill()
        path.fill()

        let borderColor: NSColor
        if isRecording {
            borderColor = .controlAccentColor
        } else if isHovered {
            borderColor = .tertiaryLabelColor
        } else {
            borderColor = .separatorColor
        }
        borderColor.setStroke()
        path.lineWidth = isRecording ? 1.5 : 1
        path.stroke()

        let text: String
        let font: NSFont
        let color: NSColor
        if isRecording {
            text = "按下按键…"
            font = .systemFont(ofSize: 11.5, weight: .medium)
            color = .controlAccentColor
        } else if let shortcut {
            text = ShortcutDisplayFormatter.string(for: shortcut)
            font = .monospacedSystemFont(ofSize: 12.5, weight: .medium)
            color = .labelColor
        } else {
            text = "未绑定"
            font = .systemFont(ofSize: 11.5)
            color = .secondaryLabelColor
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        if !isRecording {
            guard onBegin() else { return }
            isRecording = true
        }
        window?.makeFirstResponder(self)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let clear = menu.addItem(withTitle: "清除", action: #selector(clearShortcut), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = shortcut != nil
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func clearShortcut() {
        onClear()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        switch ShortcutRecorderEvent.keyAction(for: event) {
        case .capture(let shortcut):
            onCapture(shortcut)
        case .clear:
            onClear()
        case .cancel:
            onCancel()
        case .ignore:
            onMessage("仅按修饰键时继续等待，至少需要一个 Command、Option 或 Control。")
        case .reserved:
            onMessage(ShortcutValidationError.reserved.localizedDescription)
            NSSound.beep()
        case .invalid:
            onMessage(ShortcutValidationError.invalidKey.localizedDescription)
            NSSound.beep()
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else {
            super.flagsChanged(with: event)
            return
        }
        let modifiers = ShortcutRecorderEvent.modifiers(for: event.modifierFlags)
        if modifiers.isEmpty {
            onMessage(nil)
        } else {
            onMessage("仅按修饰键时继续等待，再按一个普通按键。")
        }
    }

    override func resignFirstResponder() -> Bool {
        if isRecording {
            onCancel()
        }
        return super.resignFirstResponder()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { isRecording ? "正在录入快捷键" : "快捷键" }
    override func accessibilityHelp() -> String? {
        "点击后按下新的快捷键，按 Escape 取消，按 Delete 清除。"
    }
    override func accessibilityValue() -> Any? {
        shortcut.map(ShortcutDisplayFormatter.string) ?? "未绑定"
    }
}

enum ShortcutDisplayFormatter {
    static func string(for shortcut: ShortcutKey) -> String {
        var value = ""
        if shortcut.modifiers.contains(.control) { value += "⌃" }
        if shortcut.modifiers.contains(.option) { value += "⌥" }
        if shortcut.modifiers.contains(.shift) { value += "⇧" }
        if shortcut.modifiers.contains(.command) { value += "⌘" }
        value += keyName(for: shortcut.keyCode)
        return value
    }

    static func keyName(for keyCode: UInt32) -> String {
        if let localizedName = localizedKeyName(for: keyCode) {
            return localizedName
        }
        return keyNameByCode[keyCode] ?? "Key \(keyCode)"
    }

    private static func localizedKeyName(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let dataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(dataPointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { bytes -> OSStatus in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                0,
                OptionBits(0),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        let value = String(utf16CodeUnits: characters, count: length)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return value.uppercased()
    }

    private static let keyNameByCode: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_D): "D",
        UInt32(kVK_ANSI_F): "F", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_G): "G",
        UInt32(kVK_ANSI_Z): "Z", UInt32(kVK_ANSI_X): "X", UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_Q): "Q",
        UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_U): "U", UInt32(kVK_ANSI_I): "I", UInt32(kVK_ANSI_P): "P",
        UInt32(kVK_ANSI_L): "L", UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K",
        UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_M): "M",
        UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2", UInt32(kVK_ANSI_3): "3",
        UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5", UInt32(kVK_ANSI_6): "6",
        UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8", UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_ANSI_0): "0",
        UInt32(kVK_ANSI_Equal): "=", UInt32(kVK_ANSI_Minus): "-",
        UInt32(kVK_ANSI_RightBracket): "]", UInt32(kVK_ANSI_LeftBracket): "[",
        UInt32(kVK_ANSI_Quote): "'", UInt32(kVK_ANSI_Semicolon): ";",
        UInt32(kVK_ANSI_Backslash): "\\", UInt32(kVK_ANSI_Comma): ",",
        UInt32(kVK_ANSI_Slash): "/", UInt32(kVK_ANSI_Period): ".",
        UInt32(kVK_ANSI_Grave): "`",
        UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥", UInt32(kVK_Space): "Space",
        UInt32(kVK_Delete): "⌫", UInt32(kVK_Escape): "⎋",
        UInt32(kVK_ForwardDelete): "⌦",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_ANSI_Keypad0): "0", UInt32(kVK_ANSI_Keypad1): "1",
        UInt32(kVK_ANSI_Keypad2): "2", UInt32(kVK_ANSI_Keypad3): "3",
        UInt32(kVK_ANSI_Keypad4): "4", UInt32(kVK_ANSI_Keypad5): "5",
        UInt32(kVK_ANSI_Keypad6): "6", UInt32(kVK_ANSI_Keypad7): "7",
        UInt32(kVK_ANSI_Keypad8): "8", UInt32(kVK_ANSI_Keypad9): "9",
    ]
}

enum ShortcutRecorderEvent {
    enum Action: Equatable {
        case capture(ShortcutKey)
        case clear
        case cancel
        case ignore
        case reserved
        case invalid
    }

    static func keyAction(for event: NSEvent) -> Action {
        let modifiers = modifiers(for: event.modifierFlags)
        let keyCode = UInt32(event.keyCode)

        if modifiers.isEmpty, keyCode == UInt32(kVK_Escape) {
            return .cancel
        }
        if modifiers.isEmpty,
           keyCode == UInt32(kVK_Delete) || keyCode == UInt32(kVK_ForwardDelete) {
            return .clear
        }
        if modifiers.isEmpty {
            return .invalid
        }
        guard !modifiers.intersection([.command, .option, .control]).isEmpty else {
            return .ignore
        }

        let shortcut = ShortcutKey(keyCode: keyCode, modifiers: modifiers)
        if ReservedShortcut.isReserved(shortcut) {
            return .reserved
        }
        return .capture(shortcut)
    }

    static func modifiers(for flags: NSEvent.ModifierFlags) -> ShortcutModifiers {
        var modifiers: ShortcutModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }
}
