import CoreGraphics
@preconcurrency import CoreImage

enum ScreenshotPixelProcessor {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let softwareContext = CIContext(options: [
        .cacheIntermediates: false,
        .useSoftwareRenderer: true,
    ])

    static func mosaicProcessingRect(
        for annotation: ScreenshotAnnotation,
        in sourceSize: PixelSize
    ) -> PixelRect? {
        guard annotation.kind.isMosaicEffect else {
            return annotation.rect.clamped(to: sourceSize)
        }
        let rect = annotation.rect
        guard annotation.kind.redactionEffect == .blur || annotation.kind.isFreehand else {
            return rect.clamped(to: sourceSize)
        }
        let padding: Int
        if annotation.kind.redactionEffect == .blur {
            padding = blurRadius(for: annotation.style.lineWidth) + 2
        } else {
            padding = max(1, annotation.style.lineWidth / 2 + 1)
        }
        return PixelRect(
            x: rect.minX - padding,
            y: rect.minY - padding,
            width: rect.width + padding * 2,
            height: rect.height + padding * 2
        ).clamped(to: sourceSize)
    }

    static func processedImage(
        source: CGImage,
        rect: PixelRect,
        kind: ScreenshotAnnotationKind,
        intensity: Int,
        forceFallback: Bool = false
    ) -> CGImage? {
        guard kind.isMosaicEffect,
              let cropped = source.cropping(to: rect.cgRect) else {
            return nil
        }
        if forceFallback {
            return fallbackImage(
                cropped: cropped,
                effect: kind.redactionEffect,
                intensity: intensity
            )
        }
        let input = CIImage(cgImage: cropped)
        guard let effect = kind.redactionEffect else {
            return nil
        }
        let output: CIImage
        switch effect {
        case .mosaic:
            guard let filter = CIFilter(name: "CIPixellate") else { return nil }
            filter.setValue(input, forKey: kCIInputImageKey)
            filter.setValue(max(4, intensity), forKey: kCIInputScaleKey)
            guard let image = filter.outputImage else { return nil }
            output = image.cropped(to: input.extent)
        case .blur:
            guard let blurred = gaussianImage(
                input,
                radius: blurRadius(for: intensity)
            ) else {
                return nil
            }
            output = blurred
        }
        guard !output.extent.isEmpty else {
            return fallbackImage(
                cropped: cropped,
                effect: effect,
                intensity: intensity
            )
        }
        if let rendered = context.createCGImage(output, from: input.extent) {
            return rendered
        }
        return fallbackImage(
            cropped: cropped,
            effect: effect,
            intensity: intensity
        )
    }

    private static func blurRadius(for intensity: Int) -> Int {
        max(4, Int((CGFloat(max(intensity, 1)) * 0.85).rounded()))
    }

    private static func fallbackImage(
        cropped: CGImage,
        effect: ScreenshotRedactionEffect?,
        intensity: Int
    ) -> CGImage? {
        guard let effect else { return nil }
        let colorSpace = cropped.colorSpace
            ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        switch effect {
        case .mosaic:
            let scale = max(4, intensity)
            let reducedWidth = max(1, Int(ceil(Double(cropped.width) / Double(scale))))
            let reducedHeight = max(1, Int(ceil(Double(cropped.height) / Double(scale))))
            guard let reduced = resampled(
                cropped,
                width: reducedWidth,
                height: reducedHeight,
                colorSpace: colorSpace,
                interpolation: .none
            ) else {
                return nil
            }
            return resampled(
                reduced,
                width: cropped.width,
                height: cropped.height,
                colorSpace: colorSpace,
                interpolation: .none
            )
        case .blur:
            return softwareRenderedGaussian(
                cropped,
                radius: blurRadius(for: intensity)
            )
        }
    }

    private static func gaussianImage(_ image: CIImage, radius: Int) -> CIImage? {
        guard let blur = CIFilter(name: "CIGaussianBlur") else {
            return nil
        }
        blur.setValue(image.clampedToExtent(), forKey: kCIInputImageKey)
        blur.setValue(CGFloat(radius), forKey: kCIInputRadiusKey)
        return blur.outputImage?.cropped(to: image.extent)
    }

    private static func softwareRenderedGaussian(
        _ image: CGImage,
        radius: Int
    ) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let output = gaussianImage(input, radius: radius) else {
            return nil
        }
        return softwareContext.createCGImage(output, from: input.extent)
    }

    private static func resampled(
        _ image: CGImage,
        width: Int,
        height: Int,
        colorSpace: CGColorSpace,
        interpolation: CGInterpolationQuality
    ) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = interpolation
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
