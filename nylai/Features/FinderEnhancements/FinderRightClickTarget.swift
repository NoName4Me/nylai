import AppKit
import ApplicationServices
import FinderSync

@MainActor
enum FinderRightClickTarget {
    private static var mouseMonitor: Any?
    private static var lastRightClick: (point: CGPoint, time: TimeInterval)?

    static func startObserving() {
        guard FIFinderSyncController.isExtensionEnabled else {
            stopObserving()
            return
        }
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDown) { event in
            let point = event.locationInWindow
            let time = event.timestamp
            Task { @MainActor in
                guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return }
                lastRightClick = (point, time)
            }
        }
    }

    static func stopObserving() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        lastRightClick = nil
    }

    static func resolve(point: CGPoint, candidates: [URL], menuCreatedAt: TimeInterval?) -> URL? {
        guard AXIsProcessTrusted(),
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
              let primaryScreen = NSScreen.screens.first else { return nil }
        let observed = lastRightClick.flatMap {
            if let menuCreatedAt, abs(menuCreatedAt - $0.time) < 2 { return $0.point }
            return nil
        } ?? point
        let location = CGPoint(x: observed.x, y: primaryScreen.frame.maxY - observed.y)
        let application = AXUIElementCreateApplication(finder.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.2)
        let paths = Set(candidates.map(\.path))
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        var matches = Set<String>()
        var remaining = 3000

        func urls(in element: AXUIElement, depth: Int) -> Set<String> {
            guard depth < 8, remaining > 0, ProcessInfo.processInfo.systemUptime < deadline else { return [] }
            remaining -= 1
            var found = Set<String>()
            let rawURL = value(kAXURLAttribute, of: element)
            if let url = rawURL as? URL,
               paths.contains(url.standardizedFileURL.path) {
                found.insert(url.standardizedFileURL.path)
            }
            for child in (value(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? []) {
                found.formUnion(urls(in: child, depth: depth + 1))
            }
            return found
        }

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 14, remaining > 0, ProcessInfo.processInfo.systemUptime < deadline else { return }
            remaining -= 1
            let frame = rect(of: element)
            if let frame, !frame.contains(location) { return }
            if let role = value(kAXRoleAttribute, of: element) as? String,
               role == kAXRowRole, frame?.contains(location) == true {
                matches.formUnion(urls(in: element, depth: 0))
                return
            }
            if frame?.contains(location) == true,
               let url = value(kAXURLAttribute, of: element) as? URL,
               paths.contains(url.standardizedFileURL.path) {
                matches.insert(url.standardizedFileURL.path)
            }
            for child in (value(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? []) {
                visit(child, depth: depth + 1)
            }
        }

        for window in (value(kAXWindowsAttribute, of: application) as? [AXUIElement] ?? []) {
            visit(window, depth: 0)
        }
        guard matches.count == 1, let path = matches.first else { return nil }
        return candidates.first { $0.path == path }
    }

    private static func value(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    private static func rect(of element: AXUIElement) -> CGRect? {
        guard let position = value(kAXPositionAttribute, of: element),
              let size = value(kAXSizeAttribute, of: element),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }
}
