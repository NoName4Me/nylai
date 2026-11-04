import AppKit
import XCTest
@testable import nylai

final class SelectionGeometryTests: XCTestCase {
    func testDraggingInEveryDirectionCreatesNormalizedRectangle() {
        let start = CGPoint(x: 50, y: 50)
        let cases: [(CGPoint, CGRect)] = [
            (CGPoint(x: 100, y: 100), CGRect(x: 50, y: 50, width: 50, height: 50)),
            (CGPoint(x: 10, y: 100), CGRect(x: 10, y: 50, width: 40, height: 50)),
            (CGPoint(x: 100, y: 10), CGRect(x: 50, y: 10, width: 50, height: 40)),
            (CGPoint(x: 10, y: 10), CGRect(x: 10, y: 10, width: 40, height: 40)),
        ]
        for (end, expected) in cases {
            let rect = SelectionGeometry.normalizedSelection(from: start, to: end)
            XCTAssertEqual(rect, expected)
        }
    }

    func testEightHandlesHitAndResizeWithinBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 120)
        let rect = CGRect(x: 20, y: 20, width: 100, height: 60)
        let points = SelectionGeometry.handlePoints(in: rect)
        XCTAssertEqual(SelectionGeometry.handle(at: points.topLeft, in: rect), .topLeft)
        XCTAssertEqual(SelectionGeometry.handle(at: points.top, in: rect), .top)
        XCTAssertEqual(SelectionGeometry.handle(at: points.bottomRight, in: rect), .bottomRight)
        XCTAssertNil(SelectionGeometry.handle(at: CGPoint(x: 80, y: 50), in: rect))

        let expanded = SelectionGeometry.resized(
            rect, handle: .topLeft, by: CGPoint(x: -200, y: -200),
            constrainedTo: bounds, minimumSize: CGSize(width: 1, height: 1)
        )
        XCTAssertEqual(expanded, CGRect(x: 0, y: 0, width: 120, height: 80))

        let collapsed = SelectionGeometry.resized(
            rect, handle: .bottomRight, by: CGPoint(x: -200, y: -200),
            constrainedTo: bounds, minimumSize: CGSize(width: 1, height: 1)
        )
        XCTAssertEqual(collapsed, CGRect(x: 20, y: 20, width: 1, height: 1))
    }

    func testHandlesAreCenteredOnSelectionBorder() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 120)
        let points = SelectionGeometry.handlePoints(in: bounds)

        XCTAssertEqual(points.topLeft, CGPoint(x: bounds.minX, y: bounds.minY))
        XCTAssertEqual(points.bottomRight, CGPoint(x: bounds.maxX, y: bounds.maxY))
        XCTAssertEqual(points.left, CGPoint(x: bounds.minX, y: bounds.midY))
        XCTAssertEqual(SelectionGeometry.handle(at: points.bottomRight, in: bounds), .bottomRight)
        XCTAssertEqual(SelectionGeometry.handle(at: points.left, in: bounds), .left)
    }

    func testSelectionCornerHandlesUseDiagonalResizeCursors() {
        XCTAssertEqual(
            SelectionResizeHandle.topLeft.resizeCursorStyle,
            .diagonalTopLeftBottomRight
        )
        XCTAssertEqual(
            SelectionResizeHandle.bottomRight.resizeCursorStyle,
            .diagonalTopLeftBottomRight
        )
        XCTAssertEqual(
            SelectionResizeHandle.topRight.resizeCursorStyle,
            .diagonalTopRightBottomLeft
        )
        XCTAssertEqual(
            SelectionResizeHandle.bottomLeft.resizeCursorStyle,
            .diagonalTopRightBottomLeft
        )
        XCTAssertEqual(SelectionResizeHandle.top.resizeCursorStyle, .vertical)
        XCTAssertEqual(SelectionResizeHandle.left.resizeCursorStyle, .horizontal)
    }

    func testAnnotationSelectionUsesEightFreeHandlesAndOptionalProportionalResize() {
        let rect = CGRect(x: 20, y: 20, width: 100, height: 50)
        let points = SelectionGeometry.handlePoints(in: rect)

        XCTAssertEqual(AnnotationSelectionGeometry.handle(at: points.left, in: rect), .left)
        XCTAssertEqual(AnnotationSelectionGeometry.handle(at: points.topRight, in: rect), .topRight)
        let resized = AnnotationSelectionGeometry.resized(
            rect,
            handle: .bottomRight,
            by: CGPoint(x: 50, y: 10),
            constrainedTo: CGRect(x: 0, y: 0, width: 300, height: 200),
            minimumSize: CGSize(width: 1, height: 1)
        )
        XCTAssertEqual(resized, CGRect(x: 20, y: 20, width: 150, height: 60))
        XCTAssertNil(
            AnnotationSelectionGeometry.handle(
                at: points.left,
                in: rect,
                proportional: true
            )
        )
        let verticalResize = AnnotationSelectionGeometry.resized(
            rect,
            handle: .bottomRight,
            by: CGPoint(x: 10, y: 10),
            constrainedTo: CGRect(x: 0, y: 0, width: 200, height: 120),
            minimumSize: CGSize(width: 1, height: 1),
            proportional: true
        )
        XCTAssertEqual(verticalResize.width / verticalResize.height, 2, accuracy: 0.0001)
        XCTAssertEqual(verticalResize.minX, rect.minX)
        XCTAssertEqual(verticalResize.minY, rect.minY)
    }

    func testCornerRadiusHandleTracksInwardAndOutwardDrag() {
        let selection = CGRect(x: 20, y: 20, width: 200, height: 120)
        let handle = SelectionCornerRadiusGeometry.handleCenter(in: selection, radius: 0)
        XCTAssertEqual(handle, CGPoint(x: 200, y: 120))
        XCTAssertEqual(
            SelectionCornerRadiusGeometry.radius(startRadius: 0, dragDelta: CGPoint(x: -20, y: -24)),
            22
        )
        XCTAssertEqual(
            SelectionCornerRadiusGeometry.radius(startRadius: 12, dragDelta: CGPoint(x: 30, y: 30)),
            0
        )
    }

    func testSmallSelectionInteriorStaysAvailableForMoving() {
        let rect = CGRect(x: 20, y: 20, width: 50, height: 30)
        let points = SelectionGeometry.handlePoints(in: rect)

        XCTAssertNil(SelectionGeometry.handle(at: CGPoint(x: 45, y: 35), in: rect))
        XCTAssertEqual(SelectionGeometry.handle(at: points.left, in: rect), .left)
    }

    func testMoveSelectionClampsAtScreenEdgesWithoutChangingSize() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 120)
        let rect = CGRect(x: 20, y: 20, width: 50, height: 30)
        XCTAssertEqual(
            SelectionGeometry.moved(rect, by: CGPoint(x: -100, y: -100), constrainedTo: bounds),
            CGRect(x: 0, y: 0, width: 50, height: 30)
        )
        XCTAssertEqual(
            SelectionGeometry.moved(rect, by: CGPoint(x: 300, y: 300), constrainedTo: bounds),
            CGRect(x: 150, y: 90, width: 50, height: 30)
        )
    }

    func testToolbarStaysInsideScreenBelowThenAboveSelection() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let toolbar = CGSize(width: 160, height: 40)
        let center = CGRect(x: 120, y: 100, width: 160, height: 80)
        XCTAssertEqual(
            SelectionToolbarPlacement.origin(toolbarSize: toolbar, selection: center, in: bounds),
            CGPoint(x: 120, y: 192)
        )

        let bottom = CGRect(x: 120, y: 0, width: 160, height: 80)
        XCTAssertEqual(
            SelectionToolbarPlacement.origin(toolbarSize: toolbar, selection: bottom, in: bounds),
            CGPoint(x: 120, y: 92)
        )

        let edge = CGRect(x: 390, y: 290, width: 10, height: 10)
        let origin = SelectionToolbarPlacement.origin(toolbarSize: toolbar, selection: edge, in: bounds)
        XCTAssertLessThanOrEqual(origin.x + toolbar.width, 400 - 12)
        XCTAssertLessThanOrEqual(origin.y + toolbar.height, 300 - 12)
    }

    func testTwoToolbarGroupsUseBottomAndRightThenMoveInsideFullScreenSelection() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let selection = CGRect(x: 180, y: 140, width: 500, height: 300)
        let layout = ScreenshotToolbarLayout.layout(
            selection: selection,
            bounds: bounds,
            editingSize: CGSize(width: 520, height: 44),
            outputSize: CGSize(width: 116, height: 250)
        )
        XCTAssertEqual(layout.editingFrame.minY, selection.maxY + 10)
        XCTAssertEqual(layout.outputFrame.minX, selection.maxX + 10)
        XCTAssertFalse(layout.editingFrame.intersects(layout.outputFrame))

        let fullScreen = ScreenshotToolbarLayout.layout(
            selection: bounds,
            bounds: bounds,
            editingSize: CGSize(width: 520, height: 44),
            outputSize: CGSize(width: 116, height: 250)
        )
        XCTAssertTrue(bounds.contains(fullScreen.editingFrame))
        XCTAssertTrue(bounds.contains(fullScreen.outputFrame))
        XCTAssertTrue(bounds.contains(fullScreen.editingFrame))
        XCTAssertLessThan(fullScreen.editingFrame.maxY, bounds.maxY)
        XCTAssertGreaterThan(fullScreen.outputFrame.minX, bounds.maxX - 130)
    }

    func testToolbarGroupsAvoidEachOtherAtScreenCorner() {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 700)
        let selection = CGRect(x: 610, y: 0, width: 290, height: 260)

        let layout = ScreenshotToolbarLayout.layout(
            selection: selection,
            bounds: bounds,
            editingSize: CGSize(width: 568, height: 46),
            outputSize: CGSize(width: 120, height: 184)
        )

        XCTAssertTrue(bounds.contains(layout.editingFrame))
        XCTAssertTrue(bounds.contains(layout.outputFrame))
        XCTAssertFalse(layout.editingFrame.intersects(layout.outputFrame))
    }

    func testAnnotationViewportMapsSourcePixelsAtRetinaScale() throws {
        let viewport = try XCTUnwrap(ScreenshotAnnotationViewport(
            pixelSize: PixelSize(width: 400, height: 240),
            viewSize: CGSize(width: 200, height: 120)
        ))
        let pixelRect = PixelRect(x: 20, y: 30, width: 80, height: 40)

        XCTAssertEqual(viewport.viewRect(for: pixelRect), CGRect(x: 10, y: 15, width: 40, height: 20))
        XCTAssertEqual(viewport.pixelRect(from: CGRect(x: 10, y: 15, width: 40, height: 20)), pixelRect)
    }

    func testAnnotationHitTestUsesTopmostVisibleObject() throws {
        let annotations = [
            ScreenshotAnnotation(rect: PixelRect(x: 10, y: 10, width: 80, height: 80)),
            ScreenshotAnnotation(rect: PixelRect(x: 20, y: 20, width: 50, height: 30)),
        ]
        let viewport = try XCTUnwrap(ScreenshotAnnotationViewport(
            pixelSize: PixelSize(width: 200, height: 120),
            viewSize: CGSize(width: 200, height: 120)
        ))

        XCTAssertEqual(
            ScreenshotAnnotationViewport.hitTest(
                CGPoint(x: 30, y: 20),
                annotations: annotations,
                viewport: viewport,
                visibleIn: CGRect(x: 0, y: 0, width: 200, height: 120)
            ),
            annotations[1].id
        )
        XCTAssertEqual(
            ScreenshotAnnotationViewport.hitTest(
                CGPoint(x: 15, y: 15),
                annotations: annotations,
                viewport: viewport,
                visibleIn: CGRect(x: 0, y: 0, width: 200, height: 120)
            ),
            annotations[0].id
        )
        XCTAssertNil(
            ScreenshotAnnotationViewport.hitTest(
                CGPoint(x: 15, y: 15),
                annotations: annotations,
                viewport: viewport,
                visibleIn: CGRect(x: 50, y: 0, width: 150, height: 120)
            )
        )
    }
}
