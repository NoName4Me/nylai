import Foundation

extension Notification.Name {
    static let nylaiLanguageDidChange = Notification.Name(
        "com.noname4me.nylai.languageDidChange"
    )
}

final class L10n: @unchecked Sendable {
    static let shared = L10n()

    private let lock = NSLock()
    private var language = AppLanguage.system
    private var cachedEnglishBundle: Bundle?

    private init() {}

    var appName: String {
        resolvedLanguage == .simplifiedChinese ? "拈来" : "Nylai"
    }

    var locale: Locale {
        resolvedLanguage.locale
    }

    func setLanguage(_ language: AppLanguage) {
        lock.withLock {
            self.language = language
        }
    }

    func string(_ key: String) -> String {
        let resolved = resolvedLanguage
        guard resolved == .english else { return key }
        guard let bundle = englishBundle else { return key }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    func string(_ key: String, _ arguments: CVarArg...) -> String {
        let format = string(key)
        guard !arguments.isEmpty else { return format }
        return String(format: format, arguments: arguments)
    }

    private var resolvedLanguage: AppLanguage {
        let configured = lock.withLock { language }
        guard configured == .system else { return configured }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return preferred.hasPrefix("zh") ? .simplifiedChinese : .english
    }

    private var englishBundle: Bundle? {
        if let cachedEnglishBundle {
            return cachedEnglishBundle
        }
        guard let path = Bundle.main.path(forResource: "en", ofType: "lproj")
                ?? Bundle(for: LocalizationBundleToken.self)
                    .path(forResource: "en", ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return nil
        }
        lock.withLock {
            cachedEnglishBundle = bundle
        }
        return bundle
    }
}

private final class LocalizationBundleToken {}
