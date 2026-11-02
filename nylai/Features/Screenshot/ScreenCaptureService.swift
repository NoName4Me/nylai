import AppKit
import CoreVideo
import ScreenCaptureKit

@MainActor
final class ScreenCaptureService: ScreenCapturing {
    private let requestAccess: @MainActor () -> Bool

    init(requestAccess: @escaping @MainActor () -> Bool = { ScreenRecordingPermission.requestAccessIfNeeded() }) {
        self.requestAccess = requestAccess
    }

    func captureDisplay(_ displayID: CGDirectDisplayID) async throws -> CGImage {
        guard requestAccess() else { throw ScreenshotError.permissionRequired }
        try Task.checkCancellation()
        do {
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
        } catch {
            let nativeError = error as NSError
            if nativeError.domain == SCStreamErrorDomain,
               nativeError.code == SCStreamError.Code.userDeclined.rawValue {
                throw ScreenshotError.permissionRequired
            }
            throw error
        }
    }
}

enum ScreenshotError: LocalizedError, Equatable {
    case permissionRequired
    case displayUnavailable
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            "请在系统设置的屏幕录制权限中允许 nylai，然后重试；如系统要求，请重新打开 nylai。"
        case .displayUnavailable:
            "主显示器不可用，请检查显示器连接后重试。"
        case .encodingFailed:
            "无法生成 PNG 图片，请重新截图。"
        }
    }
}
