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
            guard !renderAnnotation.isTaperedArrow else { continue }
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
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        ScreenshotTextLayout.draw(annotation, in: CGRect(origin: .zero, size: rect.size))
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }

    private static func drawStep(
        _ annotation: ScreenshotAnnotation,
        in rect: CGRect,
        context: CGContext
    ) {
        guard let stepNumber = annotation.stepNumber else { return }
        context.setFillColor(annotation.style.color.cgColor)
        context.fillEllipse(in: rect)
        let fontSize = rect.height * 0.56
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

enum ScreenshotTextLayout {
    private static let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    private static func attributes(_ style: ScreenshotAnnotationStyle, scale: CGFloat)
        -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: CGFloat(style.lineWidth) * scale, weight: .semibold),
            .foregroundColor: style.textColor,
        ]
    }

    static func size(_ text: String, style: ScreenshotAnnotationStyle, width: CGFloat, scale: CGFloat) -> CGSize {
        let measured = (text.isEmpty ? "国" : text).boundingRect(
            with: CGSize(width: max(1, width - 8 * scale), height: .greatestFiniteMagnitude),
            options: options,
            attributes: attributes(style, scale: scale)
        )
        return CGSize(width: ceil(measured.width + 8 * scale), height: ceil(measured.height + 6 * scale))
    }

    static func draw(_ annotation: ScreenshotAnnotation, in rect: CGRect, scale: CGFloat = 1) {
        guard !annotation.text.isEmpty, rect.width > 8 * scale else { return }
        let measured = size(annotation.text, style: annotation.style, width: rect.width, scale: scale)
        if annotation.style.fillsTextBackground == true {
            annotation.style.color.nsColor.setFill()
            NSBezierPath(
                roundedRect: CGRect(origin: rect.origin, size: CGSize(
                    width: min(rect.width, measured.width), height: min(rect.height, measured.height)
                )),
                xRadius: 4 * scale, yRadius: 4 * scale
            ).fill()
        }
        annotation.text.draw(
            with: rect.insetBy(dx: 4 * scale, dy: 3 * scale),
            options: options, attributes: attributes(annotation.style, scale: scale)
        )
    }
}
