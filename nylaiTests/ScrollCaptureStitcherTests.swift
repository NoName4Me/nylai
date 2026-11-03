import CoreGraphics
import AppKit
import XCTest
@preconcurrency import WebKit
@testable import nylai

@MainActor
final class ScrollCaptureStitcherTests: XCTestCase {
    func testMatcherFindsRealOverlapAndRejectsDuplicateAndReverseFrames() throws {
        let page = try makePage(width: 720, height: 1_600, seed: 91)
        let first = try crop(page, y: 300, height: 520)
        let second = try crop(page, y: 364, height: 520)
        let matcher = ScrollGrayscaleFrameMatcher(
            minimumOverlapRatio: 0.18,
            maximumAdvanceRatio: 0.72
        )

        let forwardMatch = matcher.match(
            previous: first,
            current: second
        )
        guard case .matched(let advance, let overlap, let difference) = forwardMatch else {
            return XCTFail("应识别向下滚动后的真实重叠，实际为 \(forwardMatch)")
        }
        XCTAssertEqual(advance, 64, accuracy: 2)
        XCTAssertEqual(overlap, first.height - advance)
        XCTAssertLessThan(difference, 0.02)

        guard case .duplicate = matcher.match(previous: first, current: first) else {
            return XCTFail("相同画面应判定为重复帧")
        }
        guard case .reversed = matcher.match(previous: second, current: first) else {
            return XCTFail("向上滚动应明确拒绝")
        }
    }

    func testStitcherAppendsOnlyNewRowsAndPreservesOrder() async throws {
        let page = try makePage(width: 640, height: 1_400, seed: 17)
        let frames = try [
            crop(page, y: 200, height: 480),
            crop(page, y: 260, height: 480),
            crop(page, y: 320, height: 480),
        ]
        let stitcher = ScrollCaptureStitcher()

        let firstResult = await stitcher.append(frames[0])
        let secondResult = await stitcher.append(frames[1])
        let thirdResult = await stitcher.append(frames[2])
        XCTAssertEqual(firstResult, .accepted(
            advance: 0,
            overlap: 480,
            frameCount: 1,
            outputHeight: 480
        ))
        guard case .accepted(let firstAdvance, _, let secondCount, let secondHeight) = secondResult,
              case .accepted(let secondAdvance, _, let thirdCount, let thirdHeight) = thirdResult else {
            return XCTFail("三帧都应被接纳：\(secondResult), \(thirdResult)")
        }
        XCTAssertEqual(firstAdvance, 60, accuracy: 2)
        XCTAssertEqual(secondAdvance, 60, accuracy: 2)
        XCTAssertEqual(secondCount, 2)
        XCTAssertEqual(thirdCount, 3)
        XCTAssertEqual(secondHeight, 480 + firstAdvance)
        XCTAssertEqual(thirdHeight, secondHeight + secondAdvance)
        let previewImage = await stitcher.currentImage()
        let preview = try XCTUnwrap(previewImage)
        XCTAssertEqual(preview.width, 640)
        XCTAssertEqual(preview.height, thirdHeight)

        let result = try await stitcher.finish()
        XCTAssertEqual(result.image.width, 640)
        XCTAssertEqual(result.image.height, thirdHeight)
        XCTAssertEqual(result.frameCount, 3)
        XCTAssertGreaterThan(result.memoryEstimate, 0)
        XCTAssertEqual(
            try pixel(result.image, x: 80, y: thirdHeight - 20),
            try pixel(page, x: 80, y: 320 + 480 - (thirdHeight - secondHeight) - 20 + secondAdvance)
        )
    }

    func testStitcherPrependsRowsWhenScrollingBackward() async throws {
        let page = try makePage(width: 640, height: 1_400, seed: 29)
        let first = try crop(page, y: 300, height: 480)
        let second = try crop(page, y: 240, height: 480)
        let stitcher = ScrollCaptureStitcher()

        _ = await stitcher.append(first)
        let result = await stitcher.append(second)
        guard case .prepended(let advance, _, let frameCount, let outputHeight) = result else {
            return XCTFail("向上滚动应把新内容拼接到顶部，实际为 \(result)")
        }

        XCTAssertEqual(advance, 60, accuracy: 2)
        XCTAssertEqual(frameCount, 2)
        XCTAssertEqual(outputHeight, 540, accuracy: 2)
        let image = try await stitcher.finish().image
        XCTAssertEqual(image.height, outputHeight)
        XCTAssertEqual(
            try pixel(image, x: 80, y: 10),
            try pixel(page, x: 80, y: 250)
        )
    }

    func testDuplicateDoesNotGrowFrameOrPixelCount() async throws {
        let page = try makePage(width: 480, height: 1_000, seed: 33)
        let first = try crop(page, y: 100, height: 420)
        let second = try crop(page, y: 145, height: 420)
        let stitcher = ScrollCaptureStitcher()
        let firstAppend = await stitcher.append(first)
        XCTAssertEqual(firstAppend, .accepted(
            advance: 0,
            overlap: 420,
            frameCount: 1,
            outputHeight: 420
        ))
        let secondAppend = await stitcher.append(second)
        guard case .accepted(_, _, _, let acceptedHeight) = secondAppend else {
            return XCTFail("第二帧应被接纳，实际为 \(secondAppend)")
        }
        let duplicateAppend = await stitcher.append(second)
        XCTAssertEqual(duplicateAppend, .duplicate)
        let frameCount = await stitcher.currentFrameCount
        let pixelSize = await stitcher.currentPixelSize
        XCTAssertEqual(frameCount, 2)
        XCTAssertEqual(pixelSize?.height, acceptedHeight)
    }

    func testFrameAndPixelLimitsKeepPartialImage() async throws {
        let page = try makePage(width: 500, height: 1_600, seed: 47)
        let frameHeight = 320
        let frame = try crop(page, y: 200, height: frameHeight)
        let scrolledFrame = try crop(page, y: 245, height: frameHeight)
        let frameLimitStitcher = ScrollCaptureStitcher(limits: ScrollCaptureLimits(
            maximumFrames: 2,
            maximumPixels: 10_000_000,
            minimumOverlapRatio: 0.18,
            maximumAdvanceRatio: 0.72
        ))
        let firstFrame = await frameLimitStitcher.append(frame)
        let secondFrame = await frameLimitStitcher.append(scrolledFrame)
        let stationaryFrame = await frameLimitStitcher.append(scrolledFrame)
        let limitFrame = await frameLimitStitcher.append(frame)
        XCTAssertNotEqual(firstFrame, .frameLimitReached)
        XCTAssertNotEqual(secondFrame, .frameLimitReached)
        XCTAssertEqual(stationaryFrame, .duplicate)
        XCTAssertEqual(limitFrame, .frameLimitReached)
        let frameLimitedImage = try? await frameLimitStitcher.finish()
        XCTAssertNotNil(frameLimitedImage)

        let pixelLimitStitcher = ScrollCaptureStitcher(limits: ScrollCaptureLimits(
            maximumFrames: 100,
            maximumPixels: 500 * 330,
            minimumOverlapRatio: 0.18,
            maximumAdvanceRatio: 0.72
        ))
        let firstPixelFrame = await pixelLimitStitcher.append(frame)
        let limitedPixelFrame = await pixelLimitStitcher.append(scrolledFrame)
        XCTAssertNotEqual(firstPixelFrame, .pixelLimitReached)
        XCTAssertEqual(limitedPixelFrame, .pixelLimitReached)
        let pixelLimitedImage = try? await pixelLimitStitcher.finish()
        XCTAssertNotNil(pixelLimitedImage)
    }

    func testMismatchedFrameAndFlatContentAreRejected() throws {
        let page = try makePage(width: 600, height: 1_000, seed: 62)
        let first = try crop(page, y: 100, height: 360)
        let differentWidth = try crop(page, y: 140, width: 580, height: 360)
        let matcher = ScrollGrayscaleFrameMatcher(
            minimumOverlapRatio: 0.18,
            maximumAdvanceRatio: 0.72
        )
        XCTAssertEqual(matcher.match(previous: first, current: differentWidth), .mismatchedSize)

        let flat = try makeSolid(width: 600, height: 360, value: 180)
        guard case .changed = matcher.match(previous: flat, current: flat) else {
            return XCTFail("无纹理画面不能凭相似度判定为可靠重叠")
        }
    }

    func testExactOverlapWinsOverAWeakerSecondaryCandidate() throws {
        let page = try makePage(width: 720, height: 1_600, seed: 128)
        let first = try crop(page, y: 240, height: 520)
        let second = try crop(page, y: 300, height: 520)
        let matcher = ScrollGrayscaleFrameMatcher(
            minimumOverlapRatio: 0.18,
            maximumAdvanceRatio: 0.72
        )

        guard case .matched(let advance, _, let difference) = matcher.match(
            previous: first,
            current: second
        ) else {
            return XCTFail("精确重叠应优先于较弱的次候选")
        }
        XCTAssertEqual(advance, 60, accuracy: 2)
        XCTAssertLessThan(difference, ScrollCaptureStitcherTests.exactDifferenceLimit)
    }

    func testAmbiguityRequiresSecondaryCandidateToRemainClose() {
        XCTAssertTrue(ScrollGrayscaleFrameMatcher.hasClearWinner(
            bestDifference: 0.00007,
            secondDifference: 0.0033
        ))
        XCTAssertFalse(ScrollGrayscaleFrameMatcher.hasClearWinner(
            bestDifference: 0.00007,
            secondDifference: 0.0002
        ))
        XCTAssertTrue(ScrollGrayscaleFrameMatcher.hasClearWinner(
            bestDifference: 0.01,
            secondDifference: 0.02
        ))
    }

    func testPeriodicContentRemainsAmbiguousDespiteExactMatches() throws {
        let page = try makePeriodicPage(width: 480, height: 900, period: 20)
        let first = try crop(page, y: 100, height: 360)
        let second = try crop(page, y: 107, height: 360)
        let matcher = ScrollGrayscaleFrameMatcher(
            minimumOverlapRatio: 0.18,
            maximumAdvanceRatio: 0.72
        )

        let result = matcher.match(previous: first, current: second)
        guard case .ambiguous = result else {
            return XCTFail("周期性内容存在多个等价位移时必须拒绝，实际为 \(result)")
        }
    }

    func testWebKitRenderedScrollFramesStitchWithoutGapsOrDuplicates() async throws {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1_200, height: 800))
        try await webView.loadHTMLString(Self.scrollValidationHTML, baseURL: nil)
        try await waitForWebKitLoad(webView)

        let offsets = [0, 300, 600, 900, 1_200, 1_500, 1_800, 2_100]
        var stitcher = ScrollCaptureStitcher()
        var frameSize: PixelSize?
        var advances: [Int] = []

        for offset in offsets {
            _ = try await webView.evaluateJavaScript(
                "window.scrollTo(0, \(offset)); window.scrollY"
            )
            try await Task.sleep(for: .milliseconds(80))
            let snapshot = try await snapshot(of: webView)
            let append = await stitcher.append(snapshot)
            if frameSize == nil, let size = await stitcher.currentPixelSize {
                frameSize = size
            }
            if case .accepted(let advance, _, _, _) = append {
                if offset > 0 {
                    advances.append(advance)
                }
            } else {
                XCTFail("WebKit 第 \(offset) 点画面未被接纳：\(append)")
            }
        }

        let expectedAdvance = try XCTUnwrap(frameSize.map {
            Int((300 * Double($0.width) / 1_200).rounded())
        })
        XCTAssertEqual(advances.count, offsets.count - 1)
        XCTAssertTrue(advances.allSatisfy { abs($0 - expectedAdvance) <= 1 })
        let result = try await stitcher.finish()
        XCTAssertEqual(
            result.image.height,
            try XCTUnwrap(frameSize).height + expectedAdvance * (offsets.count - 1)
        )
    }

    private static let exactDifferenceLimit = 0.0015

    private static let scrollValidationHTML = """
        <!doctype html>
        <meta charset="utf-8">
        <style>
          html, body { margin: 0; background: #f7f2e8; color: #17211b; }
          main { width: 920px; margin: 0 auto; padding: 32px 0; }
          section {
            height: 540px; padding: 32px; margin-bottom: 28px;
            border: 1px solid #cabf9f; border-radius: 16px;
            background: #fffdf7; font: 16px/1.6 Georgia, serif;
          }
          h2 { margin: 0 0 18px; color: #a13c24; font-size: 30px; }
          .hero { height: 132px; margin: 0 0 22px; border-radius: 10px; }
          .bars { height: 80px; margin: 0 0 22px; border-radius: 10px; }
          .rows { white-space: pre-wrap; font: 14px/1.8 ui-monospace, monospace; }
        </style>
        <main></main>
        <script>
          const main = document.querySelector('main');
          for (let i = 1; i <= 20; i++) {
            const section = document.createElement('section');
            const hue = (i * 47) % 360;
            const rows = Array.from(
              { length: 9 },
              (_, j) => `ROW ${i}.${j + 1}  ${(i * 1409 + j * 97).toString(36)}  stable unique content`
            ).join('\\n');
            section.innerHTML = `
              <div class="hero" style="background:linear-gradient(135deg,hsl(${hue} 55% 72%),hsl(${(hue + 140) % 360} 48% 38%))"></div>
              <h2>Stable WebKit section ${i}</h2>
              <div class="bars" style="background:repeating-linear-gradient(90deg,hsl(${hue} 60% 30%) 0 50px,hsl(${(hue + 90) % 360} 55% 55%) 50px 86px,#eee8d7 86px 130px)"></div>
              <div class="rows">${rows}</div>`;
            main.appendChild(section);
          }
        </script>
        """

    private func waitForWebKitLoad(_ webView: WKWebView) async throws {
        for _ in 0..<100 {
            let ready = try await webView.evaluateJavaScript("document.readyState") as? String
            if ready == "complete" {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("WebKit 页面加载超时")
    }

    private func snapshot(of webView: WKWebView) async throws -> CGImage {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        let image = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<NSImage, Error>) in
            webView.takeSnapshot(with: configuration) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: TestImageError.creationFailed)
                }
            }
        }
        guard let cgImage = image.cgImage(
            forProposedRect: nil,
            context: nil,
            hints: nil
        ) else {
            throw TestImageError.creationFailed
        }
        return cgImage
    }

    private func makePage(width: Int, height: Int, seed: UInt64) throws -> CGImage {
        var generator = SeededGenerator(seed: seed)
        var rowValues = [UInt8]()
        rowValues.reserveCapacity(height)
        for _ in 0..<height {
            rowValues.append(UInt8(48 + (generator.next() >> 32) % 161))
        }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0..<height {
            let rowValue = Int(rowValues[row])
            for column in 0..<width {
                let index = (row * width + column) * 4
                let band = (column / 24) % 7
                let variation = band * 5 - 15
                let value = UInt8(clamping: rowValue + variation)
                bytes[index] = value
                bytes[index + 1] = UInt8(clamping: rowValue + (column % 11) - 5)
                bytes[index + 2] = UInt8(clamping: rowValue - variation)
                bytes[index + 3] = 255
            }
        }
        return try makeImage(width: width, height: height, bytes: bytes)
    }

    private func makeSolid(width: Int, height: Int, value: UInt8) throws -> CGImage {
        var bytes = [UInt8](repeating: value, count: width * height * 4)
        for index in stride(from: 3, to: bytes.count, by: 4) {
            bytes[index] = 255
        }
        return try makeImage(width: width, height: height, bytes: bytes)
    }

    private func makePeriodicPage(width: Int, height: Int, period: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0..<height {
            let rowValue = UInt8(clamping: 70 + (row % period) * 7)
            for column in 0..<width {
                let index = (row * width + column) * 4
                let columnPattern = UInt8(clamping: 40 + (column % 37) * 4)
                bytes[index] = rowValue
                bytes[index + 1] = columnPattern
                bytes[index + 2] = rowValue / 2 + columnPattern / 2
                bytes[index + 3] = 255
            }
        }
        return try makeImage(width: width, height: height, bytes: bytes)
    }

    private func makeImage(width: Int, height: Int, bytes: [UInt8]) throws -> CGImage {
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                ).union(.byteOrder32Big),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw TestImageError.creationFailed
        }
        return image
    }

    private func crop(
        _ image: CGImage,
        y: Int,
        width: Int? = nil,
        height: Int
    ) throws -> CGImage {
        guard let cropped = image.cropping(to: CGRect(
            x: 0,
            y: y,
            width: width ?? image.width,
            height: height
        )) else {
            throw TestImageError.creationFailed
        }
        return cropped
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        guard let data = image.dataProvider?.data,
              let pointer = CFDataGetBytePtr(data) else {
            throw TestImageError.creationFailed
        }
        let bytesPerRow = image.bytesPerRow
        let index = y * bytesPerRow + x * 4
        return [
            pointer[index],
            pointer[index + 1],
            pointer[index + 2],
            pointer[index + 3],
        ]
    }
}

final class ScrollPreviewLayoutSolverTests: XCTestCase {
    func testPrefersRightSideWhenItHasSpace() {
        let screen = CGRect(x: 0, y: 0, width: 1_400, height: 900)
        let selection = CGRect(x: 420, y: 300, width: 400, height: 320)

        let layout = ScrollPreviewLayoutSolver.layout(
            selection: selection,
            screenFrame: screen
        )

        XCTAssertEqual(layout.position, .right)
        XCTAssertFalse(layout.frame.intersects(selection))
        XCTAssertTrue(screen.contains(layout.frame))
    }

    func testFloatsInsideSelectionWhenNoOutsideSideFits() {
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let selection = screen.insetBy(dx: 20, dy: 20)

        let layout = ScrollPreviewLayoutSolver.layout(
            selection: selection,
            screenFrame: screen
        )

        XCTAssertEqual(layout.position, .inside)
        XCTAssertTrue(selection.contains(layout.frame))
        XCTAssertGreaterThan(layout.frame.width, 100)
        XCTAssertGreaterThan(layout.frame.height, 150)
    }

    func testUsesSidePositionWhenSelectionCoversOnlyPartOfScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let selection = CGRect(x: 20, y: 240, width: 900, height: 420)

        let layout = ScrollPreviewLayoutSolver.layout(
            selection: selection,
            screenFrame: screen
        )

        XCTAssertEqual(layout.position, .right)
        XCTAssertFalse(layout.frame.intersects(selection))
    }

    func testCompressesPreviewBeforeFloatingOverSelection() {
        let screen = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let selection = CGRect(x: 20, y: 180, width: 1_020, height: 420)

        let layout = ScrollPreviewLayoutSolver.layout(
            selection: selection,
            screenFrame: screen
        )

        XCTAssertEqual(layout.position, .right)
        XCTAssertFalse(layout.frame.intersects(selection))
        XCTAssertGreaterThanOrEqual(
            layout.frame.width,
            ScrollPreviewLayoutSolver.minimumSize.width
        )
    }
}

@MainActor
final class ScrollCaptureControllerTests: XCTestCase {
    func testBeginWithSelectionStartsFromExistingRegionAndPublishesPreview() async throws {
        let target = ScrollCaptureDisplayTarget(displayID: 8, frame: CGRect(
            x: 0,
            y: 0,
            width: 640,
            height: 480
        ))
        let capturer = SequenceScrollCapturer(images: [
            try makePageSlice(width: 1280, height: 960, yOffset: 0),
            try makePageSlice(width: 1280, height: 960, yOffset: 80),
        ])
        let controller = ScrollCaptureController(
            displayCapturer: capturer,
            displayTarget: { _ in target },
            openEditor: { _, _, _ in },
            presentError: { _ in }
        )
        let request = ScrollCaptureStartRequest(
            displayID: target.displayID,
            displayFrame: target.frame,
            selectionGlobalRect: target.frame,
            pointPixelScale: 2,
            targetApplication: nil
        )

        controller.begin(with: request, automaticCapture: false)
        XCTAssertEqual(controller.phase, .running)
        XCTAssertEqual(
            controller.selection,
            ScrollCaptureSelection(
                pixelRect: PixelRect(x: 0, y: 0, width: 1280, height: 960),
                pointPixelScale: 2
            )
        )

        controller.startOrResume(automaticCapture: false)
        let first = await controller.captureFrameNow()
        guard case .accepted = first else {
            return XCTFail("首帧应被接纳，实际为 \(String(describing: first))")
        }
        XCTAssertEqual(controller.previewImage?.width, 1280)
        XCTAssertEqual(controller.previewImage?.height, 960)
        XCTAssertEqual(controller.frameCount, 1)
        controller.cancel()
    }

    func testTransientUnmatchedFrameDoesNotInterruptFollowingScroll() async throws {
        let target = ScrollCaptureDisplayTarget(
            displayID: 81,
            frame: CGRect(x: 0, y: 0, width: 640, height: 480)
        )
        let capturer = SequenceScrollCapturer(images: [
            try makePageSlice(width: 1280, height: 960, yOffset: 0),
            try makeImage(width: 1280, height: 960, top: 0),
            try makePageSlice(width: 1280, height: 960, yOffset: 80),
        ])
        let controller = ScrollCaptureController(
            displayCapturer: capturer,
            displayTarget: { _ in target },
            openEditor: { _, _, _ in },
            presentError: { _ in }
        )
        controller.begin(with: ScrollCaptureStartRequest(
            displayID: target.displayID,
            displayFrame: target.frame,
            selectionGlobalRect: target.frame,
            pointPixelScale: 2,
            targetApplication: nil
        ), automaticCapture: false)
        _ = await controller.captureFrameNow()
        _ = await controller.captureFrameNow()
        XCTAssertEqual(controller.phase, .running)
        let recovered = await controller.captureFrameNow()
        guard case .accepted = recovered else {
            return XCTFail("短暂不稳定后应继续拼接，实际为 \(String(describing: recovered))")
        }
        XCTAssertEqual(controller.frameCount, 2)
        controller.cancel()
    }

    func testUnstableFramesDoNotPauseCapture() async throws {
        let target = ScrollCaptureDisplayTarget(
            displayID: 82,
            frame: CGRect(x: 0, y: 0, width: 120, height: 120)
        )
        let images = [
            try makePageSlice(width: 120, height: 120, yOffset: 0),
        ] + (try (0..<8).map { _ in try makeImage(width: 120, height: 120, top: 0) }) + [
            try makePageSlice(width: 120, height: 120, yOffset: 20),
        ]
        let capturer = SequenceScrollCapturer(images: images)
        let controller = ScrollCaptureController(
            displayCapturer: capturer,
            displayTarget: { _ in target },
            openEditor: { _, _, _ in },
            presentError: { _ in }
        )
        controller.begin(with: ScrollCaptureStartRequest(
            displayID: target.displayID,
            displayFrame: target.frame,
            selectionGlobalRect: target.frame,
            pointPixelScale: 1,
            targetApplication: nil
        ), automaticCapture: false)
        _ = await controller.captureFrameNow()
        for _ in 0..<8 {
            _ = await controller.captureFrameNow()
        }
        XCTAssertEqual(controller.phase, .running)

        _ = await controller.captureFrameNow()

        XCTAssertEqual(controller.frameCount, 2)
        XCTAssertEqual(capturer.calls, 10)
        controller.cancel()
    }

    func testPreviewUsesContainLayoutForGrowingLongImage() {
        let container = CGRect(x: 20, y: 30, width: 200, height: 300)
        let fitted = ScrollPreviewImageFit.rect(
            imageSize: CGSize(width: 100, height: 1_000),
            in: container
        )

        XCTAssertEqual(fitted.width, 30, accuracy: 0.001)
        XCTAssertEqual(fitted.height, 300, accuracy: 0.001)
        XCTAssertEqual(fitted.midX, container.midX, accuracy: 0.001)
        XCTAssertEqual(fitted.midY, container.midY, accuracy: 0.001)
    }

    func testWideShortSelectionMatchesOrdinaryScrollStep() async throws {
        let first = try makePageSlice(width: 2_400, height: 180, yOffset: 0)
        let second = try makePageSlice(width: 2_400, height: 180, yOffset: 90)
        var stitcher = ScrollCaptureStitcher()

        let firstAppend = await stitcher.append(first)
        guard case .accepted = firstAppend else {
            return XCTFail("宽而矮选区的首帧应被接纳")
        }
        let secondAppend = await stitcher.append(second)
        guard case .accepted(let advance, _, _, _) = secondAppend else {
            return XCTFail("宽而矮的选区应能拼接正常滚动步长")
        }
        XCTAssertEqual(advance, 90, accuracy: 2)
    }

    private func waitForScrollCondition(
        timeout: Duration = .seconds(3),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("等待滚动采集状态超时。")
    }

    func testSelectingRegionClosesPickerAfterMouseEventReturns() async throws {
        let target = ScrollCaptureDisplayTarget(displayID: 4, frame: CGRect(
            x: 0,
            y: 0,
            width: 640,
            height: 480
        ))
        let selector = FakeScrollRegionSelector()
        let controller = ScrollCaptureController(
            displayCapturer: SequenceScrollCapturer(images: [
                try makeImage(width: 640, height: 480, top: 0),
            ]),
            displayTarget: { _ in target },
            regionSelector: selector,
            openEditor: { _, _, _ in },
            presentError: { _ in }
        )

        await controller.begin()
        selector.select(CGRect(x: 40, y: 40, width: 320, height: 200))
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(selector.session.closeCount, 0, "选区窗口必须在鼠标事件返回后关闭")
        await Task.yield()
        XCTAssertEqual(selector.session.closeCount, 1)
    }

    func testSelectionStartAndStopUseSelectedRegionAndOpenOneEditor() async throws {
        let target = ScrollCaptureDisplayTarget(displayID: 1, frame: CGRect(
            x: 0,
            y: 0,
            width: 640,
            height: 480
        ))
        let selector = FakeScrollRegionSelector()
        let capturer = SequenceScrollCapturer(images: [
            try makePageSlice(width: 1280, height: 960, yOffset: 0),
            try makePageSlice(width: 1280, height: 960, yOffset: 100),
            try makePageSlice(width: 1280, height: 960, yOffset: 200),
        ])
        var openedImages: [CGImage] = []
        var openedScales: [CGFloat] = []
        let controller = ScrollCaptureController(
            displayCapturer: capturer,
            displayTarget: { _ in target },
            regionSelector: selector,
            openEditor: { image, scale, _ in
                openedImages.append(image)
                openedScales.append(scale)
            },
            presentError: { _ in }
        )

        await controller.begin()
        XCTAssertEqual(controller.phase, .selecting)
        XCTAssertEqual(selector.presentCount, 1)
        selector.select(CGRect(x: 80, y: 60, width: 480, height: 320))
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(
            controller.selection,
            ScrollCaptureSelection(
                pixelRect: PixelRect(x: 160, y: 200, width: 960, height: 640),
                pointPixelScale: 2
            )
        )

        controller.startOrResume(automaticCapture: false)
        let firstAppend = await controller.captureFrameNow()
        let secondAppend = await controller.captureFrameNow()
        guard case .accepted = firstAppend, case .accepted = secondAppend else {
            return XCTFail("测试帧应被接纳：\(String(describing: firstAppend)), \(String(describing: secondAppend))")
        }
        XCTAssertEqual(controller.frameCount, 2)
        await controller.stopAndOpenEditor()

        XCTAssertEqual(openedImages.count, 1)
        XCTAssertEqual(openedScales, [2])
        XCTAssertEqual(openedImages.first?.width, 960)
        XCTAssertGreaterThan(try XCTUnwrap(openedImages.first).height, 640)
        XCTAssertEqual(controller.phase, .idle)
    }

    @MainActor
    func testRunningCaptureShowsOnlyCompactCompletionControl() async throws {
        let target = ScrollCaptureDisplayTarget(
            displayID: 12,
            frame: CGRect(x: 0, y: 0, width: 640, height: 480)
        )
        let controller = ScrollCaptureController(
            displayCapturer: SequenceScrollCapturer(images: [
                try makePageSlice(width: 640, height: 480, yOffset: 0),
            ]),
            displayTarget: { _ in target },
            openEditor: { _, _, _ in },
            presentError: { _ in }
        )

        controller.begin(with: ScrollCaptureStartRequest(
            displayID: target.displayID,
            displayFrame: target.frame,
            selectionGlobalRect: CGRect(x: 40, y: 80, width: 400, height: 280),
            pointPixelScale: 1,
            targetApplication: nil
        ), automaticCapture: false)
        defer { controller.cancel() }

        let completion = try XCTUnwrap(NSApp.windows.first {
            $0.identifier?.rawValue == "nylai.scroll-capture-completion"
        })
        let button = try XCTUnwrap(completion.contentView as? NSButton)
        XCTAssertEqual(button.title, "完成")
        XCTAssertFalse(button.isEnabled)

        controller.startOrResume(automaticCapture: false)
        Task { _ = await controller.captureFrameNow() }
        try await waitForScrollCondition { button.isEnabled }
        XCTAssertTrue(button.isEnabled)
    }

    func testCancelAndCloseAreIdempotentAndPreventLateSelection() async throws {
        let target = ScrollCaptureDisplayTarget(displayID: 2, frame: CGRect(
            x: 0,
            y: 0,
            width: 800,
            height: 600
        ))
        let selector = FakeScrollRegionSelector()
        let controller = ScrollCaptureController(
            displayCapturer: SequenceScrollCapturer(images: [
                try makeImage(width: 800, height: 600, top: 0),
            ]),
            displayTarget: { _ in target },
            regionSelector: selector,
            openEditor: { _, _, _ in },
            presentError: { _ in }
        )

        await controller.begin()
        controller.cancel()
        controller.cancel()
        selector.select(CGRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(controller.selection)
        XCTAssertEqual(selector.session.closeCount, 0)
        await Task.yield()
        XCTAssertEqual(selector.session.closeCount, 1)
    }

    func testStopWithoutAcceptedFramesStaysPausedAndAllowsRecovery() async throws {
        let target = ScrollCaptureDisplayTarget(displayID: 3, frame: CGRect(
            x: 0,
            y: 0,
            width: 400,
            height: 300
        ))
        let selector = FakeScrollRegionSelector()
        let capturer = FlakyScrollCapturer(
            firstImage: try makeImage(width: 400, height: 300, top: 0)
        )
        var errors: [Error] = []
        let controller = ScrollCaptureController(
            displayCapturer: capturer,
            displayTarget: { _ in target },
            regionSelector: selector,
            openEditor: { _, _, _ in },
            presentError: { errors.append($0) }
        )
        await controller.begin()
        selector.select(CGRect(x: 0, y: 0, width: 300, height: 200))
        controller.startOrResume(automaticCapture: false)
        await controller.captureFrameNow()
        XCTAssertEqual(controller.phase, .paused)
        await controller.stopAndOpenEditor()
        XCTAssertEqual(controller.phase, .paused)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first as? ScrollCaptureError, .noFrames)
    }

    func testStopAfterAcceptedFrameOutputsPartialResultDespiteUnmatchedFrames() async throws {
        let target = ScrollCaptureDisplayTarget(displayID: 31, frame: CGRect(
            x: 0,
            y: 0,
            width: 400,
            height: 300
        ))
        let selector = FakeScrollRegionSelector()
        let capturer = SequenceScrollCapturer(images: [
            try makePageSlice(width: 400, height: 300, yOffset: 0),
            try makePageSlice(width: 400, height: 300, yOffset: 0),
            try makePageSlice(width: 400, height: 300, yOffset: 0),
        ])
        var openedImages: [CGImage] = []
        var errors: [Error] = []
        let controller = ScrollCaptureController(
            displayCapturer: capturer,
            displayTarget: { _ in target },
            regionSelector: selector,
            openEditor: { image, _, _ in openedImages.append(image) },
            presentError: { errors.append($0) }
        )

        await controller.begin()
        selector.select(CGRect(x: 0, y: 0, width: 300, height: 200))
        controller.startOrResume(automaticCapture: false)
        let firstAppend = await controller.captureFrameNow()
        guard case .accepted = firstAppend else {
            return XCTFail("首帧应被接纳，实际为 \(String(describing: firstAppend))")
        }
        XCTAssertEqual(controller.phase, .running)

        let duplicateAppend = await controller.captureFrameNow()
        guard case .duplicate = duplicateAppend else {
            return XCTFail("重复帧应被拒绝，实际为 \(String(describing: duplicateAppend))")
        }
        XCTAssertEqual(controller.phase, .running)
        XCTAssertEqual(controller.frameCount, 1)

        await controller.stopAndOpenEditor()

        XCTAssertEqual(openedImages.count, 1)
        XCTAssertEqual(openedImages.first?.width, 300)
        XCTAssertEqual(openedImages.first?.height, 200)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(errors.isEmpty)
    }

    func testSecondBeginDoesNotReplaceActiveSelection() async throws {
        let target = ScrollCaptureDisplayTarget(displayID: 4, frame: CGRect(
            x: 0,
            y: 0,
            width: 500,
            height: 400
        ))
        let selector = FakeScrollRegionSelector()
        let controller = ScrollCaptureController(
            displayCapturer: SequenceScrollCapturer(images: [
                try makeImage(width: 500, height: 400, top: 0),
            ]),
            displayTarget: { _ in target },
            regionSelector: selector,
            openEditor: { _, _, _ in },
            presentError: { _ in }
        )

        await controller.begin()
        await controller.begin()

        XCTAssertEqual(selector.presentCount, 1)
        XCTAssertEqual(controller.phase, .selecting)
    }

    func testClosingSelectionWindowCancelsThePendingSession() async throws {
        let target = ScrollCaptureDisplayTarget(displayID: 5, frame: CGRect(
            x: 0,
            y: 0,
            width: 400,
            height: 300
        ))
        let selector = FakeScrollRegionSelector()
        let controller = ScrollCaptureController(
            displayCapturer: SequenceScrollCapturer(images: [
                try makeImage(width: 400, height: 300, top: 0),
            ]),
            displayTarget: { _ in target },
            regionSelector: selector,
            openEditor: { _, _, _ in },
            presentError: { _ in }
        )
        await controller.begin()
        XCTAssertEqual(controller.phase, .selecting)

        selector.session.isVisible = false
        for _ in 0..<20 where controller.phase == .selecting {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(controller.phase, .idle)
    }

    func testStopFailureKeepsTargetForRetryAndSuccessfulStopReleasesIt() async throws {
        let target = ScrollCaptureDisplayTarget(displayID: 6, frame: CGRect(
            x: 0,
            y: 0,
            width: 400,
            height: 300
        ))
        let selector = FakeScrollRegionSelector()
        let controller = ScrollCaptureController(
            displayCapturer: FlakyScrollCapturer(
                firstImage: try makeImage(width: 400, height: 300, top: 0)
            ),
            displayTarget: { _ in target },
            regionSelector: selector,
            openEditor: { _, _, _ in },
            presentError: { _ in }
        )
        await controller.begin()
        selector.select(CGRect(x: 0, y: 0, width: 300, height: 200))
        controller.startOrResume(automaticCapture: false)
        await controller.captureFrameNow()
        await controller.stopAndOpenEditor()
        XCTAssertEqual(controller.phase, .paused)

        controller.cancel()
        XCTAssertEqual(controller.phase, .idle)
    }

    private func makePageSlice(width: Int, height: Int, yOffset: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let pageY = y + yOffset
            for x in 0..<width {
                let index = (y * width + x) * 4
                var hash = UInt64(pageY) &* 0x9E37_79B9_7F4A_7C15
                hash ^= UInt64(x) &* 0xBF58_476D_1CE4_E5B9
                hash ^= hash >> 30
                hash &*= 0xBF58_476D_1CE4_E5B9
                hash ^= hash >> 27
                bytes[index] = UInt8(hash & 0xFF)
                bytes[index + 1] = UInt8((hash >> 8) & 0xFF)
                bytes[index + 2] = UInt8((hash >> 16) & 0xFF)
                bytes[index + 3] = 255
            }
        }
        return try makeImage(width: width, height: height, bytes: bytes)
    }

    private func makeImage(width: Int, height: Int, top: UInt8) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let value = UInt8(clamping: Int(top) + y / 8 + x / 16)
                bytes[index] = value
                bytes[index + 1] = UInt8(clamping: Int(top) + 40 + y / 12)
                bytes[index + 2] = UInt8(clamping: Int(top) + 80 + x / 20)
                bytes[index + 3] = 255
            }
        }
        return try makeImage(width: width, height: height, bytes: bytes)
    }

    private func makeImage(width: Int, height: Int, bytes: [UInt8]) throws -> CGImage {
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                ).union(.byteOrder32Big),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw TestImageError.creationFailed
        }
        return image
    }
}

@MainActor
private final class FakeScrollRegionSelector: ScrollRegionSelecting {
    private(set) var presentCount = 0
    private var onSelection: ((CGRect) -> Void)?
    private var onCancel: (() -> Void)?
    let session = FakeScrollSelectionSession()

    func present(
        screenFrame: CGRect,
        image: CGImage,
        onSelection: @escaping (CGRect) -> Void,
        onCancel: @escaping () -> Void
    ) throws -> any ScrollRegionSelectionSession {
        presentCount += 1
        self.onSelection = onSelection
        self.onCancel = onCancel
        return session
    }

    func select(_ rect: CGRect) {
        onSelection?(rect)
    }
}

@MainActor
private final class FakeScrollSelectionSession: ScrollRegionSelectionSession {
    var isVisible = false
    private(set) var closeCount = 0

    func show() {
        isVisible = true
    }

    func close() {
        isVisible = false
        closeCount += 1
    }
}

@MainActor
private final class SequenceScrollCapturer: ScreenCapturing {
    private var images: [CGImage]
    private(set) var calls = 0

    init(images: [CGImage]) {
        self.images = images
    }

    func captureDisplay(_ displayID: CGDirectDisplayID) async throws -> CGImage {
        calls += 1
        guard !images.isEmpty else {
            throw ScreenshotError.displayUnavailable
        }
        return images.removeFirst()
    }
}

@MainActor
private final class FlakyScrollCapturer: ScreenCapturing {
    private let firstImage: CGImage
    private(set) var calls = 0

    init(firstImage: CGImage) {
        self.firstImage = firstImage
    }

    func captureDisplay(_ displayID: CGDirectDisplayID) async throws -> CGImage {
        calls += 1
        guard calls == 1 else {
            throw ScreenshotError.displayUnavailable
        }
        return firstImage
    }
}

private enum TestImageError: Error {
    case creationFailed
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x1234_5678_9ABC_DEF0 : seed
    }

    mutating func next() -> UInt64 {
        state &*= 6_364_136_223_846_793_005
        state &+= 1_442_695_040_888_963_407
        return state
    }
}
