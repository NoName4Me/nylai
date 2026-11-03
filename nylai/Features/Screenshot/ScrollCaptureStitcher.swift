import CoreGraphics
import Foundation

struct ScrollCaptureLimits: Equatable, Sendable {
    var maximumFrames: Int = 100
    var maximumPixels: Int = 40_000_000
    var minimumOverlapRatio: Double = 0.18
    var maximumAdvanceRatio: Double = 0.72

    static let standard = ScrollCaptureLimits()

    var isValid: Bool {
        maximumFrames > 1 &&
            maximumPixels > 0 &&
            minimumOverlapRatio > 0 &&
            maximumAdvanceRatio > 0 &&
            minimumOverlapRatio < 1 &&
            maximumAdvanceRatio < 1 &&
            minimumOverlapRatio + maximumAdvanceRatio <= 1
    }
}

enum ScrollFrameMatch: Equatable, Sendable {
    case matched(advance: Int, overlap: Int, difference: Double)
    case duplicate(difference: Double)
    case reversed(advance: Int, overlap: Int, difference: Double)
    case insufficientOverlap
    case ambiguous(bestDifference: Double, secondDifference: Double)
    case changed(bestDifference: Double)
    case mismatchedSize
}

enum ScrollFrameAppend: Equatable, Sendable {
    case accepted(advance: Int, overlap: Int, frameCount: Int, outputHeight: Int)
    case prepended(advance: Int, overlap: Int, frameCount: Int, outputHeight: Int)
    case duplicate
    case insufficientOverlap
    case ambiguous
    case changed
    case mismatchedSize
    case frameLimitReached
    case pixelLimitReached
}

struct ScrollStitchResult: Sendable {
    let image: CGImage
    let frameCount: Int
    let elapsed: TimeInterval
    let memoryEstimate: Int
}

enum ScrollCaptureError: LocalizedError, Equatable {
    case invalidLimits
    case noFrames
    case imageCreationFailed

    var errorDescription: String? {
        switch self {
        case .invalidLimits:
            "滚动截图参数无效。"
        case .noFrames:
            "尚未采集到可用于拼接的画面。"
        case .imageCreationFailed:
            "无法生成长截图。"
        }
    }
}

actor ScrollCaptureStitcher {
    let limits: ScrollCaptureLimits
    private(set) var observedFrameCount = 0
    private(set) var acceptedFrameCount = 0
    private(set) var lastMatch: ScrollFrameMatch?
    private let startedAt = ContinuousClock.now

    private var grayscale = ScrollGrayscaleFrameMatcher(
        minimumOverlapRatio: 0.18,
        maximumAdvanceRatio: 0.72
    )
    private var previousImage: CGImage?
    private var canvas: CGContext?
    private var sourceWidth = 0
    private var usedHeight = 0
    private var nextFrameRejection: ScrollFrameAppend?

    init(limits: ScrollCaptureLimits = .standard) {
        self.limits = limits
        grayscale = ScrollGrayscaleFrameMatcher(
            minimumOverlapRatio: limits.minimumOverlapRatio,
            maximumAdvanceRatio: limits.maximumAdvanceRatio
        )
    }

    var currentFrameCount: Int { acceptedFrameCount }
    var currentPixelSize: PixelSize? {
        guard sourceWidth > 0, usedHeight > 0 else { return nil }
        return try? PixelSize(width: sourceWidth, height: usedHeight)
    }

    func currentImage() -> CGImage? {
        guard let canvas, sourceWidth > 0, usedHeight > 0 else { return nil }
        return canvas.makeImage()?.cropping(to: CGRect(
            x: 0,
            y: 0,
            width: sourceWidth,
            height: usedHeight
        ))
    }

    func append(_ image: CGImage) -> ScrollFrameAppend {
        if let rejection = nextFrameRejection {
            return rejection
        }
        guard limits.isValid else { return .changed }
        guard acceptedFrameCount < limits.maximumFrames else {
            // A stationary viewport must not end a completed capture at the limit.
            if let previousImage,
               case .duplicate = grayscale.match(previous: previousImage, current: image) {
                observedFrameCount += 1
                return .duplicate
            }
            nextFrameRejection = .frameLimitReached
            return .frameLimitReached
        }
        if image.height > 0, image.width > limits.maximumPixels / image.height {
            nextFrameRejection = .pixelLimitReached
            return .pixelLimitReached
        }
        observedFrameCount += 1

        guard let priorFrame = previousImage else {
            guard image.width * image.height <= limits.maximumPixels else {
                nextFrameRejection = .pixelLimitReached
                return .pixelLimitReached
            }
            do {
                try startCanvas(with: image)
            } catch {
                nextFrameRejection = .pixelLimitReached
                return .pixelLimitReached
            }
            acceptedFrameCount = 1
            return .accepted(
                advance: 0,
                overlap: image.height,
                frameCount: acceptedFrameCount,
                outputHeight: usedHeight
            )
        }

        let match = grayscale.match(previous: priorFrame, current: image)
        lastMatch = match
        switch match {
        case .matched(let advance, let overlap, _):
            guard advance > 0 else { return .duplicate }
            let nextHeight = usedHeight + advance
            guard nextHeight * image.width <= limits.maximumPixels else {
                nextFrameRejection = .pixelLimitReached
                return .pixelLimitReached
            }
            guard appendBottomRows(of: image, count: advance, at: usedHeight) else {
                nextFrameRejection = .pixelLimitReached
                return .pixelLimitReached
            }
            usedHeight = nextHeight
            previousImage = image
            acceptedFrameCount += 1
            return .accepted(
                advance: advance,
                overlap: overlap,
                frameCount: acceptedFrameCount,
                outputHeight: usedHeight
            )
        case .reversed(let advance, let overlap, _):
            let nextHeight = usedHeight + advance
            guard nextHeight * image.width <= limits.maximumPixels,
                  prependTopRows(of: image, count: advance) else {
                nextFrameRejection = .pixelLimitReached
                return .pixelLimitReached
            }
            usedHeight = nextHeight
            previousImage = image
            acceptedFrameCount += 1
            return .prepended(
                advance: advance,
                overlap: overlap,
                frameCount: acceptedFrameCount,
                outputHeight: usedHeight
            )
        case .duplicate:
            return .duplicate
        case .insufficientOverlap:
            return .insufficientOverlap
        case .ambiguous:
            return .ambiguous
        case .changed:
            return .changed
        case .mismatchedSize:
            return .mismatchedSize
        }
    }

    func finish() throws -> ScrollStitchResult {
        guard let canvas, usedHeight > 0 else {
            throw ScrollCaptureError.noFrames
        }
        let fullBounds = CGRect(x: 0, y: 0, width: sourceWidth, height: usedHeight)
        guard let image = canvas.makeImage()?.cropping(to: fullBounds) else {
            throw ScrollCaptureError.imageCreationFailed
        }
        let elapsedDuration = startedAt.duration(to: .now)
        let components = elapsedDuration.components
        let elapsed = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return ScrollStitchResult(
            image: image,
            frameCount: acceptedFrameCount,
            elapsed: elapsed,
            memoryEstimate: sourceWidth * usedHeight * 4
        )
    }

    private func startCanvas(with image: CGImage) throws {
        sourceWidth = image.width
        usedHeight = image.height
        let maxHeight = max(1, limits.maximumPixels / image.width)
        guard image.height <= maxHeight else {
            throw ScrollCaptureError.invalidLimits
        }
        let capacity = min(maxHeight, max(image.height * 2, image.height))
        guard let canvas = Self.makeCanvas(width: image.width, height: capacity) else {
            throw ScrollCaptureError.imageCreationFailed
        }
        self.canvas = canvas
        draw(image: image, cropY: 0, cropHeight: image.height, destinationTop: 0)
        previousImage = image
    }

    private func appendBottomRows(of image: CGImage, count: Int, at destinationTop: Int) -> Bool {
        guard count > 0, count <= image.height else { return false }
        let requiredHeight = destinationTop + count
        guard requiredHeight <= max(1, limits.maximumPixels / image.width) else { return false }
        guard ensureCanvasCapacity(requiredHeight) else { return false }
        draw(
            image: image,
            cropY: image.height - count,
            cropHeight: count,
            destinationTop: destinationTop
        )
        return true
    }

    private func prependTopRows(of image: CGImage, count: Int) -> Bool {
        guard count > 0,
              count <= image.height,
              let canvas,
              let existing = canvas.makeImage() else {
            return false
        }
        let requiredHeight = usedHeight + count
        let maximumHeight = max(1, limits.maximumPixels / sourceWidth)
        guard requiredHeight <= maximumHeight else { return false }
        let capacity = min(
            maximumHeight,
            max(requiredHeight, canvas.height + canvas.height / 2)
        )
        guard let replacement = Self.makeCanvas(width: sourceWidth, height: capacity) else {
            return false
        }
        draw(
            image: image,
            cropY: 0,
            cropHeight: count,
            destinationTop: 0,
            context: replacement
        )
        draw(
            image: existing,
            cropY: 0,
            cropHeight: usedHeight,
            destinationTop: count,
            context: replacement
        )
        self.canvas = replacement
        return true
    }

    private func ensureCanvasCapacity(_ requiredHeight: Int) -> Bool {
        guard let canvas else { return false }
        if requiredHeight <= canvas.height { return true }
        let maximumHeight = max(1, limits.maximumPixels / sourceWidth)
        let grownHeight = min(maximumHeight, max(requiredHeight, canvas.height + canvas.height / 2))
        guard let replacement = Self.makeCanvas(width: sourceWidth, height: grownHeight) else {
            return false
        }
        if let existing = canvas.makeImage() {
            draw(
                image: existing,
                cropY: 0,
                cropHeight: usedHeight,
                destinationTop: 0,
                context: replacement
            )
        }
        self.canvas = replacement
        return true
    }

    private func draw(
        image: CGImage,
        cropY: Int,
        cropHeight: Int,
        destinationTop: Int,
        context: CGContext? = nil
    ) {
        guard let context = context ?? canvas,
              let slice = image.cropping(to: CGRect(
                x: 0,
                y: cropY,
                width: image.width,
                height: min(cropHeight, image.height - cropY)
              )) else {
            return
        }
        context.draw(
            slice,
            in: CGRect(
                x: 0,
                y: context.height - destinationTop - slice.height,
                width: sourceWidth,
                height: slice.height
            )
        )
    }

    private static func makeCanvas(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }
}

struct ScrollGrayscaleFrameMatcher: Sendable {
    private static let analysisWidth = 192
    private static let maximumAnalysisHeight = 4_096
    private static let sampleColumns = 42
    private static let sampleRows = 72
    private static let absoluteDifferenceThreshold = 0.065
    private static let duplicateDifferenceThreshold = 0.008
    private static let ambiguityMargin = 0.008
    private static let confidentDifferenceThreshold = 0.0015
    private static let minimumConfidentLead = 0.0025
    private static let minimumContrast = 0.00045

    let minimumOverlapRatio: Double
    let maximumAdvanceRatio: Double

    func match(previous: CGImage, current: CGImage) -> ScrollFrameMatch {
        guard previous.width == current.width, previous.height == current.height else {
            return .mismatchedSize
        }
        guard let previousGray = Self.makeAnalysisImage(previous),
              let currentGray = Self.makeAnalysisImage(current) else {
            return .changed(bestDifference: 1)
        }
        let height = previousGray.height
        let width = previousGray.width
        let minimumOverlap = max(2, Int((Double(height) * minimumOverlapRatio).rounded()))
        let maximumAdvance = min(
            height - minimumOverlap,
            Int((Double(height) * maximumAdvanceRatio).rounded())
        )
        guard maximumAdvance >= 1 else { return .insufficientOverlap }
        guard let pixels = Self.readPixels(previousGray),
              let currentPixels = Self.readPixels(currentGray) else {
            return .changed(bestDifference: 1)
        }

        let duplicateDifference = difference(
            first: pixels,
            second: currentPixels,
            width: width,
            startRow: 0,
            rowCount: height
        )
        if duplicateDifference <= Self.duplicateDifferenceThreshold {
            if hasEnoughContrast(pixels, width: width, startRow: 0, rowCount: height) {
                return .duplicate(difference: duplicateDifference)
            }
        }

        var best: (advance: Int, difference: Double)?
        var secondDifference = Double.infinity
        for advance in 1...maximumAdvance {
            let overlap = height - advance
            guard overlap >= minimumOverlap else { continue }
            let candidate = difference(
                first: pixels,
                second: currentPixels,
                width: width,
                startRow: advance,
                rowCount: overlap
            )
            if let currentBest = best {
                if candidate < currentBest.difference {
                    secondDifference = currentBest.difference
                    best = (advance, candidate)
                } else if candidate < secondDifference {
                    secondDifference = candidate
                }
            } else {
                best = (advance, candidate)
            }
        }
        guard let best else { return .insufficientOverlap }
        let overlap = height - best.advance
        let enoughContrast = hasEnoughContrast(
            pixels,
            width: width,
            startRow: best.advance,
            rowCount: overlap
        ) && hasEnoughContrast(
            currentPixels,
            width: width,
            startRow: 0,
            rowCount: overlap
        )
        let clearWinner = Self.hasClearWinner(
            bestDifference: best.difference,
            secondDifference: secondDifference
        )
        // Heavy downscaling can flatten texture, but an exact, unique overlap is still reliable.
        guard enoughContrast || (best.difference == 0 && clearWinner) else {
            return .changed(bestDifference: best.difference)
        }
        guard best.difference <= Self.absoluteDifferenceThreshold else {
            if let reverse = bestReverseDifference(
                previous: pixels,
                current: currentPixels,
                width: width,
                height: height,
                minimumOverlap: minimumOverlap,
                maximumAdvance: maximumAdvance
            ), reverse.difference <= Self.absoluteDifferenceThreshold {
                let sourceAdvance = max(
                    1,
                    Int((Double(reverse.advance) / Double(height) * Double(previous.height)).rounded())
                )
                let sourceOverlap = previous.height - sourceAdvance
                guard sourceOverlap >= Int(Double(previous.height) * minimumOverlapRatio) else {
                    return .insufficientOverlap
                }
                return .reversed(
                    advance: sourceAdvance,
                    overlap: sourceOverlap,
                    difference: reverse.difference
                )
            }
            return .changed(bestDifference: best.difference)
        }
        guard clearWinner else {
            return .ambiguous(
                bestDifference: best.difference,
                secondDifference: secondDifference
            )
        }

        let sourceAdvance = max(
            1,
            Int((Double(best.advance) / Double(height) * Double(previous.height)).rounded())
        )
        let sourceOverlap = previous.height - sourceAdvance
        guard sourceOverlap >= Int(Double(previous.height) * minimumOverlapRatio) else {
            return .insufficientOverlap
        }
        return .matched(
            advance: sourceAdvance,
            overlap: sourceOverlap,
            difference: best.difference
        )
    }

    static func hasClearWinner(
        bestDifference: Double,
        secondDifference: Double
    ) -> Bool {
        secondDifference.isInfinite
            || secondDifference - bestDifference >= ambiguityMargin
            || (
                bestDifference <= confidentDifferenceThreshold
                    && secondDifference >= minimumConfidentLead
            )
    }

    private func bestReverseDifference(
        previous: [UInt8],
        current: [UInt8],
        width: Int,
        height: Int,
        minimumOverlap: Int,
        maximumAdvance: Int
    ) -> (advance: Int, difference: Double)? {
        var best: (advance: Int, difference: Double)?
        for advance in 1...maximumAdvance {
            let overlap = height - advance
            guard overlap >= minimumOverlap else { continue }
            let candidate = difference(
                first: previous,
                second: current,
                width: width,
                firstStartRow: 0,
                secondStartRow: advance,
                rowCount: overlap
            )
            if best == nil || candidate < best!.difference {
                best = (advance, candidate)
            }
        }
        return best
    }

    private func difference(
        first: [UInt8],
        second: [UInt8],
        width: Int,
        startRow: Int,
        rowCount: Int
    ) -> Double {
        difference(
            first: first,
            second: second,
            width: width,
            firstStartRow: startRow,
            secondStartRow: 0,
            rowCount: rowCount
        )
    }

    private func difference(
        first: [UInt8],
        second: [UInt8],
        width: Int,
        firstStartRow: Int,
        secondStartRow: Int,
        rowCount: Int
    ) -> Double {
        let rowStep = max(1, rowCount / Self.sampleRows)
        let columnStep = max(1, width / Self.sampleColumns)
        var total = 0
        var samples = 0
        var row = 0
        while row < rowCount {
            let firstRow = (firstStartRow + row) * width
            let secondRow = (secondStartRow + row) * width
            var column = 0
            while column < width {
                let firstIndex = firstRow + column
                let secondIndex = secondRow + column
                guard firstIndex < first.count, secondIndex < second.count else {
                    return 1
                }
                total += abs(Int(first[firstIndex]) - Int(second[secondIndex]))
                samples += 1
                column += columnStep
            }
            row += rowStep
        }
        guard samples > 0 else { return 1 }
        return Double(total) / Double(samples) / 255.0
    }

    private func hasEnoughContrast(
        _ pixels: [UInt8],
        width: Int,
        startRow: Int,
        rowCount: Int
    ) -> Bool {
        let rowStep = max(1, rowCount / Self.sampleRows)
        let columnStep = max(1, width / Self.sampleColumns)
        var sum = 0.0
        var squareSum = 0.0
        var samples = 0
        var row = 0
        while row < rowCount {
            let rowStart = (startRow + row) * width
            var column = 0
            while column < width {
                let value = Double(pixels[rowStart + column]) / 255.0
                sum += value
                squareSum += value * value
                samples += 1
                column += columnStep
            }
            row += rowStep
        }
        guard samples > 0 else { return false }
        let mean = sum / Double(samples)
        return squareSum / Double(samples) - mean * mean >= Self.minimumContrast
    }

    private static func makeAnalysisImage(_ image: CGImage) -> CGImage? {
        let width = min(image.width, analysisWidth)
        let aspectScale = Double(width) / Double(image.width)
        let height = image.height < analysisWidth
            ? max(2, Int((Double(image.height) * aspectScale).rounded()))
            : min(image.height, maximumAnalysisHeight)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func readPixels(_ image: CGImage) -> [UInt8]? {
        guard let data = image.dataProvider?.data,
              let pointer = CFDataGetBytePtr(data) else {
            return nil
        }
        let count = CFDataGetLength(data)
        guard count >= image.width * image.height else { return nil }
        return Array(UnsafeBufferPointer(start: pointer, count: image.width * image.height))
    }
}
