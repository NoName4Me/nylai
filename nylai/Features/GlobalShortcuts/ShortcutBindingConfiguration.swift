import Carbon
import Foundation

struct ShortcutModifiers: OptionSet, Codable, Equatable, Hashable, Sendable {
    let rawValue: UInt8

    static let command = ShortcutModifiers(rawValue: 1 << 0)
    static let option = ShortcutModifiers(rawValue: 1 << 1)
    static let control = ShortcutModifiers(rawValue: 1 << 2)
    static let shift = ShortcutModifiers(rawValue: 1 << 3)
    static let supported: ShortcutModifiers = [.command, .option, .control, .shift]
}

struct ShortcutKey: Codable, Equatable, Hashable, Sendable {
    let keyCode: UInt32
    let modifiers: ShortcutModifiers

    init(keyCode: UInt32, modifiers: ShortcutModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt32.self, forKey: .keyCode)
        modifiers = try container.decode(ShortcutModifiers.self, forKey: .modifiers)

        guard keyCode <= 127 else {
            throw DecodingError.dataCorruptedError(
                forKey: .keyCode,
                in: container,
                debugDescription: "物理键码超出支持范围。"
            )
        }
        guard modifiers.subtracting(.supported).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .modifiers,
                in: container,
                debugDescription: "包含不支持的修饰键。"
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case keyCode
        case modifiers
    }
}

struct ShortcutBindingID: Codable, Equatable, Hashable, Sendable {
    static let openSettings = ShortcutBindingID(rawValue: "internal.open-settings")
    // 仅用于读取版本 1／2 的旧配置，迁移完成后不再写入。
    static let captureMainDisplay = ShortcutBindingID(rawValue: "internal.capture-main-display")
    static let captureInteractive = ShortcutBindingID(rawValue: "internal.capture-interactive")
    static let screenshotHistory = ShortcutBindingID(rawValue: "internal.screenshot-history")
    static let collage = ShortcutBindingID(rawValue: "internal.collage")
    static let scrollCapture = ShortcutBindingID(rawValue: "internal.scroll-capture")
    static let clipboardHistory = ShortcutBindingID(rawValue: "internal.clipboard-history")

    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
        guard !rawValue.isEmpty else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "快捷键绑定 ID 不能为空。"
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct ApplicationShortcutTarget: Codable, Equatable, Sendable {
    var bundleIdentifier: String
    var path: String
    var hidesOnRepeatTrigger: Bool
}

enum ShortcutAction: Equatable, Sendable {
    case openSettings
    // 仅用于读取版本 1／2 的旧配置。
    case captureMainDisplay
    case captureInteractive
    case screenshotHistory
    case openCollage
    case scrollCapture
    case clipboardHistory
    case application(ApplicationShortcutTarget)
}

extension ShortcutAction: Codable {
    private enum Kind: String, Codable {
        case openSettings
        case captureMainDisplay
        case captureInteractive
        case screenshotHistory
        case openCollage
        case scrollCapture
        case clipboardHistory
        case application
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case application
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .openSettings:
            self = .openSettings
        case .captureMainDisplay:
            self = .captureMainDisplay
        case .captureInteractive:
            self = .captureInteractive
        case .screenshotHistory:
            self = .screenshotHistory
        case .openCollage:
            self = .openCollage
        case .scrollCapture:
            self = .scrollCapture
        case .clipboardHistory:
            self = .clipboardHistory
        case .application:
            self = .application(try container.decode(ApplicationShortcutTarget.self, forKey: .application))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .openSettings:
            try container.encode(Kind.openSettings, forKey: .kind)
        case .captureMainDisplay:
            try container.encode(Kind.captureMainDisplay, forKey: .kind)
        case .captureInteractive:
            try container.encode(Kind.captureInteractive, forKey: .kind)
        case .screenshotHistory:
            try container.encode(Kind.screenshotHistory, forKey: .kind)
        case .openCollage:
            try container.encode(Kind.openCollage, forKey: .kind)
        case .scrollCapture:
            try container.encode(Kind.scrollCapture, forKey: .kind)
        case .clipboardHistory:
            try container.encode(Kind.clipboardHistory, forKey: .kind)
        case .application(let target):
            try container.encode(Kind.application, forKey: .kind)
            try container.encode(target, forKey: .application)
        }
    }
}

struct ShortcutBinding: Codable, Equatable, Sendable {
    let id: ShortcutBindingID
    let action: ShortcutAction
    var shortcut: ShortcutKey?
    var isEnabled: Bool
}

extension ShortcutBinding {
    var applicationTarget: ApplicationShortcutTarget? {
        if case .application(let target) = action {
            return target
        }
        return nil
    }
}

struct ShortcutBindingConfiguration: Codable, Equatable, Sendable {
    static let currentVersion = 8

    var version: Int
    var isEnabled: Bool
    var bindings: [ShortcutBinding]

    static let defaults = ShortcutBindingConfiguration(
        version: currentVersion,
        isEnabled: false,
        bindings: [
            ShortcutBinding(
                id: .openSettings,
                action: .openSettings,
                shortcut: nil,
                isEnabled: true
            ),
            ShortcutBinding(
                id: .captureInteractive,
                action: .captureInteractive,
                shortcut: ShortcutKey(
                    keyCode: UInt32(kVK_ANSI_A),
                    modifiers: [.option]
                ),
                isEnabled: true
            ),
            ShortcutBinding(
                id: .screenshotHistory,
                action: .screenshotHistory,
                shortcut: nil,
                isEnabled: true
            ),
            ShortcutBinding(
                id: .collage,
                action: .openCollage,
                shortcut: nil,
                isEnabled: true
            ),
            ShortcutBinding(
                id: .scrollCapture,
                action: .scrollCapture,
                shortcut: nil,
                isEnabled: true
            ),
            ShortcutBinding(
                id: .clipboardHistory,
                action: .clipboardHistory,
                shortcut: nil,
                isEnabled: true
            ),
        ]
    )
}
