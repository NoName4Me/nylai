import AppKit
import ApplicationServices
import CoreVideo
import ScreenCaptureKit

@MainActor
final class ScreenCaptureService: ScreenCapturing, WindowCapturing {
    private let permissionRecovery: ScreenCapturePermissionRecovery

    init(
        requestAccess: @escaping @MainActor () -> Bool = {
            ScreenRecordingPermission.requestAccessIfNeeded()
        }
    ) {
        permissionRecovery = ScreenCapturePermissionRecovery(requestAccess: requestAccess)
    }

    func captureDisplay(_ displayID: CGDirectDisplayID) async throws -> CGImage {
        try await captureDisplay(
            displayID,
            excludingOwnApplication: false
        )
    }

    func captureDisplayExcludingOwnApplication(
        _ displayID: CGDirectDisplayID
    ) async throws -> CGImage {
        try await captureDisplay(
            displayID,
            excludingOwnApplication: true
        )
    }

    private func captureDisplay(
        _ displayID: CGDirectDisplayID,
        excludingOwnApplication: Bool
    ) async throws -> CGImage {
        try Task.checkCancellation()
        return try await permissionRecovery.perform {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw ScreenshotError.displayUnavailable
            }
            let excludedApplications = excludingOwnApplication
                ? content.applications.filter {
                    $0.bundleIdentifier == Bundle.main.bundleIdentifier
                }
                : []
            let filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApplications,
                exceptingWindows: []
            )
            let configuration = SCStreamConfiguration()
            configuration.width = Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded())
            configuration.height = Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded())
            configuration.showsCursor = false
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.colorSpaceName = CGColorSpace.sRGB
            try Task.checkCancellation()
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            try Task.checkCancellation()
            return image
        }
    }

    func windowCandidates() async throws -> [WindowCaptureCandidate] {
        try await windowCandidates(includeOffscreenWindows: false)
    }

    func switchableWindowCandidates() async throws -> [WindowCaptureCandidate] {
        try await windowCandidates(includeOffscreenWindows: true)
    }

    private func windowCandidates(
        includeOffscreenWindows: Bool
    ) async throws -> [WindowCaptureCandidate] {
        try Task.checkCancellation()
        return try await permissionRecovery.perform {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: !includeOffscreenWindows
            )
            try Task.checkCancellation()

            let windowsByID = Dictionary(
                uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) }
            )
            let frontToBackIDs = Self.frontToBackWindowIDs(
                excludingProcessID: nil,
                includeOffscreenWindows: includeOffscreenWindows
            )
            let displaySpaces = Self.displayCoordinateSpaces()
            let processIdentifiersToVerify = Set(
                frontToBackIDs.compactMap { windowID -> pid_t? in
                    guard let window = windowsByID[windowID],
                          !window.isOnScreen
                            || WindowCaptureAccessibilityMatcher.normalizedTitle(window.title) == nil,
                          Self.isRegularApplicationWindow(window) else {
                        return nil
                    }
                    return window.owningApplication?.processID
                }
            )
            let accessibilityWindows = Dictionary(
                uniqueKeysWithValues: processIdentifiersToVerify.map {
                    ($0, Self.accessibilityWindows(processIdentifier: $0))
                }
            )
            return frontToBackIDs.compactMap { windowID in
                guard let window = windowsByID[windowID],
                      (!includeOffscreenWindows
                        || Self.isSwitchableApplicationWindow(
                            window,
                            accessibilityWindows: accessibilityWindows
                        )),
                      let frame = Self.appKitWindowFrame(
                        fromCoreGraphicsFrame: window.frame,
                        displaySpaces: displaySpaces
                      ) else {
                    return nil
                }
                return WindowCaptureCandidate(
                    windowID: windowID,
                    processIdentifier: window.owningApplication?.processID ?? 0,
                    frame: frame,
                    title: window.title,
                    applicationName: window.owningApplication?.applicationName,
                    bundleIdentifier: window.owningApplication?.bundleIdentifier
                )
            }
        }
    }

    func captureWindow(_ windowID: CGWindowID) async throws -> CGImage {
        try Task.checkCancellation()
        return try await permissionRecovery.perform {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw ScreenshotError.windowUnavailable
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded()))
            configuration.height = max(1, Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded()))
            configuration.showsCursor = false
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.colorSpaceName = CGColorSpace.sRGB
            try Task.checkCancellation()
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            try Task.checkCancellation()
            return image
        }
    }

    // CGWindowListCopyWindowInfo 明确按前到后返回，可用于命中遮挡关系。
    nonisolated static func frontToBackWindowIDs(
        excludingProcessID processID: pid_t? = nil,
        includeOffscreenWindows: Bool = false
    ) -> [CGWindowID] {
        guard let windows = CGWindowListCopyWindowInfo(
            [
                includeOffscreenWindows ? .optionAll : .optionOnScreenOnly,
                .excludeDesktopElements,
            ],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return windows.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? NSNumber,
                  let layer = info[kCGWindowLayer as String] as? NSNumber,
                  let alpha = info[kCGWindowAlpha as String] as? NSNumber,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
                  layer.intValue == 0,
                  alpha.doubleValue > 0,
                  ownerPID.int32Value != processID else {
                return nil
            }
            return CGWindowID(number.uint32Value)
        }
    }

    private nonisolated static func isSwitchableApplicationWindow(
        _ window: SCWindow,
        accessibilityWindows: [pid_t: [WindowCaptureAccessibilityWindow]]
    ) -> Bool {
        guard isRegularApplicationWindow(window),
              let processIdentifier = window.owningApplication?.processID else {
            return false
        }
        if window.isOnScreen,
           WindowCaptureAccessibilityMatcher.normalizedTitle(window.title) != nil {
            return true
        }
        return WindowCaptureAccessibilityMatcher.contains(
            candidateID: window.windowID,
            candidateTitle: window.title,
            candidateFrame: window.frame,
            in: accessibilityWindows[processIdentifier] ?? []
        )
    }

    private nonisolated static func accessibilityWindows(
        processIdentifier: pid_t
    ) -> [WindowCaptureAccessibilityWindow] {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.2)
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &rawWindows
        ) == .success,
        let windows = rawWindows as? [AXUIElement] else {
            return []
        }
        return windows.compactMap { window in
            guard let frame = accessibilityFrame(of: window) else {
                return nil
            }
            return WindowCaptureAccessibilityWindow(
                windowID: WindowCaptureAccessibilityMatcher.windowID(of: window),
                title: accessibilityTitle(of: window),
                frame: frame
            )
        }
    }

    private nonisolated static func accessibilityTitle(
        of window: AXUIElement
    ) -> String? {
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

    private nonisolated static func accessibilityFrame(
        of window: AXUIElement
    ) -> CGRect? {
        guard let position = accessibilityPoint(
            attribute: kAXPositionAttribute,
            of: window
        ), let size = accessibilitySize(
            attribute: kAXSizeAttribute,
            of: window
        ) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private nonisolated static func accessibilityPoint(
        attribute: String,
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

    private nonisolated static func accessibilitySize(
        attribute: String,
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

    private nonisolated static func isRegularApplicationWindow(_ window: SCWindow) -> Bool {
        guard window.windowLayer == 0,
              let processIdentifier = window.owningApplication?.processID,
              let application = NSRunningApplication(
                processIdentifier: processIdentifier
              ) else {
            return false
        }
        return application.activationPolicy == .regular
    }

    struct DisplayCoordinateSpace: Equatable, Sendable {
        let coreGraphicsBounds: CGRect
        let appKitFrame: CGRect
    }

    nonisolated static func displayCoordinateSpaces() -> [DisplayCoordinateSpace] {
        NSScreen.screens.compactMap { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
            let displayID = CGDirectDisplayID(number.uint32Value)
            return DisplayCoordinateSpace(
                coreGraphicsBounds: CGDisplayBounds(displayID),
                appKitFrame: screen.frame
            )
        }
    }

    // SCWindow.frame 使用 CoreGraphics 顶左原点；覆盖层与 NSScreen 使用 AppKit 底左原点。
    nonisolated static func appKitWindowFrame(
        fromCoreGraphicsFrame frame: CGRect,
        displaySpaces: [DisplayCoordinateSpace]
    ) -> CGRect? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard let space = displaySpaces.first(where: {
            $0.coreGraphicsBounds.contains(center)
        }) else {
            return nil
        }
        return CGRect(
            x: space.appKitFrame.minX + (frame.minX - space.coreGraphicsBounds.minX),
            y: space.appKitFrame.minY + (space.coreGraphicsBounds.maxY - frame.maxY),
            width: frame.width,
            height: frame.height
        )
    }

    nonisolated static func coreGraphicsPoint(
        fromAppKitPoint point: CGPoint,
        displaySpaces: [DisplayCoordinateSpace]
    ) -> CGPoint? {
        guard let space = displaySpaces.first(where: {
            point.x >= $0.appKitFrame.minX
                && point.x <= $0.appKitFrame.maxX
                && point.y >= $0.appKitFrame.minY
                && point.y <= $0.appKitFrame.maxY
        }) else {
            return nil
        }
        return CGPoint(
            x: space.coreGraphicsBounds.minX + point.x - space.appKitFrame.minX,
            y: space.coreGraphicsBounds.minY + space.appKitFrame.maxY - point.y
        )
    }
}

@MainActor
struct ScreenCapturePermissionRecovery {
    let isAccessGranted: @MainActor () -> Bool
    let requestAccess: @MainActor () -> Bool

    init(
        isAccessGranted: @escaping @MainActor () -> Bool = {
            ScreenRecordingPermission.isGranted
        },
        requestAccess: @escaping @MainActor () -> Bool = {
            ScreenRecordingPermission.requestAccessIfNeeded()
        }
    ) {
        self.isAccessGranted = isAccessGranted
        self.requestAccess = requestAccess
    }

    func perform<T>(_ operation: @MainActor () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            guard Self.isPermissionError(error) else { throw error }
            // A running process can keep a stale authorization cache after the
            // user grants access in System Settings.
            guard !isAccessGranted() else {
                throw ScreenshotError.permissionRestartRequired
            }
            guard requestAccess() else { throw ScreenshotError.permissionRequired }
            do {
                return try await operation()
            } catch {
                if Self.isPermissionError(error) {
                    // CGRequestScreenCaptureAccess returned true, so the grant
                    // exists but this process still cannot use it.
                    throw ScreenshotError.permissionRestartRequired
                }
                throw error
            }
        }
    }

    nonisolated static func isPermissionError(_ error: Error) -> Bool {
        let nativeError = error as NSError
        return nativeError.domain == SCStreamErrorDomain
            && nativeError.code == SCStreamError.Code.userDeclined.rawValue
    }
}

enum ScreenshotError: LocalizedError, Equatable {
    case permissionRequired
    case permissionRestartRequired
    case displayUnavailable
    case windowUnavailable
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            "请在系统设置的屏幕录制权限中允许 \(AppName.current)，然后重试；如系统要求，请重新打开 \(AppName.current)。"
        case .permissionRestartRequired:
            "屏幕录制权限已开启，但当前运行中的 \(AppName.current) 尚未取得权限。重新启动 \(AppName.current) 后即可截图。"
        case .displayUnavailable:
            "主显示器不可用，请检查显示器连接后重试。"
        case .windowUnavailable:
            "目标窗口已关闭、最小化或当前不可捕获，请重新选择。"
        case .encodingFailed:
            "无法生成 PNG 图片，请重新截图。"
        }
    }
}
