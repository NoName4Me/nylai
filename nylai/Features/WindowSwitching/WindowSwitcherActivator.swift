import AppKit
import ApplicationServices

@MainActor
protocol WindowSwitcherActivating {
    func activate(_ target: WindowSwitcherTarget) async throws
}

@MainActor
protocol WindowSwitcherWindowClosing {
    func close(
        windowID: CGWindowID,
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        title: String?,
        frame: CGRect
    ) async throws
}

@MainActor
final class WindowSwitcherWindowCloser: WindowSwitcherWindowClosing {
    private let isAccessibilityGranted: @MainActor () -> Bool
    private let applicationIsAvailable: @MainActor (
        pid_t,
        String?
    ) -> Bool
    private let resolveWindow: @MainActor (
        pid_t,
        CGWindowID,
        String?,
        CGRect?
    ) -> AXUIElement?
    private let pressClose: @MainActor (AXUIElement) -> Bool

    init(
        isAccessibilityGranted: @escaping @MainActor () -> Bool = {
            AccessibilityPermission.isGranted
        },
        applicationIsAvailable: @escaping @MainActor (
            pid_t,
            String?
        ) -> Bool = { processIdentifier, bundleIdentifier in
            guard let application = NSRunningApplication(
                processIdentifier: processIdentifier
            ) else {
                return false
            }
            return !application.isTerminated
                && application.bundleIdentifier == bundleIdentifier
        },
        resolveWindow: @escaping @MainActor (
            pid_t,
            CGWindowID,
            String?,
            CGRect?
        ) -> AXUIElement? = { processIdentifier, windowID, title, frame in
            WindowSwitcherActivator.windowElement(
                processIdentifier: processIdentifier,
                windowID: windowID,
                title: title,
                frame: frame
            )
        },
        pressClose: @escaping @MainActor (AXUIElement) -> Bool = {
            WindowSwitcherWindowCloser.pressCloseButton(of: $0)
        }
    ) {
        self.isAccessibilityGranted = isAccessibilityGranted
        self.applicationIsAvailable = applicationIsAvailable
        self.resolveWindow = resolveWindow
        self.pressClose = pressClose
    }

    func close(
        windowID: CGWindowID,
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        title: String?,
        frame: CGRect
    ) async throws {
        guard isAccessibilityGranted() else {
            throw WindowSwitcherError.accessibilityUnavailable
        }
        guard processIdentifier > 0,
              applicationIsAvailable(processIdentifier, bundleIdentifier),
              let window = resolveWindow(
                  processIdentifier,
                  windowID,
                  title,
                  frame
              ) else {
            throw WindowSwitcherError.windowUnavailable
        }
        guard pressClose(window) else {
            throw WindowSwitcherError.windowNotClosable
        }
    }

    static func pressCloseButton(of window: AXUIElement) -> Bool {
        guard let closeButton = closeButton(of: window) else {
            return false
        }
        return AXUIElementPerformAction(
            closeButton,
            kAXPressAction as CFString
        ) == .success
    }

    private static func closeButton(of window: AXUIElement) -> AXUIElement? {
        var rawCloseButton: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXCloseButtonAttribute as CFString,
            &rawCloseButton
        ) == .success,
        let rawCloseButton,
        CFGetTypeID(rawCloseButton) == AXUIElementGetTypeID() else {
            return nil
        }
        let closeButton = rawCloseButton as! AXUIElement
        var rawEnabled: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            closeButton,
            kAXEnabledAttribute as CFString,
            &rawEnabled
        ) == .success,
        (rawEnabled as? Bool) != false else {
            return nil
        }
        return closeButton
    }
}

@MainActor
final class WindowSwitcherActivator: WindowSwitcherActivating {
    private let isAccessibilityGranted: @MainActor () -> Bool
    private let openApplication: @MainActor (URL) async throws -> Void
    private let activationService: ApplicationActivationService

    init(
        isAccessibilityGranted: @escaping @MainActor () -> Bool = {
            AccessibilityPermission.isGranted
        },
        openApplication: @escaping @MainActor (URL) async throws -> Void = { url in
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    ) {
        self.isAccessibilityGranted = isAccessibilityGranted
        self.openApplication = openApplication
        activationService = ApplicationActivationService(
            openApplication: openApplication
        )
    }

    func activate(_ target: WindowSwitcherTarget) async throws {
        guard let application = Self.runningApplication(for: target) else {
            guard target.launchIfNeeded, let url = target.applicationURL,
                  let identifier = target.bundleIdentifier,
                  Bundle(url: url)?.bundleIdentifier == identifier else {
                throw WindowSwitcherError.targetUnavailable
            }
            try await openApplication(url)
            return
        }
        guard let windowID = target.windowID else {
            do {
                try await activationService.activate(ApplicationActivationTarget(application))
            } catch {
                throw WindowSwitcherError.targetUnavailable
            }
            return
        }
        guard isAccessibilityGranted() else {
            throw WindowSwitcherError.accessibilityUnavailable
        }
        var window = Self.windowElement(
            processIdentifier: application.processIdentifier,
            windowID: windowID,
            title: target.windowTitle,
            frame: target.windowFrame
        )
        if window == nil {
            try? await Task.sleep(for: .milliseconds(80))
            window = Self.windowElement(
                processIdentifier: application.processIdentifier,
                windowID: windowID,
                title: target.windowTitle,
                frame: target.windowFrame
            )
        }
        guard let window else {
            throw WindowSwitcherError.windowUnavailable
        }
        do {
            try activationService.activate(
                window: window,
                target: ApplicationActivationTarget(application),
                restoresMinimizedWindow: true
            )
        } catch {
            throw WindowSwitcherError.windowUnavailable
        }
    }

    private static func runningApplication(
        for target: WindowSwitcherTarget
    ) -> NSRunningApplication? {
        if target.processIdentifier > 0,
           let application = NSRunningApplication(
               processIdentifier: target.processIdentifier
           ),
           !application.isTerminated,
           application.bundleIdentifier == target.bundleIdentifier {
            return application
        }
        guard let bundleIdentifier = target.bundleIdentifier else {
            return nil
        }
        return NSWorkspace.shared.runningApplications.first {
            !$0.isTerminated && $0.bundleIdentifier == bundleIdentifier
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
