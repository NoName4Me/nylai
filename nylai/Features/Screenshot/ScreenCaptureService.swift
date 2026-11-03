import AppKit
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
        try Task.checkCancellation()
        return try await permissionRecovery.perform {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw ScreenshotError.displayUnavailable
            }
            let ownApplications = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
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
        try Task.checkCancellation()
        return try await permissionRecovery.perform {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            try Task.checkCancellation()

            let windowIDs = content.windows.map(\.windowID)
            let frontToBackIDs = Self.frontToBackWindowIDs(
                excludingProcessID: ProcessInfo.processInfo.processIdentifier
            )
            let displaySpaces = Self.displayCoordinateSpaces()
            return frontToBackIDs.compactMap { windowID in
                guard windowIDs.contains(windowID),
                      let window = content.windows.first(where: { $0.windowID == windowID }),
                      window.isOnScreen,
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
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == windowID }),
                  window.isOnScreen else {
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
    nonisolated static func frontToBackWindowIDs(excludingProcessID processID: pid_t? = nil) -> [CGWindowID] {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
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
            "请在系统设置的屏幕录制权限中允许 nylai，然后重试；如系统要求，请重新打开 nylai。"
        case .permissionRestartRequired:
            "屏幕录制权限已开启，但当前运行中的 nylai 尚未取得权限。重新启动 nylai 后即可截图。"
        case .displayUnavailable:
            "主显示器不可用，请检查显示器连接后重试。"
        case .windowUnavailable:
            "目标窗口已关闭、最小化或当前不可捕获，请重新选择。"
        case .encodingFailed:
            "无法生成 PNG 图片，请重新截图。"
        }
    }
}
