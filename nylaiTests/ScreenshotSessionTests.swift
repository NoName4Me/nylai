import AppKit
import XCTest
@testable import nylai

final class ScreenshotSessionTests: XCTestCase {
    @MainActor
    func testAppearanceDragCanBeUndoneAndRedone() throws {
        let session = ScreenshotSession()
        session.begin(with: try makeSource(kind: .display(1), width: 120, height: 80))
        try session.select(pixelRect: PixelRect(x: 10, y: 10, width: 80, height: 60))
        let original = session.outputAppearance
        try session.beginInteraction(.resizingSelection)
        session.setOutputAppearance(ScreenshotOutputAppearance(
            roundedCornersEnabled: true,
            cornerRadius: 24
        ))
        session.endInteraction()

        session.undo()
        XCTAssertEqual(session.outputAppearance, original)
        session.redo()
        XCTAssertEqual(session.outputAppearance.cornerRadius, 24)
    }

    func testOneAndTwoPixelScaleMappingRoundTrips() throws {
        let size = try PixelSize(width: 200, height: 200)
        let oneX = try ScreenshotSourceGeometry(
            kind: .display(1),
            globalFrame: CGRect(x: 0, y: 0, width: 200, height: 200),
            pointPixelScale: 1,
            pixelSize: size
        )
        let twoX = try ScreenshotSourceGeometry(
            kind: .display(1),
            globalFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            pointPixelScale: 2,
            pixelSize: size
        )

        XCTAssertEqual(
            try oneX.mapper.pixelRect(fromGlobalScreenRect: CGRect(x: 10, y: 20, width: 30, height: 40)),
            PixelRect(x: 10, y: 140, width: 30, height: 40)
        )
        XCTAssertEqual(
            try twoX.mapper.pixelRect(fromGlobalScreenRect: CGRect(x: 10, y: 20, width: 30, height: 40)),
            PixelRect(x: 20, y: 80, width: 60, height: 80)
        )
        XCTAssertEqual(
            twoX.mapper.globalScreenRect(fromPixelRect: PixelRect(x: 20, y: 80, width: 60, height: 80)),
            CGRect(x: 10, y: 20, width: 30, height: 40)
        )
    }

    func testNegativeAndVerticallyStackedScreenCoordinates() throws {
        let size = try PixelSize(width: 2400, height: 1600)
        let geometry = try ScreenshotSourceGeometry(
            kind: .display(2),
            globalFrame: CGRect(x: -1200, y: -400, width: 1200, height: 800),
            pointPixelScale: 2,
            pixelSize: size
        )
        let selection = try geometry.mapper.pixelRect(
            fromGlobalScreenRect: CGRect(x: -1100, y: -300, width: 100, height: 50)
        )
        XCTAssertEqual(selection, PixelRect(x: 200, y: 1300, width: 200, height: 100))
        XCTAssertEqual(
            geometry.mapper.globalScreenRect(fromPixelRect: selection),
            CGRect(x: -1100, y: -300, width: 100, height: 50)
        )

        let upper = try ScreenshotSourceGeometry(
            kind: .display(3),
            globalFrame: CGRect(x: -1200, y: 400, width: 1200, height: 800),
            pointPixelScale: 2,
            pixelSize: size
        )
        XCTAssertEqual(
            try upper.mapper.pixelRect(
                fromGlobalScreenRect: CGRect(x: -1200, y: 1000, width: 10, height: 10)
            ),
            PixelRect(x: 0, y: 380, width: 20, height: 20)
        )
    }

    func testSelectionClampsAndRejectsZeroArea() throws {
        let geometry = try ScreenshotSourceGeometry(
            kind: .window(42),
            globalFrame: CGRect(x: 100, y: 100, width: 100, height: 100),
            pointPixelScale: 1,
            pixelSize: try PixelSize(width: 100, height: 100)
        )
        XCTAssertThrowsError(
            try geometry.mapper.pixelRect(
                fromGlobalScreenRect: CGRect(x: 150, y: 150, width: 0, height: 30)
            )
        ) { error in
            XCTAssertEqual(error as? ScreenshotGeometryError, .emptySelection)
        }
        XCTAssertEqual(
            try geometry.mapper.pixelRect(
                fromGlobalScreenRect: CGRect(x: 0, y: 0, width: 300, height: 300)
            ),
            PixelRect(x: 0, y: 0, width: 100, height: 100)
        )
        XCTAssertEqual(
            try geometry.mapper.pixelRect(
                fromGlobalScreenRect: CGRect(x: 100.25, y: 100.25, width: 0.5, height: 0.5)
            ),
            PixelRect(x: 0, y: 99, width: 1, height: 1)
        )
    }

    @MainActor
    func testMovingSelectionKeepsAnnotationsInSourcePixels() throws {
        let source = try makeSource(kind: .display(1), width: 200, height: 120)
        let session = ScreenshotSession()
        session.begin(with: source)
        try session.select(pixelRect: PixelRect(x: 10, y: 10, width: 40, height: 30))
        let annotation = ScreenshotAnnotation(rect: PixelRect(x: 20, y: 20, width: 8, height: 8))
        try session.addAnnotation(annotation)

        try session.moveSelection(to: PixelRect(x: 100, y: 60, width: 40, height: 30))

        XCTAssertEqual(session.selection, PixelRect(x: 100, y: 60, width: 40, height: 30))
        XCTAssertEqual(session.annotations, [annotation])
    }

    @MainActor
    func testCancelPrioritizesCurrentInteractionThenEndsSession() throws {
        let session = ScreenshotSession()
        session.begin(with: try makeSource(kind: .window(7), width: 120, height: 80))
        try session.select(pixelRect: PixelRect(x: 5, y: 5, width: 20, height: 20))
        let annotation = ScreenshotAnnotation(rect: PixelRect(x: 8, y: 8, width: 4, height: 4))
        try session.addAnnotation(annotation)
        try session.beginInteraction(.annotation(annotation.id))

        XCTAssertFalse(session.cancel())
        XCTAssertEqual(session.phase, .editing)
        XCTAssertNil(session.interaction)
        XCTAssertEqual(session.annotations, [annotation])

        XCTAssertTrue(session.cancel())
        XCTAssertEqual(session.phase, .ended)
        XCTAssertNil(session.source)
        XCTAssertNil(session.selection)
        XCTAssertTrue(session.annotations.isEmpty)
    }

    @MainActor
    func testOutputStateCanReturnToEditingOrFinish() throws {
        let session = ScreenshotSession()
        session.begin(with: try makeSource(kind: .display(1), width: 100, height: 100))
        try session.select(pixelRect: PixelRect(x: 0, y: 0, width: 100, height: 100))
        try session.beginOutput()
        XCTAssertEqual(session.phase, .outputting)

        session.outputCancelled()
        XCTAssertEqual(session.phase, .editing)
        XCTAssertNotNil(session.selection)

        try session.beginOutput()
        session.outputSucceeded()
        XCTAssertEqual(session.phase, .ended)
        XCTAssertNil(session.source)
    }

    @MainActor
    func testOutputCanFinishWithoutEndingInlineEditorSession() throws {
        let session = ScreenshotSession()
        session.begin(with: try makeSource(kind: .display(1), width: 100, height: 100))
        try session.select(pixelRect: PixelRect(x: 0, y: 0, width: 100, height: 100))
        let selection = try XCTUnwrap(session.selection)

        try session.beginOutput()
        session.outputSucceededKeepingEditorActive()

        XCTAssertEqual(session.phase, .editing)
        XCTAssertEqual(session.selection, selection)
        XCTAssertNoThrow(try session.beginOutput())
    }

    func testAppKitWindowCoordinatesConvertBothWays() {
        let windowFrame = CGRect(x: -500, y: 200, width: 800, height: 600)
        let global = CGRect(x: -450, y: 300, width: 100, height: 50)
        let local = ScreenshotCoordinateMapper.appKitLocalRect(fromGlobalScreenRect: global, in: windowFrame)
        XCTAssertEqual(local, CGRect(x: 50, y: 100, width: 100, height: 50))
        XCTAssertEqual(
            ScreenshotCoordinateMapper.globalScreenRect(fromAppKitLocalRect: local, in: windowFrame),
            global
        )
    }

    @MainActor
    func testChoosingWindowReplacesSelectionWithEntireWindowSource() throws {
        let display = try makeSource(kind: .display(1), width: 200, height: 120)
        let window = try makeSource(kind: .window(42), width: 90, height: 60)
        let session = ScreenshotSession()
        session.begin(with: display)
        let candidate = WindowCaptureCandidate(
            windowID: 42,
            processIdentifier: 100,
            frame: CGRect(x: 20, y: 20, width: 90, height: 60),
            title: "Target",
            applicationName: "Editor",
            bundleIdentifier: "com.example.Editor"
        )
        session.setTargets([
            .window(candidate),
            .display(displayID: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 120)),
        ])
        XCTAssertEqual(session.target(at: CGPoint(x: 40, y: 40)), .window(candidate))
        XCTAssertEqual(
            session.target(at: CGPoint(x: 180, y: 100)),
            .display(displayID: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        )
        try session.beginInteraction(.selectingRegion)

        try session.chooseWindow(42, source: window)

        XCTAssertEqual(session.phase, .editing)
        XCTAssertNil(session.interaction)
        XCTAssertEqual(session.source?.geometry.kind, .window(42))
        XCTAssertEqual(session.selection, PixelRect(x: 0, y: 0, width: 90, height: 60))
    }

    @MainActor
    func testUndoRedoCoalescesAnnotationDragAndClearsRedoBranch() throws {
        let session = ScreenshotSession()
        session.begin(with: try makeSource(kind: .display(1), width: 200, height: 120))
        try session.select(pixelRect: PixelRect(x: 0, y: 0, width: 200, height: 120))
        let annotation = ScreenshotAnnotation(rect: PixelRect(x: 20, y: 20, width: 30, height: 20))
        try session.addAnnotation(annotation)
        try session.beginInteraction(.annotation(annotation.id))
        try session.updateAnnotation(annotation.id, rect: PixelRect(x: 30, y: 25, width: 30, height: 20))
        try session.updateAnnotation(annotation.id, rect: PixelRect(x: 40, y: 30, width: 30, height: 20))
        session.endInteraction()

        XCTAssertEqual(session.annotations.first?.rect, PixelRect(x: 40, y: 30, width: 30, height: 20))
        XCTAssertTrue(session.canUndo)

        session.undo()
        XCTAssertEqual(session.annotations.first?.rect, PixelRect(x: 20, y: 20, width: 30, height: 20))
        XCTAssertTrue(session.canRedo)

        session.redo()
        XCTAssertEqual(session.annotations.first?.rect, PixelRect(x: 40, y: 30, width: 30, height: 20))

        session.undo()
        try session.updateAnnotation(annotation.id, rect: PixelRect(x: 60, y: 40, width: 30, height: 20))
        XCTAssertFalse(session.canRedo)
    }

    @MainActor
    func testCreatingAnnotationCommitsOneUndoEntryAndUndoRestoresSelectionState() throws {
        let session = ScreenshotSession()
        session.begin(with: try makeSource(kind: .display(1), width: 200, height: 120))
        try session.select(pixelRect: PixelRect(x: 20, y: 10, width: 100, height: 80))
        try session.beginInteraction(.creatingAnnotation)
        let annotation = ScreenshotAnnotation(
            rect: PixelRect(x: 30, y: 20, width: 40, height: 30)
        )
        try session.addAnnotation(annotation)
        session.endInteraction()

        XCTAssertEqual(session.annotations, [annotation])
        XCTAssertEqual(session.selectedAnnotationID, annotation.id)
        XCTAssertTrue(session.canUndo)

        session.undo()

        XCTAssertTrue(session.annotations.isEmpty)
        XCTAssertNil(session.selectedAnnotationID)
        XCTAssertEqual(session.selection, PixelRect(x: 20, y: 10, width: 100, height: 80))
    }

    @MainActor
    func testUndoRestoresSelectionWhileAnnotationsRemainInSourcePixels() throws {
        let session = ScreenshotSession()
        session.begin(with: try makeSource(kind: .display(1), width: 200, height: 120))
        try session.select(pixelRect: PixelRect(x: 0, y: 0, width: 200, height: 120))
        let annotation = ScreenshotAnnotation(rect: PixelRect(x: 10, y: 10, width: 180, height: 100))
        try session.addAnnotation(annotation)
        try session.beginInteraction(.resizingSelection)
        try session.select(pixelRect: PixelRect(x: 80, y: 50, width: 40, height: 30))
        session.endInteraction()

        XCTAssertEqual(session.selection, PixelRect(x: 80, y: 50, width: 40, height: 30))
        XCTAssertEqual(session.annotations, [annotation])

        session.undo()

        XCTAssertEqual(session.selection, PixelRect(x: 0, y: 0, width: 200, height: 120))
        XCTAssertEqual(session.annotations, [annotation])
    }

    @MainActor
    func testCancelInteractionRestoresPreviousContent() throws {
        let session = ScreenshotSession()
        session.begin(with: try makeSource(kind: .window(9), width: 120, height: 80))
        try session.chooseWindow(
            9,
            source: try makeSource(kind: .window(9), width: 120, height: 80)
        )
        try session.beginInteraction(.movingSelection)
        try session.select(pixelRect: PixelRect(x: 40, y: 30, width: 60, height: 40))

        session.cancelInteraction()

        XCTAssertEqual(session.selection, PixelRect(x: 0, y: 0, width: 120, height: 80))
        XCTAssertNil(session.interaction)
        XCTAssertFalse(session.canUndo)
    }

    func testCropUsesSourcePixelCoordinatesAndDimensions() throws {
        let image = try makeStripedImage(width: 12, height: 8)
        let geometry = try ScreenshotSourceGeometry(
            kind: .display(1),
            globalFrame: CGRect(x: 0, y: 0, width: 6, height: 4),
            pointPixelScale: 2,
            pixelSize: try PixelSize(width: 12, height: 8)
        )
        let source = try ScreenshotImageSource(image: image, geometry: geometry)

        let cropped = try source.cropped(to: PixelRect(x: 6, y: 2, width: 6, height: 4))

        XCTAssertEqual(cropped.width, 6)
        XCTAssertEqual(cropped.height, 4)
        let bitmap = NSBitmapImageRep(cgImage: cropped)
        let color = try XCTUnwrap(bitmap.colorAt(x: 3, y: 2)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(color.blueComponent, color.redComponent)
    }

    func testRenderedOutputIncludesRectangleAnnotationInsideSelection() throws {
        let image = try makeImage(width: 40, height: 30)
        let geometry = try ScreenshotSourceGeometry(
            kind: .window(5),
            globalFrame: CGRect(x: 0, y: 0, width: 40, height: 30),
            pointPixelScale: 1,
            pixelSize: PixelSize(width: 40, height: 30)
        )
        let source = try ScreenshotImageSource(image: image, geometry: geometry)
        let selection = PixelRect(x: 10, y: 8, width: 20, height: 16)
        let annotation = ScreenshotAnnotation(
            rect: PixelRect(x: 14, y: 12, width: 10, height: 8)
        )

        let rendered = try ScreenshotAnnotationRenderer.render(
            source: source,
            selection: selection,
            annotations: [annotation]
        )

        XCTAssertEqual(rendered.width, selection.width)
        XCTAssertEqual(rendered.height, selection.height)
        let bitmap = NSBitmapImageRep(cgImage: rendered)
        var redPixelCount = 0
        for y in 0..<rendered.height {
            for x in 0..<rendered.width {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    continue
                }
                if color.redComponent > 0.8,
                   color.redComponent > color.greenComponent * 1.5,
                   color.redComponent > color.blueComponent * 1.5 {
                    redPixelCount += 1
                }
            }
        }
        XCTAssertGreaterThan(redPixelCount, 10)
    }

    func testUnannotatedRenderedOutputPreservesSourceOrientationAndPixels() throws {
        let image = try makeTopBottomStripedImage(width: 20, height: 12)
        let geometry = try ScreenshotSourceGeometry(
            kind: .display(1),
            globalFrame: CGRect(x: 0, y: 0, width: 20, height: 12),
            pointPixelScale: 1,
            pixelSize: PixelSize(width: 20, height: 12)
        )
        let source = try ScreenshotImageSource(image: image, geometry: geometry)
        let selection = PixelRect(x: 0, y: 0, width: 20, height: 12)

        let rendered = try ScreenshotAnnotationRenderer.render(
            source: source,
            selection: selection,
            annotations: []
        )
        let cropped = try XCTUnwrap(image.cropping(to: selection.cgRect))

        XCTAssertEqual(
            try XCTUnwrap(rendered.dataProvider?.data) as Data,
            try XCTUnwrap(cropped.dataProvider?.data) as Data
        )
    }

    @MainActor
    private func makeSource(kind: ScreenshotSourceKind, width: Int, height: Int) throws -> ScreenshotImageSource {
        let image = try makeImage(width: width, height: height)
        let geometry = try ScreenshotSourceGeometry(
            kind: kind,
            globalFrame: CGRect(x: 0, y: 0, width: width, height: height),
            pointPixelScale: 1,
            pixelSize: try PixelSize(width: width, height: height)
        )
        return try ScreenshotImageSource(image: image, geometry: geometry)
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func makeStripedImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func makeTopBottomStripedImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        return try XCTUnwrap(context.makeImage())
    }
}
