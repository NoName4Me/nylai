import AppKit
import CoreGraphics
import CoreText

enum ScreenshotAnnotationRenderer {
    static func render(
        source: ScreenshotImageSource,
        selection: PixelRect,
        annotations: [ScreenshotAnnotation]
    ) throws -> CGImage {
        guard selection == selection.clamped(to: source.geometry.pixelSize) else {
            throw ScreenshotGeometryError.selectionOutsideSource
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: selection.width,
            height: selection.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ScreenshotOutputError.imageRenderingFailed
        }
        guard let cropped = source.image.cropping(to: selection.cgRect) else {
            throw ScreenshotGeometryError.emptySelection
        }

        context.interpolationQuality = .none
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: selection.width, height: selection.height))

        for annotation in annotations {
            let sourceRect = annotation.rect
            let rect = sourceRect.cgRect.offsetBy(
                dx: -CGFloat(selection.minX),
                dy: -CGFloat(selection.minY)
            )
            guard rect.intersects(
                CGRect(x: 0, y: 0, width: selection.width, height: selection.height)
            ) else {
                continue
            }
            let contextRect = CGRect(
                x: rect.minX,
                y: CGFloat(selection.height) - rect.maxY,
                width: rect.width,
                height: rect.height
            )
            if annotation.kind == .mosaic {
                guard let processed = ScreenshotPixelProcessor.processedImage(
                    source: source.image,
                    rect: sourceRect,
                    kind: annotation.kind,
                    intensity: annotation.style.lineWidth
                ) else {
                    continue
                }
                context.saveGState()
                context.interpolationQuality = .none
                context.draw(processed, in: contextRect)
                context.restoreGState()
                continue
            }
            if annotation.kind == .text {
                drawText(annotation, in: contextRect, context: context)
                continue
            }
            if annotation.kind == .step {
                drawStep(annotation, in: contextRect, context: context)
                continue
            }
            var renderAnnotation = annotation
            renderAnnotation.start.y = sourceRect.minY + sourceRect.maxY - annotation.start.y
            renderAnnotation.end.y = sourceRect.minY + sourceRect.maxY - annotation.end.y
            let path = ScreenshotAnnotationPath.cgPath(
                for: renderAnnotation,
                in: contextRect, flipped: false
            )
            if let fill = ScreenshotAnnotationPath.fillPath(for: renderAnnotation, in: contextRect, flipped: false) {
                context.addPath(fill)
                context.setFillColor(annotation.style.color.cgColor)
                context.fillPath()
            }
            context.addPath(path)
            context.setStrokeColor(annotation.style.color.cgColor)
            context.setLineWidth(CGFloat(annotation.style.lineWidth))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            if annotation.style.lineStyle == .dashed {
                let width = CGFloat(annotation.style.lineWidth)
                context.setLineDash(phase: 0, lengths: [width * 3, width * 2])
            } else {
                context.setLineDash(phase: 0, lengths: [])
            }
            context.strokePath()
        }

        guard let image = context.makeImage() else {
            throw ScreenshotOutputError.imageRenderingFailed
        }
        return image
    }

    private static func drawText(
        _ annotation: ScreenshotAnnotation,
        in rect: CGRect,
        context: CGContext
    ) {
        guard !annotation.text.isEmpty, rect.width > 0, rect.height > 0 else { return }
        let filled = annotation.style.fillsTextBackground == true
        if filled {
            context.setFillColor(annotation.style.color.cgColor)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
            context.fillPath()
        }
        let fontSize = max(CGFloat(annotation.style.lineWidth), 8)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: annotation.style.textColor,
        ]
        let string = NSAttributedString(string: annotation.text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let path = CGPath(
            rect: rect.insetBy(dx: filled ? 4 : 1, dy: filled ? 3 : 1),
            transform: nil
        )
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            path,
            nil
        )
        CTFrameDraw(frame, context)
    }

    private static func drawStep(
        _ annotation: ScreenshotAnnotation,
        in rect: CGRect,
        context: CGContext
    ) {
        guard let stepNumber = annotation.stepNumber else { return }
        context.setFillColor(annotation.style.color.cgColor)
        context.fillEllipse(in: rect)
        let fontSize = max(9, min(rect.height * 0.56, 20))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "\(stepNumber)", attributes: attributes)
        )
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(
            line,
            &ascent,
            &descent,
            nil
        ))
        context.textPosition = CGPoint(
            x: rect.midX - width / 2,
            y: rect.midY - (ascent - descent) / 2
        )
        CTLineDraw(line, context)
    }
}
