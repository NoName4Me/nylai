import AppKit
import ApplicationServices

@MainActor
protocol WindowSwitcherActivating {
    func activate(_ target: WindowSwitcherTarget) async throws
}

@MainActor
final class WindowSwitcherActivator: WindowSwitcherActivating {
    private let isAccessibilityGranted: @MainActor () -> Bool

    init(
        isAccessibilityGranted: @escaping @MainActor () -> Bool = {
            AccessibilityPermission.isGranted
        }
    ) {
        self.isAccessibilityGranted = isAccessibilityGranted
    }

    func activate(_ target: WindowSwitcherTarget) async throws {
        guard let application = NSRunningApplication(
            processIdentifier: target.processIdentifier
        ), application.bundleIdentifier == target.bundleIdentifier else {
            throw WindowSwitcherError.targetUnavailable
        }
        guard let windowID = target.windowID else {
            guard application.activate(options: [.activateAllWindows]) else {
                throw WindowSwitcherError.targetUnavailable
            }
            return
        }
        guard isAccessibilityGranted() else {
            throw WindowSwitcherError.accessibilityUnavailable
        }
        guard let window = Self.windowElement(
            processIdentifier: target.processIdentifier,
            windowID: windowID,
            title: target.windowTitle,
            frame: target.windowFrame
        ) else {
            throw WindowSwitcherError.windowUnavailable
        }
        AXUIElementSetAttributeValue(
            window,
            kAXMinimizedAttribute as CFString,
            kCFBooleanFalse
        )
        guard application.activate(options: [.activateAllWindows]) else {
            throw WindowSwitcherError.targetUnavailable
        }
        AXUIElementSetAttributeValue(
            window,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        AXUIElementSetAttributeValue(
            window,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
        )
        let result = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        guard result == .success else {
            throw WindowSwitcherError.windowUnavailable
        }
    }

    static func windowElement(
        processIdentifier: pid_t,
        windowID: CGWindowID,
        title: String?,
        frame: CGRect?
    ) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.5)
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &rawWindows
        ) == .success,
        let windows = rawWindows as? [AXUIElement] else {
            return nil
        }
        let identified = windows.map { ($0, WindowCaptureAccessibilityMatcher.windowID(of: $0)) }
        if let exact = identified.first(where: { $0.1 == windowID }) {
            return exact.0
        }
        guard let frame, let expected = accessibilityFrame(fromAppKitFrame: frame),
              let title = WindowCaptureAccessibilityMatcher.normalizedTitle(title) else { return nil }
        let matches = identified.filter { window, identifier in
            identifier == nil
                && WindowCaptureAccessibilityMatcher.normalizedTitle(Self.title(of: window)) == title
                && Self.frameMatches(Self.frame(of: window), expected)
        }
        return matches.count == 1 ? matches[0].0 : nil
    }

    static func accessibilityFrame(fromAppKitFrame frame: CGRect) -> CGRect? {
        ScreenCaptureService.coreGraphicsPoint(
            fromAppKitPoint: CGPoint(x: frame.minX, y: frame.maxY),
            displaySpaces: ScreenCaptureService.displayCoordinateSpaces()
        ).map {
            CGRect(origin: $0, size: frame.size)
        }
    }

    static func frameMatches(_ actual: CGRect?, _ expected: CGRect) -> Bool {
        guard let actual else { return false }
        let tolerance: CGFloat = 3
        return abs(actual.minX - expected.minX) <= tolerance
            && abs(actual.minY - expected.minY) <= tolerance
            && abs(actual.width - expected.width) <= tolerance
            && abs(actual.height - expected.height) <= tolerance
    }

    private static func title(of window: AXUIElement) -> String? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXTitleAttribute as CFString,
            &rawValue
        ) == .success else {
            return nil
        }
        return rawValue as? String
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        guard let position = pointAttribute(kAXPositionAttribute, of: window),
              let size = sizeAttribute(kAXSizeAttribute, of: window) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func pointAttribute(
        _ attribute: String,
        of element: AXUIElement
    ) -> CGPoint? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &rawValue
        ) == .success,
        let value = rawValue,
        CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private static func sizeAttribute(
        _ attribute: String,
        of element: AXUIElement
    ) -> CGSize? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &rawValue
        ) == .success,
        let value = rawValue,
        CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else {
            return nil
        }
        return size
    }
}
