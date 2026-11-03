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
        guard let frame else { return nil }
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
        let expected = accessibilityFrame(fromAppKitFrame: frame)
        return windows.first { window in
            let titleMatches = title == nil
                || Self.title(of: window) == title
            let frameMatches = expected.map {
                Self.frameMatches(Self.frame(of: window), $0)
            } ?? true
            return titleMatches && frameMatches
        }
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
