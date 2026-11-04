import Foundation

enum AppName {
    static var current: String {
        if let localizedName = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleDisplayName"
        ) as? String,
        !localizedName.isEmpty {
            return localizedName
        }
        return "Nylai"
    }
}
