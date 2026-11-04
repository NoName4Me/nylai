import AppKit
import CoreGraphics

struct PixelSize: Equatable, Sendable {
    let width: Int
    let height: Int

    init(width: Int, height: Int) throws {
        guard width > 0, height > 0 else {
            throw ScreenshotGeometryError.invalidSourceSize
        }
        self.width = width
        self.height = height
    }
}

struct PixelRect: Equatable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    var minX: Int { x }
    var minY: Int { y }
    var maxX: Int { x + width }
    var maxY: Int { y + height }

    func clamped(to size: PixelSize, minimumWidth: Int = 1, minimumHeight: Int = 1) -> PixelRect? {
        let left = min(max(x, 0), size.width)
        let top = min(max(y, 0), size.height)
        let right = min(max(maxX, 0), size.width)
        let bottom = min(max(maxY, 0), size.height)
        guard right > left, bottom > top else { return nil }
        return PixelRect(
            x: left,
            y: top,
            width: max(right - left, min(minimumWidth, size.width)),
            height: max(bottom - top, min(minimumHeight, size.height))
        )
    }

    func offsetBy(dx: Int, dy: Int) -> PixelRect {
        PixelRect(x: x + dx, y: y + dy, width: width, height: height)
    }

    func intersection(_ other: PixelRect) -> PixelRect? {
        let left = max(minX, other.minX)
        let top = max(minY, other.minY)
        let right = min(maxX, other.maxX)
        let bottom = min(maxY, other.maxY)
        guard right > left, bottom > top else { return nil }
        return PixelRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

enum ScreenshotSourceKind: Equatable, Sendable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
}

// 所有 frame 使用 AppKit 全局屏幕坐标（左下角原点）；选区与标注使用原图左上角像素坐标。
struct ScreenshotSourceGeometry: Equatable, Sendable {
    let kind: ScreenshotSourceKind
    let globalFrame: CGRect
    let pointPixelScale: CGFloat
    let pixelSize: PixelSize

    init(
        kind: ScreenshotSourceKind,
        globalFrame: CGRect,
        pointPixelScale: CGFloat,
        pixelSize: PixelSize
    ) throws {
        guard globalFrame.width > 0, globalFrame.height > 0, pointPixelScale > 0 else {
            throw ScreenshotGeometryError.invalidSourceGeometry
        }
        self.kind = kind
        self.globalFrame = globalFrame
        self.pointPixelScale = pointPixelScale
        self.pixelSize = pixelSize
    }

    var mapper: ScreenshotCoordinateMapper {
        ScreenshotCoordinateMapper(geometry: self)
    }
}

struct ScreenshotImageSource {
    let image: CGImage
    let geometry: ScreenshotSourceGeometry

    init(image: CGImage, geometry: ScreenshotSourceGeometry) throws {
        guard image.width == geometry.pixelSize.width,
              image.height == geometry.pixelSize.height else {
            throw ScreenshotGeometryError.imageSizeMismatch
        }
        self.image = image
        self.geometry = geometry
    }

    func cropped(to selection: PixelRect) throws -> CGImage {
        guard selection == selection.clamped(to: geometry.pixelSize) else {
            throw ScreenshotGeometryError.selectionOutsideSource
        }
        guard let cropped = image.cropping(to: selection.cgRect) else {
            throw ScreenshotGeometryError.emptySelection
        }
        return cropped
    }
}

struct ScreenshotCoordinateMapper: Equatable, Sendable {
    let geometry: ScreenshotSourceGeometry

    func pixelRect(fromGlobalScreenRect rect: CGRect) throws -> PixelRect {
        let clipped = rect.intersection(geometry.globalFrame)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else {
            throw ScreenshotGeometryError.emptySelection
        }

        let scale = geometry.pointPixelScale
        let left = floor((clipped.minX - geometry.globalFrame.minX) * scale)
        let right = ceil((clipped.maxX - geometry.globalFrame.minX) * scale)
        let top = floor((geometry.globalFrame.maxY - clipped.maxY) * scale)
        let bottom = ceil((geometry.globalFrame.maxY - clipped.minY) * scale)
        let converted = PixelRect(
            x: Int(left),
            y: Int(top),
            width: Int(right - left),
            height: Int(bottom - top)
        )
        guard let result = converted.clamped(to: geometry.pixelSize) else {
            throw ScreenshotGeometryError.emptySelection
        }
        return result
    }

    func globalScreenRect(fromPixelRect rect: PixelRect) -> CGRect {
        let scale = geometry.pointPixelScale
        return CGRect(
            x: geometry.globalFrame.minX + CGFloat(rect.x) / scale,
            y: geometry.globalFrame.maxY - CGFloat(rect.maxY) / scale,
            width: CGFloat(rect.width) / scale,
            height: CGFloat(rect.height) / scale
        )
    }

    func globalScreenPoint(fromPixelPoint point: CGPoint) -> CGPoint {
        CGPoint(
            x: geometry.globalFrame.minX + point.x / geometry.pointPixelScale,
            y: geometry.globalFrame.maxY - point.y / geometry.pointPixelScale
        )
    }

    func pixelPoint(fromGlobalScreenPoint point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - geometry.globalFrame.minX) * geometry.pointPixelScale,
            y: (geometry.globalFrame.maxY - point.y) * geometry.pointPixelScale
        )
    }

    static func appKitLocalRect(fromGlobalScreenRect rect: CGRect, in windowFrame: CGRect) -> CGRect {
        rect.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY)
    }

    static func globalScreenRect(fromAppKitLocalRect rect: CGRect, in windowFrame: CGRect) -> CGRect {
        rect.offsetBy(dx: windowFrame.minX, dy: windowFrame.minY)
    }
}

enum ScreenshotGeometryError: LocalizedError, Equatable {
    case invalidSourceSize
    case invalidSourceGeometry
    case imageSizeMismatch
    case emptySelection
    case selectionOutsideSource

    var errorDescription: String? {
        switch self {
        case .invalidSourceSize:
            L10n.shared.string("图像尺寸无效。")
        case .invalidSourceGeometry:
            L10n.shared.string("截图源的位置或像素比例无效。")
        case .imageSizeMismatch:
            L10n.shared.string("截图源尺寸与图像像素尺寸不一致。")
        case .emptySelection:
            L10n.shared.string("拖出的区域没有有效面积。")
        case .selectionOutsideSource:
            L10n.shared.string("选区必须位于图像范围内。")
        }
    }
}
