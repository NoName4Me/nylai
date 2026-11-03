import CoreGraphics
import Foundation

struct ScreenshotAnnotationViewport: Equatable, Sendable {
    let pixelSize: PixelSize
    let viewSize: CGSize

    init?(pixelSize: PixelSize, viewSize: CGSize) {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        self.pixelSize = pixelSize
        self.viewSize = viewSize
    }

    var scaleX: CGFloat {
        viewSize.width / CGFloat(pixelSize.width)
    }

    var scaleY: CGFloat {
        viewSize.height / CGFloat(pixelSize.height)
    }

    func viewRect(for rect: PixelRect) -> CGRect {
        CGRect(
            x: CGFloat(rect.x) * scaleX,
            y: CGFloat(rect.y) * scaleY,
            width: CGFloat(rect.width) * scaleX,
            height: CGFloat(rect.height) * scaleY
        )
    }

    func pixelRect(from viewRect: CGRect) -> PixelRect? {
        guard viewRect.width > 0, viewRect.height > 0 else { return nil }
        let left = floor(viewRect.minX * CGFloat(pixelSize.width) / viewSize.width)
        let top = floor(viewRect.minY * CGFloat(pixelSize.height) / viewSize.height)
        let right = ceil(viewRect.maxX * CGFloat(pixelSize.width) / viewSize.width)
        let bottom = ceil(viewRect.maxY * CGFloat(pixelSize.height) / viewSize.height)
        return PixelRect(
            x: Int(left),
            y: Int(top),
            width: Int(right - left),
            height: Int(bottom - top)
        ).clamped(to: pixelSize)
    }

    func pixelPoint(from viewPoint: CGPoint) -> PixelPoint {
        PixelPoint(
            x: min(
                max(Int(viewPoint.x * CGFloat(pixelSize.width) / viewSize.width), 0),
                pixelSize.width
            ),
            y: min(
                max(Int(viewPoint.y * CGFloat(pixelSize.height) / viewSize.height), 0),
                pixelSize.height
            )
        )
    }

    static func hitTest(
        _ point: CGPoint,
        annotations: [ScreenshotAnnotation],
        viewport: ScreenshotAnnotationViewport,
        visibleIn selection: CGRect
    ) -> UUID? {
        for annotation in annotations.reversed() {
            let viewRect = viewport.viewRect(for: annotation.rect)
            let visibleRect = viewRect.intersection(selection)
            if !visibleRect.isNull,
               selection.contains(point),
               ScreenshotAnnotationPath.hitTest(point, annotation: annotation, in: viewRect) {
                return annotation.id
            }
        }
        return nil
    }
}
