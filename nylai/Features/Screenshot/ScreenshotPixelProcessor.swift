import CoreGraphics
@preconcurrency import CoreImage

enum ScreenshotPixelProcessor {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func processedImage(
        source: CGImage,
        rect: PixelRect,
        kind: ScreenshotAnnotationKind,
        intensity: Int
    ) -> CGImage? {
        guard kind == .mosaic,
              let cropped = source.cropping(to: rect.cgRect) else {
            return nil
        }
        let input = CIImage(cgImage: cropped)
        let filter: CIFilter?
        switch kind {
        case .mosaic:
            filter = CIFilter(name: "CIPixellate")
            filter?.setValue(max(4, intensity), forKey: kCIInputScaleKey)
        case .rectangle, .ellipse, .line, .arrow, .brush, .text, .step:
            return nil
        }
        filter?.setValue(input, forKey: kCIInputImageKey)
        guard let output = filter?.outputImage?.cropped(to: input.extent) else {
            return nil
        }
        return context.createCGImage(output, from: input.extent)
    }
}
