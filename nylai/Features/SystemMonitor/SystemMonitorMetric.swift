import Foundation

enum SystemMonitorMetric: String, CaseIterable, Codable, Sendable {
    case cpu, memory, network, storage

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: L10n.shared.string("内存")
        case .network: L10n.shared.string("网络")
        case .storage: L10n.shared.string("存储")
        }
    }
}

extension Notification.Name {
    static let systemMonitorConfigurationDidChange = Notification.Name("systemMonitorConfigurationDidChange")
}
