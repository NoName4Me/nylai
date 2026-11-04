import Foundation

enum AppName {
    static var current: String {
        L10n.shared.appName
    }
}
