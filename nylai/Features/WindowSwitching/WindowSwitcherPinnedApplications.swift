import AppKit

struct WindowSwitcherPinnedApplication: Codable, Equatable, Identifiable {
    let bundleIdentifier: String
    let name: String
    let applicationURL: URL

    var id: String { bundleIdentifier }
}

@MainActor
final class WindowSwitcherPinnedApplications {
    private static let key = "window-switcher.pinned-applications"
    private let defaults: UserDefaults
    private let readError: Error?
    private(set) var applications: [WindowSwitcherPinnedApplication]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        do {
            if let data = defaults.data(forKey: Self.key) {
                let decoded = try JSONDecoder().decode([WindowSwitcherPinnedApplication].self, from: data)
                var seen = Set<String>()
                applications = decoded.filter { seen.insert($0.bundleIdentifier).inserted }
            } else {
                applications = []
            }
            readError = nil
        } catch {
            applications = []
            readError = error
        }
    }

    func toggle(_ application: WindowSwitcherApplication) throws {
        if let readError { throw readError }
        guard let identifier = application.bundleIdentifier else { throw WindowSwitcherError.targetUnavailable }
        var updated = applications
        if let index = updated.firstIndex(where: { $0.bundleIdentifier == identifier }) {
            updated.remove(at: index)
        } else {
            guard let url = application.applicationURL
                    ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
                throw WindowSwitcherError.targetUnavailable
            }
            updated.append(WindowSwitcherPinnedApplication(bundleIdentifier: identifier, name: application.name, applicationURL: url))
        }
        try save(updated)
    }

    func move(_ identifier: String, offset: Int) throws {
        if let readError { throw readError }
        guard let index = applications.firstIndex(where: { $0.bundleIdentifier == identifier }) else { return }
        let destination = index + offset
        guard applications.indices.contains(destination) else { return }
        var updated = applications
        updated.swapAt(index, destination)
        try save(updated)
    }

    func applying(to snapshot: WindowSwitcherSnapshot,
                  resolveURL: (WindowSwitcherPinnedApplication) -> URL? = { $0.applicationURL }) -> WindowSwitcherSnapshot {
        let pinned = applications.enumerated().map { order, pin -> WindowSwitcherApplication in
            if var running = snapshot.applications.first(where: { $0.isRunning && $0.bundleIdentifier == pin.bundleIdentifier }) {
                running.pinnedOrder = order
                running.applicationURL = running.applicationURL ?? resolveURL(pin) ?? pin.applicationURL
                return running
            }
            return WindowSwitcherApplication(id: -pid_t(order + 1), bundleIdentifier: pin.bundleIdentifier,
                                             name: pin.name, windows: [], applicationURL: resolveURL(pin) ?? pin.applicationURL,
                                             pinnedOrder: order)
        }
        let pinnedProcesses = Set(pinned.filter(\.isRunning).map(\.id))
        let remaining = snapshot.applications.compactMap { application -> WindowSwitcherApplication? in
            guard application.isRunning, !pinnedProcesses.contains(application.id) else { return nil }
            var unpinned = application
            unpinned.pinnedOrder = nil
            return unpinned
        }
        return WindowSwitcherSnapshot(applications: pinned + remaining, currentApplicationID: snapshot.currentApplicationID)
    }

    private func save(_ applications: [WindowSwitcherPinnedApplication]) throws {
        let data = try JSONEncoder().encode(applications)
        defaults.set(data, forKey: Self.key)
        self.applications = applications
    }
}
