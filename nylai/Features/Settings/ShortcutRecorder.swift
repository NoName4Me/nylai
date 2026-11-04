import AppKit
import Carbon
@preconcurrency import CoreGraphics
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

@MainActor
final class ShortcutRecorderView: NSView {
    private var trackingArea: NSTrackingArea?
    nonisolated(unsafe) private var localRecordingEventMonitor: Any?
    nonisolated(unsafe) private var sessionRecordingEventMonitor: ShortcutRecordingEventMonitor?
    private var hasConsumedRecordingInput = false
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
            guard oldValue != isRecording else { return }
            hasConsumedRecordingInput = false
            if isRecording {
                installLocalRecordingEventMonitor()
                installSessionRecordingEventMonitor()
            } else {
                removeRecordingEventMonitors()
            }
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
    var interceptsSystemEvents = true

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

    deinit {
        if let localRecordingEventMonitor {
            NSEvent.removeMonitor(localRecordingEventMonitor)
        }
        if let sessionRecordingEventMonitor {
            Task { @MainActor in
                sessionRecordingEventMonitor.stop()
            }
        }
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
        if let shortcut, !isRecording {
            drawKeycaps(shortcut)
            return
        }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 7, yRadius: 7)

        let fillColor: NSColor
        if isRecording {
            fillColor = NylaiTheme.accent.withAlphaComponent(0.10)
        } else if isHovered {
            fillColor = NSColor.labelColor.withAlphaComponent(0.07)
        } else {
            fillColor = NSColor.labelColor.withAlphaComponent(0.04)
        }
        fillColor.setFill()
        path.fill()

        let borderColor: NSColor
        if isRecording {
            borderColor = NylaiTheme.accent
        } else if isHovered {
            borderColor = .tertiaryLabelColor
        } else {
            borderColor = .separatorColor
        }
        borderColor.setStroke()
        path.lineWidth = isRecording ? 1.5 : 1
        path.stroke()

        let text: String
        let font: NSFont?
        let color: NSColor
        if isRecording {
            text = "按下按键…"
            font = .systemFont(ofSize: 11.5, weight: .medium)
            color = NylaiTheme.accent
        } else {
            text = "未绑定"
            font = .systemFont(ofSize: 11.5)
            color = .secondaryLabelColor
        }
        var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
        ]
        if let font { attributes[.font] = font }
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    private func drawKeycaps(_ shortcut: ShortcutKey) {
        let labels = ShortcutDisplayFormatter.keycaps(for: shortcut)
        let gap: CGFloat = 3
        let width = min(24, (bounds.width - CGFloat(labels.count - 1) * gap) / CGFloat(labels.count))
        guard width > 0 else { return }
        let height: CGFloat = 21
        let start = bounds.midX - (CGFloat(labels.count) * (width + gap) - gap) / 2
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.labelColor]
        for (index, label) in labels.enumerated() {
            let modifier = index < labels.count - 1
            attributes[.font] = modifier ? NSFont.systemFont(ofSize: 14.5, weight: .medium)
                : NSFont(name: "Menlo", size: 11)
            let rect = CGRect(x: start + CGFloat(index) * (width + gap), y: bounds.midY - height / 2,
                              width: width, height: height)
            let cap = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            NSColor.labelColor.withAlphaComponent(isHovered ? 0.10 : 0.055).setFill()
            cap.fill()
            NSColor.separatorColor.setStroke()
            cap.lineWidth = 0.5
            cap.stroke()
            let text = label as NSString
            let size = text.size(withAttributes: attributes)
            let textRect = CGRect(x: rect.minX + 1, y: rect.midY - size.height / 2,
                                  width: rect.width - 2, height: size.height)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            attributes[.paragraphStyle] = paragraph
            text.draw(in: textRect, withAttributes: attributes)
        }
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
        handleRecordingKeyDown(event)
    }

    private func handleRecordingKeyDown(_ event: NSEvent) {
        guard !event.isARepeat, !hasConsumedRecordingInput else { return }
        switch ShortcutRecorderEvent.keyAction(for: event) {
        case .capture(let shortcut):
            hasConsumedRecordingInput = true
            onCapture(shortcut)
        case .clear:
            hasConsumedRecordingInput = true
            onClear()
        case .cancel:
            hasConsumedRecordingInput = true
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
        guard hasConsumedRecordingInput else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRecording else { return }
            self.hasConsumedRecordingInput = false
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else {
            super.flagsChanged(with: event)
            return
        }
        handleRecordingModifierChange(event)
    }

    private func handleRecordingModifierChange(_ event: NSEvent) {
        let modifiers = ShortcutRecorderEvent.modifiers(for: event.modifierFlags)
        if modifiers.isEmpty {
            onMessage(nil)
        } else {
            onMessage("仅按修饰键时继续等待，再按一个普通按键。")
        }
    }

    private func installLocalRecordingEventMonitor() {
        removeLocalRecordingEventMonitor()
        localRecordingEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged]
        ) { [weak self] event in
            guard let self, self.isRecording else { return event }
            if event.type == .flagsChanged {
                self.handleRecordingModifierChange(event)
            } else {
                self.handleRecordingKeyDown(event)
            }
            return nil
        }
    }

    private func installSessionRecordingEventMonitor() {
        guard interceptsSystemEvents, isRecording, sessionRecordingEventMonitor == nil else {
            return
        }
        guard ensureSystemInterceptionPermissions() else {
            interruptRecordingForUnavailableSystemInterception()
            return
        }
        let monitor = ShortcutRecordingEventMonitor()
        do {
            try monitor.start(
                onKeyDown: { [weak self] event in
                    self?.handleRecordingKeyDown(event)
                },
                onFlagsChanged: { [weak self] event in
                    self?.handleRecordingModifierChange(event)
                }
            ) { [weak self] message in
                self?.onMessage(message)
            }
            sessionRecordingEventMonitor = monitor
        } catch {
            onMessage(error.localizedDescription)
            interruptRecordingForUnavailableSystemInterception()
        }
    }

    private func ensureSystemInterceptionPermissions() -> Bool {
        let accessibilityGranted = AccessibilityPermission.isGranted
            || AccessibilityPermission.requestIfNeeded()
        guard accessibilityGranted else {
            onMessage("录入系统组合键需要开启“辅助功能”，授权后请再次点击。")
            return false
        }
        return true
    }

    private func interruptRecordingForUnavailableSystemInterception() {
        guard isRecording else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRecording else { return }
            self.isRecording = false
            self.onCancel()
        }
    }

    private func removeLocalRecordingEventMonitor() {
        guard let localRecordingEventMonitor else { return }
        NSEvent.removeMonitor(localRecordingEventMonitor)
        self.localRecordingEventMonitor = nil
    }

    private func removeRecordingEventMonitors() {
        removeLocalRecordingEventMonitor()
        let monitor = sessionRecordingEventMonitor
        sessionRecordingEventMonitor = nil
        guard let monitor else { return }
        DispatchQueue.main.async {
            monitor.stop()
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

struct ShortcutKeycaps: View {
    let shortcut: ShortcutKey

    var body: some View {
        HStack(spacing: 3) {
            let keys = ShortcutDisplayFormatter.keycaps(for: shortcut)
            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                Text(key)
                    .font(.system(size: index < keys.count - 1 ? 14.5 : 11, weight: .medium,
                                  design: index < keys.count - 1 ? .default : .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .frame(width: 24, height: 21)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ShortcutDisplayFormatter.string(for: shortcut))
    }
}

enum ShortcutDisplayFormatter {
    static func string(for shortcut: ShortcutKey) -> String {
        keycaps(for: shortcut).joined()
    }

    static func keycaps(for shortcut: ShortcutKey) -> [String] {
        var keys: [String] = []
        if shortcut.modifiers.contains(.control) { keys.append("⌃") }
        if shortcut.modifiers.contains(.option) { keys.append("⌥") }
        if shortcut.modifiers.contains(.shift) { keys.append("⇧") }
        if shortcut.modifiers.contains(.command) { keys.append("⌘") }
        keys.append(keyName(for: shortcut.keyCode))
        return keys
    }

    static func keyName(for keyCode: UInt32) -> String {
        if let namedKey = nonLocalizedKeyNameByCode[keyCode] {
            return namedKey
        }
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

    private static let nonLocalizedKeyNameByCode: [UInt32: String] = [
        UInt32(kVK_Return): "↩",
        UInt32(kVK_Tab): "⇥",
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Delete): "⌫",
        UInt32(kVK_Escape): "⎋",
        UInt32(kVK_ForwardDelete): "⌦",
        UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑",
        UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_Home): "↖",
        UInt32(kVK_End): "↘",
        UInt32(kVK_PageUp): "⇞",
        UInt32(kVK_PageDown): "⇟",
        UInt32(kVK_Help): "?",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
    ]

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
        keyAction(
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers(for: event.modifierFlags)
        )
    }

    static func keyAction(for event: CGEvent) -> Action {
        keyAction(
            keyCode: UInt32(event.getIntegerValueField(.keyboardEventKeycode)),
            modifiers: modifiers(for: event.flags)
        )
    }

    private static func keyAction(
        keyCode: UInt32,
        modifiers: ShortcutModifiers
    ) -> Action {

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

    static func modifiers(for flags: CGEventFlags) -> ShortcutModifiers {
        var modifiers: ShortcutModifiers = []
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        return modifiers
    }
}

enum ShortcutRecordingEventMonitorError: LocalizedError, Equatable {
    case permissionsRequired
    case eventTapCreationFailed
    case runLoopSourceCreationFailed

    var errorDescription: String? {
        switch self {
        case .permissionsRequired:
            "录入系统组合键需要开启“辅助功能”。"
        case .eventTapCreationFailed:
            "无法拦截系统组合键，请检查系统权限后重试。"
        case .runLoopSourceCreationFailed:
            "无法启动快捷键录入监听。"
        }
    }
}

@MainActor
final class ShortcutRecordingEventMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onKeyDown: ((NSEvent) -> Void)?
    private var onFlagsChanged: ((NSEvent) -> Void)?
    private var onFailure: ((String) -> Void)?

    var isRunning: Bool { eventTap != nil }

    nonisolated static func shouldConsume(type: CGEventType) -> Bool {
        type == .keyDown || type == .keyUp || type == .flagsChanged
    }

    func start(
        onKeyDown: @escaping (NSEvent) -> Void,
        onFlagsChanged: @escaping (NSEvent) -> Void,
        onFailure: @escaping (String) -> Void
    ) throws {
        stop()
        guard AccessibilityPermission.isGranted else {
            throw ShortcutRecordingEventMonitorError.permissionsRequired
        }
        self.onKeyDown = onKeyDown
        self.onFlagsChanged = onFlagsChanged
        self.onFailure = onFailure

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.tapDisabledByTimeout.rawValue)
            | (1 << CGEventType.tapDisabledByUserInput.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: Self.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            clearHandlers()
            throw ShortcutRecordingEventMonitorError.eventTapCreationFailed
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            clearHandlers()
            throw ShortcutRecordingEventMonitorError.runLoopSourceCreationFailed
        }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
        clearHandlers()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            onFailure?("快捷键录入监听被系统暂停，请重新点击录入。")
            return Unmanaged.passUnretained(event)
        }
        guard Self.shouldConsume(type: type) else {
            return Unmanaged.passUnretained(event)
        }
        if let event = NSEvent(cgEvent: event) {
            if type == .keyDown {
                onKeyDown?(event)
            } else if type == .flagsChanged {
                onFlagsChanged?(event)
            }
        }
        return nil
    }

    private func clearHandlers() {
        onKeyDown = nil
        onFlagsChanged = nil
        onFailure = nil
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let monitor = Unmanaged<ShortcutRecordingEventMonitor>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        let wrappedEvent = UncheckedShortcutCGEvent(value: event)
        return MainActor.assumeIsolated {
            monitor.handle(type: type, event: wrappedEvent.value)
        }
    }
}

private struct UncheckedShortcutCGEvent: @unchecked Sendable {
    nonisolated(unsafe) let value: CGEvent
}
