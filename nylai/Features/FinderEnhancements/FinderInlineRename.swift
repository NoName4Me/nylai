import AppKit
import ApplicationServices

@MainActor
enum FinderInlineRename {
    static func begin(for url: URL) async {
        guard AccessibilityPermission.requestIfNeeded() else { return }
        for _ in 0..<20 {
            do { try await Task.sleep(for: .milliseconds(75)) } catch { return }
            guard let finder = NSWorkspace.shared.frontmostApplication,
                  finder.bundleIdentifier == "com.apple.finder" else { continue }
            let application = AXUIElementCreateApplication(finder.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.1)
            guard let window = value(kAXFocusedWindowAttribute, of: application) as! AXUIElement? else { continue }
            var remaining = 1500
            let expected = url.resolvingSymlinksInPath().path
            guard selectionMatches(in: window, expected: expected, remaining: &remaining, depth: 0) else { continue }
            if let menuBar = value(kAXMenuBarAttribute, of: application) as! AXUIElement? {
                var menuBudget = 1000
                if let command = renameCommand(in: menuBar, remaining: &menuBudget, depth: 0),
                   AXUIElementPerformAction(command, kAXPressAction as CFString) == .success {
                    return
                }
            }
            guard CGPreflightPostEventAccess(),
                  let down = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false) else { return }
            down.flags = []
            up.flags = []
            down.postToPid(finder.processIdentifier)
            up.postToPid(finder.processIdentifier)
            return
        }
    }

    private static func selectionMatches(in element: AXUIElement, expected: String, remaining: inout Int, depth: Int) -> Bool {
        guard remaining > 0, depth < 14 else { return false }
        remaining -= 1
        let selected = (value(kAXSelectedRowsAttribute, of: element) as? [AXUIElement])
            ?? (value(kAXSelectedChildrenAttribute, of: element) as? [AXUIElement]) ?? []
        if !selected.isEmpty {
            let paths = selected.reduce(into: Set<String>()) {
                $0.formUnion(urls(in: $1, remaining: &remaining, depth: 0))
            }
            if paths.contains(expected) { return paths == [expected] }
        }
        for child in children(of: element) {
            if selectionMatches(in: child, expected: expected, remaining: &remaining, depth: depth + 1) { return true }
        }
        return false
    }

    private static func urls(in element: AXUIElement, remaining: inout Int, depth: Int) -> Set<String> {
        guard remaining > 0, depth < 8 else { return [] }
        remaining -= 1
        var result = Set<String>()
        if let url = value(kAXURLAttribute, of: element) as? URL {
            result.insert(url.resolvingSymlinksInPath().path)
        }
        for child in children(of: element) {
            result.formUnion(urls(in: child, remaining: &remaining, depth: depth + 1))
        }
        return result
    }

    private static func renameCommand(in element: AXUIElement, remaining: inout Int, depth: Int) -> AXUIElement? {
        guard remaining > 0, depth < 5 else { return nil }
        remaining -= 1
        if value(kAXIdentifierAttribute, of: element) as? String == "cmdRename:",
           value(kAXEnabledAttribute, of: element) as? Bool == true {
            return element
        }
        for child in children(of: element) {
            if let command = renameCommand(in: child, remaining: &remaining, depth: depth + 1) { return command }
        }
        return nil
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        value(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? []
    }

    private static func value(_ attribute: String, of element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }
}
