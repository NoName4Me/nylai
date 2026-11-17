import AppKit
import XCTest
@testable import nylai

final class ScreenshotAnnotationTests: XCTestCase {
    func testArrowSupportsUniformAndTaperedWidthsWithOptionalCurve() {
        var style = ScreenshotAnnotationStyle.default
        style.arrowOptions = ScreenshotArrowOptions(
            widthStyle: .uniform,
            pathStyle: .curved
        )
        let annotation = ScreenshotAnnotation(kind: .arrow, start: PixelPoint(x: 0, y: 0),
                                              end: PixelPoint(x: 180, y: 0), style: style)
        let bounds = CGRect(x: 0, y: 0, width: 180, height: 1)
        let screen = ScreenshotAnnotationPath.cgPath(for: annotation, in: bounds).boundingBoxOfPath
        let export = ScreenshotAnnotationPath.cgPath(for: annotation, in: bounds, flipped: false).boundingBoxOfPath
        XCTAssertGreaterThan(screen.maxY, 15)
        XCTAssertLessThan(export.minY, -15)
        XCTAssertEqual(
            ScreenshotAnnotationPath.arrowHandles(for: annotation, in: bounds).count,
            4
        )
        XCTAssertNil(ScreenshotAnnotationPath.fillPath(for: annotation, in: bounds))

        style.arrowOptions = ScreenshotArrowOptions(
            widthStyle: .tapered,
            pathStyle: .straight
        )
        let tapered = ScreenshotAnnotation(
            kind: .arrow,
            start: PixelPoint(x: 0, y: 0),
            end: PixelPoint(x: 180, y: 0),
            style: style
        )
        XCTAssertNotNil(ScreenshotAnnotationPath.fillPath(for: tapered, in: bounds))
        XCTAssertEqual(
            ScreenshotAnnotationPath.arrowHandles(for: tapered, in: bounds).count,
            2
        )
    }

    func testLegacyArrowOptionsMigrateToCompactWidthAndPathControls() throws {
        let data = Data(#"{"form":"body","tapered":true,"curve":"left"}"#.utf8)
        let options = try JSONDecoder().decode(ScreenshotArrowOptions.self, from: data)

        XCTAssertEqual(options.widthStyle, .tapered)
        XCTAssertEqual(options.pathStyle, .curved)
    }

    func testUniformArrowSupportsDashesAndTaperedArrowUsesOnlyItsFill() throws {
        let source = try makeSource(width: 220, height: 100)
        let selection = PixelRect(x: 0, y: 0, width: 220, height: 100)
        var style = ScreenshotAnnotationStyle(
            color: ScreenshotAnnotationColor(red: 1, green: 0, blue: 0, alpha: 1),
            lineWidth: 5,
            lineStyle: .solid
        )
        style.arrowOptions = ScreenshotArrowOptions(
            widthStyle: .uniform,
            pathStyle: .straight
        )
        let solid = ScreenshotAnnotation(
            kind: .arrow,
            start: PixelPoint(x: 15, y: 50),
            end: PixelPoint(x: 205, y: 50),
            style: style
        )
        style.lineStyle = .dashed
        let dashed = ScreenshotAnnotation(
            kind: .arrow,
            start: solid.start,
            end: solid.end,
            style: style
        )
        let solidCount = try renderCount(
            source: source,
            selection: selection,
            annotation: solid
        )
        let dashedCount = try renderCount(
            source: source,
            selection: selection,
            annotation: dashed
        )
        XCTAssertGreaterThan(solidCount, dashedCount)
        XCTAssertGreaterThan(dashedCount, 0)

        style.arrowOptions = ScreenshotArrowOptions(
            widthStyle: .tapered,
            pathStyle: .straight
        )
        style.lineStyle = .solid
        let taperedSolid = ScreenshotAnnotation(
            kind: .arrow,
            start: solid.start,
            end: solid.end,
            style: style
        )
        style.lineStyle = .dashed
        let taperedDashed = ScreenshotAnnotation(
            kind: .arrow,
            start: solid.start,
            end: solid.end,
            style: style
        )
        XCTAssertEqual(
            try renderCount(source: source, selection: selection, annotation: taperedSolid),
            try renderCount(source: source, selection: selection, annotation: taperedDashed)
        )
    }

    func testTaperedArrowRendersAsOneConnectedShapeAcrossStraightAndCurvedPaths() throws {
        let source = try makeSource(width: 320, height: 320)
        let selection = PixelRect(x: 0, y: 0, width: 320, height: 320)
        let directions: [(CGFloat, CGFloat)] = [
            (1, 0), (1, 1), (0, 1), (-1, 1),
            (-1, 0), (-1, -1), (0, -1), (1, -1),
        ]

        for pathStyle in ScreenshotArrowPathStyle.allCases {
            for (dx, dy) in directions {
                for distance: CGFloat in [28, 92] {
                    for lineWidth in [2, 6, 12] {
                        let start = PixelPoint(x: 160, y: 160)
                        let end = PixelPoint(
                            x: 160 + Int((dx * distance).rounded()),
                            y: 160 + Int((dy * distance).rounded())
                        )
                        var style = ScreenshotAnnotationStyle(
                            color: ScreenshotAnnotationColor(
                                red: 1,
                                green: 0,
                                blue: 0,
                                alpha: 1
                            ),
                            lineWidth: lineWidth,
                            lineStyle: .solid
                        )
                        style.arrowOptions = ScreenshotArrowOptions(
                            widthStyle: .tapered,
                            pathStyle: pathStyle
                        )
                        let arrow = ScreenshotAnnotation(
                            kind: .arrow,
                            start: start,
                            end: end,
                            style: style
                        )
                        let output = try ScreenshotAnnotationRenderer.render(
                            source: source,
                            selection: selection,
                            annotations: [arrow]
                        )

                        let connectedComponents = redConnectedComponentCount(
                            in: output
                        )
                        if connectedComponents != 1 {
                            try pngLikeData(output).write(
                                to: URL(fileURLWithPath:
                                    "/tmp/nylai-arrow-gap-\(pathStyle.rawValue)-\(Int(dx))-\(Int(dy))-\(Int(distance))-\(lineWidth).png")
                            )
                        }
                        XCTAssertEqual(
                            connectedComponents,
                            1,
                            "\(pathStyle) \(dx),\(dy) \(distance) \(lineWidth)"
                        )
                    }
                }
            }
        }
    }

    @MainActor
    func testTaperedArrowHidesLineStyleTab() throws {
        let toolbar = SelectionToolbarView(frame: CGRect(x: 0, y: 0, width: 330, height: 104))
        let window = attachToWindow(toolbar)
        defer { window.orderOut(nil) }
        toolbar.styleControlsEnabled = true
        toolbar.styleKind = .arrow
        var style = ScreenshotAnnotationStyle.default
        style.arrowOptions = ScreenshotArrowOptions(widthStyle: .uniform)
        toolbar.style = style
        let lineStyle = try XCTUnwrap(
            findView(accessibilityLabel: "线型", in: toolbar)
        )
        XCTAssertFalse(lineStyle.isHidden)

        style.arrowOptions = ScreenshotArrowOptions(widthStyle: .tapered)
        toolbar.style = style

        XCTAssertTrue(lineStyle.isHidden)
    }

    @MainActor
    func testArrowCircleHandleBendsShaftWithoutMovingSquareEndpoints() throws {
        let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 760, height: 540))
        let window = attachToWindow(view)
        defer { window.orderOut(nil) }
        view.sourcePixelSize = try PixelSize(width: 760, height: 540)
        view.setSelection(CGRect(x: 40, y: 40, width: 620, height: 390), notify: false)
        view.setTool(.objectSelection)
        var style = ScreenshotAnnotationStyle.default
        style.arrowOptions = ScreenshotArrowOptions(pathStyle: .curved)
        let arrow = ScreenshotAnnotation(
            kind: .arrow,
            start: PixelPoint(x: 120, y: 180),
            end: PixelPoint(x: 360, y: 180),
            style: style
        )
        view.setAnnotations([arrow], selectedID: arrow.id)
        var changed: ScreenshotAnnotation?
        view.onArrowGeometryChanged = { changed = $0 }
        let first = ScreenshotAnnotationPath.arrowHandles(
            for: arrow,
            in: arrow.rect.cgRect
        )[1]
        let moved = CGPoint(x: first.x + 8, y: first.y - 52)
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: view, at: first))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: view, at: moved))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, in: view, at: moved))
        let curved = try XCTUnwrap(changed)
        XCTAssertEqual(curved.start, arrow.start)
        XCTAssertEqual(curved.end, arrow.end)
        let handles = ScreenshotAnnotationPath.arrowHandles(for: curved, in: curved.rect.cgRect)
        XCTAssertEqual(handles[1].x, moved.x, accuracy: 1)
        XCTAssertEqual(handles[1].y, moved.y, accuracy: 1)
    }

    func testColorSamplerReturnsHexAndRGBForTheExactPixel() throws {
        let image = try makeCheckerboardImage(width: 4, height: 4)
        let first = try XCTUnwrap(ScreenshotColorSampler.color(
            in: image,
            at: PixelPoint(x: 0, y: 0)
        ))
        let second = try XCTUnwrap(ScreenshotColorSampler.color(
            in: image,
            at: PixelPoint(x: 1, y: 0)
        ))

        XCTAssertEqual(first.hexText.count, 7)
        XCTAssertTrue(first.hexText.hasPrefix("#"))
        XCTAssertTrue(first.rgbText.hasPrefix("RGB "))
        XCTAssertNotEqual(first, second)
        func isRed(_ color: ScreenshotInspectorColor) -> Bool {
            color.red > 200
                && Int(color.red) > Int(color.green) * 2
                && Int(color.red) > Int(color.blue) * 2
        }
        func isBlue(_ color: ScreenshotInspectorColor) -> Bool {
            color.blue > 200
                && Int(color.blue) > Int(color.red) * 2
                && Int(color.blue) > Int(color.green) * 2
        }
        XCTAssertTrue(
            [first, second].contains(where: isRed),
            "\(first.hexText) \(second.hexText)"
        )
        XCTAssertTrue(
            [first, second].contains(where: isBlue),
            "\(first.hexText) \(second.hexText)"
        )
    }

    @MainActor
    func testEveryGeometryToolCreatesTypedAnnotationWithCurrentStyle() throws {
        let cases: [(ScreenshotEditorTool, ScreenshotAnnotationKind)] = [
            (.rectangle, .rectangle),
            (.ellipse, .ellipse),
            (.line, .line),
            (.arrow, .arrow),
        ]
        let style = ScreenshotAnnotationStyle(
            color: ScreenshotAnnotationColor(red: 0.1, green: 0.7, blue: 0.3, alpha: 0.8),
            lineWidth: 7,
            lineStyle: .dashed
        )

        for (tool, expectedKind) in cases {
            let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
            _ = attachToWindow(view)
            view.sourcePixelSize = try PixelSize(width: 200, height: 120)
            view.setSelection(CGRect(x: 0, y: 0, width: 200, height: 120), notify: false)
            view.setTool(tool)
            view.setDisplayedStyle(style)
            var created: ScreenshotAnnotation?
            view.onAnnotationCreated = { created = $0 }

            view.mouseDown(with: try mouseEvent(.leftMouseDown, in: view, at: CGPoint(x: 15, y: 20)))
            view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: view, at: CGPoint(x: 70, y: 55)))
            view.mouseUp(with: try mouseEvent(.leftMouseUp, in: view, at: CGPoint(x: 70, y: 55)))
            if tool == .line {
                XCTAssertNil(created)
                view.rightMouseDown(with: try mouseEvent(
                    .rightMouseDown,
                    in: view,
                    at: CGPoint(x: 70, y: 55)
                ))
            }

            let annotation = try XCTUnwrap(created)
            XCTAssertEqual(annotation.kind, expectedKind)
            XCTAssertEqual(annotation.start, PixelPoint(x: 15, y: 20))
            XCTAssertEqual(annotation.end, PixelPoint(x: 70, y: 55))
            XCTAssertEqual(annotation.style, style.validated())
        }
    }

    func testHitTestingUsesVisibleStrokeInsteadOfBoundingInterior() throws {
        let viewport = ScreenshotAnnotationViewport(
            pixelSize: try PixelSize(width: 200, height: 120),
            viewSize: CGSize(width: 200, height: 120)
        )!
        let selection = CGRect(x: 0, y: 0, width: 200, height: 120)
        let rectangle = ScreenshotAnnotation(
            rect: PixelRect(x: 20, y: 20, width: 60, height: 40)
        )
        let ellipse = ScreenshotAnnotation(
            kind: .ellipse,
            start: PixelPoint(x: 100, y: 20),
            end: PixelPoint(x: 170, y: 80)
        )
        let line = ScreenshotAnnotation(
            kind: .line,
            start: PixelPoint(x: 20, y: 90),
            end: PixelPoint(x: 100, y: 110)
        )
        let annotations = [rectangle, ellipse, line]

        XCTAssertNil(ScreenshotAnnotationViewport.hitTest(
            CGPoint(x: 50, y: 40),
            annotations: annotations,
            viewport: viewport,
            visibleIn: selection
        ))
        XCTAssertEqual(
            ScreenshotAnnotationViewport.hitTest(
                CGPoint(x: 50, y: 20),
                annotations: annotations,
                viewport: viewport,
                visibleIn: selection
            ),
            rectangle.id
        )
        XCTAssertEqual(
            ScreenshotAnnotationViewport.hitTest(
                CGPoint(x: 135, y: 20),
                annotations: annotations,
                viewport: viewport,
                visibleIn: selection
            ),
            ellipse.id
        )
        XCTAssertEqual(
            ScreenshotAnnotationViewport.hitTest(
                CGPoint(x: 60, y: 100),
                annotations: annotations,
                viewport: viewport,
                visibleIn: selection
            ),
            line.id
        )
        XCTAssertNil(ScreenshotAnnotationViewport.hitTest(
            CGPoint(x: 190, y: 110),
            annotations: annotations,
            viewport: viewport,
            visibleIn: selection
        ))
    }

    func testArrowHeadFollowsTheDraggedEndpointAndNotBoundingDirection() {
        let right = ScreenshotAnnotation(
            kind: .arrow,
            start: PixelPoint(x: 10, y: 10),
            end: PixelPoint(x: 80, y: 10)
        )
        let left = ScreenshotAnnotation(
            kind: .arrow,
            start: PixelPoint(x: 80, y: 10),
            end: PixelPoint(x: 10, y: 10)
        )
        XCTAssertTrue(pathContains(CGPoint(x: 73, y: 6), annotation: right))
        XCTAssertFalse(pathContains(CGPoint(x: 17, y: 6), annotation: right))
        XCTAssertTrue(pathContains(CGPoint(x: 17, y: 6), annotation: left))
        XCTAssertFalse(pathContains(CGPoint(x: 73, y: 6), annotation: left))
    }

    func testRendererCoversAllFourGeometryKindsAndStyleVariants() throws {
        let source = try makeSource(width: 100, height: 80)
        let selection = PixelRect(x: 0, y: 0, width: 100, height: 80)
        let solidStyle = ScreenshotAnnotationStyle(
            color: ScreenshotAnnotationColor(red: 1, green: 0, blue: 0, alpha: 1),
            lineWidth: 4,
            lineStyle: .solid
        )
        let dashedStyle = ScreenshotAnnotationStyle(
            color: ScreenshotAnnotationColor(red: 0, green: 0, blue: 1, alpha: 1),
            lineWidth: 4,
            lineStyle: .dashed
        )
        let annotations = [
            ScreenshotAnnotation(
                kind: .rectangle,
                start: PixelPoint(x: 5, y: 5),
                end: PixelPoint(x: 25, y: 20),
                style: solidStyle
            ),
            ScreenshotAnnotation(
                kind: .ellipse,
                start: PixelPoint(x: 30, y: 5),
                end: PixelPoint(x: 50, y: 20),
                style: dashedStyle
            ),
            ScreenshotAnnotation(
                kind: .line,
                start: PixelPoint(x: 5, y: 30),
                end: PixelPoint(x: 48, y: 45),
                style: solidStyle
            ),
            ScreenshotAnnotation(
                kind: .arrow,
                start: PixelPoint(x: 95, y: 30),
                end: PixelPoint(x: 55, y: 50),
                style: dashedStyle
            ),
        ]

        let rendered = try ScreenshotAnnotationRenderer.render(
            source: source,
            selection: selection,
            annotations: annotations
        )
        let bitmap = NSBitmapImageRep(cgImage: rendered)
        var redCount = 0
        var blueCount = 0
        for y in 0..<rendered.height {
            for x in 0..<rendered.width {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    continue
                }
                if color.redComponent > 0.8,
                   color.redComponent > color.greenComponent * 1.5,
                   color.redComponent > color.blueComponent * 1.5 {
                    redCount += 1
                }
                if color.blueComponent > 0.8,
                   color.blueComponent > color.redComponent * 1.5,
                   color.blueComponent > color.greenComponent * 1.5 {
                    blueCount += 1
                }
            }
        }
        XCTAssertGreaterThan(redCount, 100)
        XCTAssertGreaterThan(blueCount, 20)
    }

    func testFilledShapesRenderTheirStrokeColorAtTheCenter() throws {
        let source = try makeSource(width: 60, height: 60)
        let selection = PixelRect(x: 0, y: 0, width: 60, height: 60)
        for kind in [ScreenshotAnnotationKind.rectangle, .ellipse] {
            var style = ScreenshotAnnotationStyle.default
            style.fillsShape = true
            style.color = ScreenshotAnnotationColor(red: 1, green: 0, blue: 0, alpha: 1)
            let annotation = ScreenshotAnnotation(kind: kind, start: PixelPoint(x: 10, y: 10),
                                                  end: PixelPoint(x: 50, y: 50), style: style)
            let rendered = try ScreenshotAnnotationRenderer.render(
                source: source, selection: selection, annotations: [annotation]
            )
            let bitmap = NSBitmapImageRep(cgImage: rendered)
            let center = try XCTUnwrap(bitmap.colorAt(x: 30, y: 30)?.usingColorSpace(.sRGB))
            let stroke = try XCTUnwrap(bitmap.colorAt(x: 30, y: 10)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(center.redComponent, 0.95)
            XCTAssertEqual(center.greenComponent, stroke.greenComponent, accuracy: 0.02)
            XCTAssertEqual(center.blueComponent, stroke.blueComponent, accuracy: 0.02)
        }
    }

    func testDashedStyleRendersFewerPixelsAndWidthChangesCoverage() throws {
        let source = try makeSource(width: 100, height: 40)
        let selection = PixelRect(x: 0, y: 0, width: 100, height: 40)
        let base = ScreenshotAnnotationStyle(
            color: ScreenshotAnnotationColor(red: 1, green: 0, blue: 0, alpha: 1),
            lineWidth: 3,
            lineStyle: .solid
        )
        let horizontal = ScreenshotAnnotation(
            kind: .line,
            start: PixelPoint(x: 5, y: 20),
            end: PixelPoint(x: 95, y: 20),
            style: base
        )
        let thin = try renderCount(source: source, selection: selection, annotation: horizontal)
        var wideStyle = base
        wideStyle.lineWidth = 10
        let wide = try renderCount(
            source: source,
            selection: selection,
            annotation: ScreenshotAnnotation(
                kind: .line,
                start: horizontal.start,
                end: horizontal.end,
                style: wideStyle
            )
        )
        var dashedStyle = base
        dashedStyle.lineStyle = .dashed
        let dashed = try renderCount(
            source: source,
            selection: selection,
            annotation: ScreenshotAnnotation(
                kind: .line,
                start: horizontal.start,
                end: horizontal.end,
                style: dashedStyle
            )
        )

        XCTAssertGreaterThan(wide, thin)
        XCTAssertGreaterThan(thin, dashed)
        XCTAssertGreaterThan(dashed, 0)
    }

    @MainActor
    func testStyleUpdateUsesOneUndoEntry() throws {
        let session = ScreenshotSession()
        session.begin(with: try makeSource(width: 200, height: 120))
        try session.select(pixelRect: PixelRect(x: 0, y: 0, width: 200, height: 120))
        let annotation = ScreenshotAnnotation(
            rect: PixelRect(x: 20, y: 20, width: 40, height: 30)
        )
        try session.addAnnotation(annotation)
        let first = ScreenshotAnnotationStyle(
            color: .defaultRed,
            lineWidth: 5,
            lineStyle: .solid
        )
        let final = ScreenshotAnnotationStyle(
            color: ScreenshotAnnotationColor(red: 0, green: 0.4, blue: 1, alpha: 1),
            lineWidth: 12,
            lineStyle: .dashed
        )
        try session.beginInteraction(.annotation(annotation.id))
        try session.updateAnnotationStyle(annotation.id, style: first)
        try session.updateAnnotationStyle(annotation.id, style: final)
        session.endInteraction()

        XCTAssertEqual(session.annotations.first?.style, final)
        session.undo()
        XCTAssertEqual(session.annotations.first?.style, annotation.style)
        XCTAssertTrue(session.canRedo)
        session.redo()
        XCTAssertEqual(session.annotations.first?.style, final)
    }

    func testStyleStorePersistsEachToolIndependentlyAcrossInstances() throws {
        let suiteName = "ScreenshotAnnotationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ScreenshotAnnotationStyleStore(defaults: defaults)
        let rectangleStyle = ScreenshotAnnotationStyle(
            color: ScreenshotAnnotationColor(red: 0.2, green: 0.3, blue: 0.9, alpha: 1),
            lineWidth: 9,
            lineStyle: .dashed
        )
        let arrowStyle = ScreenshotAnnotationStyle(
            color: ScreenshotAnnotationColor(red: 0.9, green: 0.6, blue: 0.1, alpha: 1),
            lineWidth: 2,
            lineStyle: .solid
        )
        store.setStyle(rectangleStyle, for: ScreenshotAnnotationKind.rectangle)
        store.setStyle(arrowStyle, for: ScreenshotAnnotationKind.arrow)

        let reloaded = ScreenshotAnnotationStyleStore(defaults: defaults)

        XCTAssertEqual(reloaded.style(for: .rectangle), rectangleStyle)
        XCTAssertEqual(reloaded.style(for: .arrow), arrowStyle)
        XCTAssertEqual(reloaded.style(for: .ellipse), .default)
        XCTAssertEqual(reloaded.style(for: .line), .default)
    }

    func testStyleValidationAndRectangleSelectionClamp() throws {
        let style = ScreenshotAnnotationStyle(
            color: ScreenshotAnnotationColor(red: 2, green: -1, blue: 0.5, alpha: 3),
            lineWidth: 99,
            lineStyle: .solid
        ).validated()
        XCTAssertEqual(style.color.red, 1)
        XCTAssertEqual(style.color.green, 0)
        XCTAssertEqual(style.color.blue, 0.5)
        XCTAssertEqual(style.color.alpha, 1)
        XCTAssertEqual(style.lineWidth, ScreenshotAnnotationStyle.maximumLineWidth)

        let source = try makeSource(width: 100, height: 80)
        let annotation = ScreenshotAnnotation(
            kind: .arrow,
            start: PixelPoint(x: 90, y: 70),
            end: PixelPoint(x: 10, y: 20)
        )
        let clipped = annotation.rect.clamped(to: source.geometry.pixelSize)
        XCTAssertEqual(clipped, annotation.rect)
    }

    func testStyleValidationClampsEachAnnotationKindToItsOwnRange() {
        let cases: [(ScreenshotAnnotationKind, Int, Int, Int, Int)] = [
            (.rectangle, 0, 100, 1, 24),
            (.text, 1, 120, 8, 96),
            (.step, 2, 120, 16, 96),
            (.mosaic, 1, 100, 1, 60),
        ]

        for (kind, low, high, expectedLow, expectedHigh) in cases {
            let lowStyle = ScreenshotAnnotationStyle(
                color: .defaultRed,
                lineWidth: low,
                lineStyle: .solid
            ).validated(for: kind)
            let highStyle = ScreenshotAnnotationStyle(
                color: .defaultRed,
                lineWidth: high,
                lineStyle: .solid
            ).validated(for: kind)

            XCTAssertEqual(lowStyle.lineWidth, expectedLow, "\(kind) 下限")
            XCTAssertEqual(highStyle.lineWidth, expectedHigh, "\(kind) 上限")
        }
    }

    func testDefaultStylesUseKindAppropriateLineWidths() {
        XCTAssertEqual(
            ScreenshotAnnotationStyle.defaultStyle(for: .text).lineWidth,
            ScreenshotAnnotationStyle.minimumTextSize + 10
        )
        XCTAssertEqual(
            ScreenshotAnnotationStyle.defaultStyle(for: .step).lineWidth,
            ScreenshotAnnotationStyle.minimumStepSize + 8
        )
        XCTAssertEqual(
            ScreenshotAnnotationStyle.defaultStyle(for: .mosaic).lineWidth,
            16
        )
        XCTAssertEqual(
            ScreenshotAnnotationStyle.defaultStyle(for: .blur).lineWidth,
            18
        )
        XCTAssertEqual(
            ScreenshotAnnotationStyle.defaultStyle(for: .mosaicStroke).lineWidth,
            18
        )
    }

    func testDirectionConstraintSupportsHorizontalVerticalAndDiagonal() {
        let start = PixelPoint(x: 10, y: 10)
        XCTAssertEqual(
            ScreenshotAnnotationDirectionConstraint.constrained(
                from: start,
                to: PixelPoint(x: 80, y: 35),
                modifiers: [.shift]
            ),
            PixelPoint(x: 80, y: 10)
        )
        XCTAssertEqual(
            ScreenshotAnnotationDirectionConstraint.constrained(
                from: start,
                to: PixelPoint(x: 35, y: 80),
                modifiers: [.control]
            ),
            PixelPoint(x: 35, y: 10)
        )
        XCTAssertEqual(
            ScreenshotAnnotationDirectionConstraint.constrained(
                from: start,
                to: PixelPoint(x: 70, y: 30),
                modifiers: [.control, .shift]
            ),
            PixelPoint(x: 70, y: 70)
        )
    }

    @MainActor
    func testBrushAndRedactionStrokesCreateFreehandAnnotations() throws {
        let cases: [(
            ScreenshotEditorTool,
            ScreenshotRedactionEffect?,
            ScreenshotMosaicMode?,
            ScreenshotAnnotationKind
        )] = [
            (.brush, nil, nil, .brush),
            (.mosaic, .mosaic, .stroke, .mosaicStroke),
            (.mosaic, .blur, .stroke, .mosaicBlur),
        ]
        for (tool, effect, shape, expectedKind) in cases {
            let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 240, height: 160))
            _ = attachToWindow(view)
            view.sourcePixelSize = try PixelSize(width: 240, height: 160)
            view.setSelection(CGRect(x: 0, y: 0, width: 240, height: 160), notify: false)
            view.setTool(tool)
            if let effect {
                view.setRedactionEffect(effect)
            }
            if let shape {
                view.setRedactionShape(shape)
            }
            var created: ScreenshotAnnotation?
            view.onAnnotationCreated = { created = $0 }

            view.mouseDown(with: try mouseEvent(.leftMouseDown, in: view, at: CGPoint(x: 20, y: 20)))
            view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: view, at: CGPoint(x: 50, y: 45)))
            view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: view, at: CGPoint(x: 90, y: 30)))
            view.mouseUp(with: try mouseEvent(.leftMouseUp, in: view, at: CGPoint(x: 90, y: 30)))

            let annotation = try XCTUnwrap(created)
            XCTAssertEqual(annotation.kind, expectedKind)
            XCTAssertEqual(annotation.points, [
                PixelPoint(x: 20, y: 20),
                PixelPoint(x: 50, y: 45),
                PixelPoint(x: 90, y: 30),
            ])
        }
    }

    @MainActor
    func testShiftConstrainedFreehandStrokeKeepsOnlyEndpoints() throws {
        let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 240, height: 160))
        _ = attachToWindow(view)
        view.sourcePixelSize = try PixelSize(width: 240, height: 160)
        view.setSelection(CGRect(x: 0, y: 0, width: 240, height: 160), notify: false)
        view.setTool(.brush)
        var created: ScreenshotAnnotation?
        view.onAnnotationCreated = { created = $0 }

        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: view, at: CGPoint(x: 20, y: 20)))
        view.mouseDragged(with: try mouseEvent(
            .leftMouseDragged,
            in: view,
            at: CGPoint(x: 90, y: 55),
            modifiers: [.shift]
        ))
        view.mouseUp(with: try mouseEvent(
            .leftMouseUp,
            in: view,
            at: CGPoint(x: 90, y: 55),
            modifiers: [.shift]
        ))

        let annotation = try XCTUnwrap(created)
        XCTAssertEqual(annotation.kind, .brush)
        XCTAssertEqual(annotation.points, [
            PixelPoint(x: 20, y: 20),
            PixelPoint(x: 90, y: 20),
        ])
    }

    @MainActor
    func testMosaicStrokeCannotBeSelectedForEditing() throws {
        let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 240, height: 160))
        _ = attachToWindow(view)
        view.sourcePixelSize = try PixelSize(width: 240, height: 160)
        view.setSelection(CGRect(x: 0, y: 0, width: 240, height: 160), notify: false)
        view.setTool(.objectSelection)
        let marker = ScreenshotAnnotation(
            points: [PixelPoint(x: 20, y: 20), PixelPoint(x: 100, y: 20)],
            kind: .brush
        )
        let mosaic = ScreenshotAnnotation(
            points: [PixelPoint(x: 20, y: 80), PixelPoint(x: 100, y: 80)],
            kind: .mosaicStroke
        )
        view.setAnnotations([marker, mosaic], selectedID: nil)
        var selected: UUID?
        view.onAnnotationSelected = { selected = $0 }

        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: view, at: CGPoint(x: 60, y: 80)))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, in: view, at: CGPoint(x: 60, y: 80)))

        XCTAssertNil(selected)
        XCTAssertNil(view.selectedAnnotationID)

        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: view, at: CGPoint(x: 60, y: 20)))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, in: view, at: CGPoint(x: 60, y: 20)))
        XCTAssertEqual(selected, marker.id)
    }

    @MainActor
    func testAnnotationResizeHonorsPerKindMinimumSize() throws {
        let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 240, height: 160))
        _ = attachToWindow(view)
        view.sourcePixelSize = try PixelSize(width: 240, height: 160)
        view.setSelection(CGRect(x: 0, y: 0, width: 240, height: 160), notify: false)
        view.setTool(.objectSelection)
        let annotation = ScreenshotAnnotation(
            rect: PixelRect(x: 20, y: 20, width: 60, height: 50)
        )
        view.setAnnotations([annotation], selectedID: annotation.id)
        var changedRect: PixelRect?
        view.onAnnotationChanged = { _, rect, _ in changedRect = rect }
        let rect = CGRect(x: 20, y: 20, width: 60, height: 50)

        view.mouseDown(with: try mouseEvent(
            .leftMouseDown,
            in: view,
            at: CGPoint(x: rect.maxX, y: rect.maxY)
        ))
        view.mouseDragged(with: try mouseEvent(
            .leftMouseDragged,
            in: view,
            at: CGPoint(x: rect.minX - 100, y: rect.minY - 100)
        ))
        view.mouseUp(with: try mouseEvent(
            .leftMouseUp,
            in: view,
            at: CGPoint(x: rect.minX - 100, y: rect.minY - 100)
        ))

        let resized = try XCTUnwrap(changedRect)
        XCTAssertGreaterThanOrEqual(resized.width, 8)
        XCTAssertGreaterThanOrEqual(resized.height, 8)
    }

    func testBrushRendersTranslucentStrokeAndMosaicStrokeProcessesPixels() throws {
        let source = try makeSource(width: 100, height: 60)
        let selection = PixelRect(x: 0, y: 0, width: 100, height: 60)
        let marker = ScreenshotAnnotation(
            points: [PixelPoint(x: 10, y: 30), PixelPoint(x: 90, y: 30)],
            kind: .brush,
            style: ScreenshotAnnotationStyle(
                color: ScreenshotAnnotationColor(red: 1, green: 0, blue: 0, alpha: 0.38),
                lineWidth: 12,
                lineStyle: .solid
            )
        )
        let markerImage = try ScreenshotAnnotationRenderer.render(
            source: source,
            selection: selection,
            annotations: [marker]
        )
        let markerColor = try XCTUnwrap(
            NSBitmapImageRep(cgImage: markerImage)
                .colorAt(x: 50, y: 30)?
                .usingColorSpace(.sRGB)
        )
        XCTAssertGreaterThan(markerColor.redComponent, 0.5)
        XCTAssertLessThan(markerColor.redComponent, 0.99)

        let mosaic = ScreenshotAnnotation(
            points: [PixelPoint(x: 10, y: 30), PixelPoint(x: 90, y: 30)],
            kind: .mosaicStroke,
            style: ScreenshotAnnotationStyle(
                color: .defaultRed,
                lineWidth: 16,
                lineStyle: .solid
            )
        )
        let mosaicSource = try makeCheckerboardImage(width: 100, height: 60)
        let mosaicImage = try ScreenshotAnnotationRenderer.render(
            source: try ScreenshotImageSource(
                image: mosaicSource,
                geometry: source.geometry
            ),
            selection: selection,
            annotations: [mosaic]
        )
        XCTAssertNotEqual(try pngLikeData(mosaicSource), try pngLikeData(mosaicImage))
    }

    func testBrushUsesColorAlphaAndMosaicBlurProcessesPixels() throws {
        let source = try makeSource(width: 100, height: 60)
        let selection = PixelRect(x: 0, y: 0, width: 100, height: 60)
        let brush = ScreenshotAnnotation(
            points: [PixelPoint(x: 10, y: 30), PixelPoint(x: 90, y: 30)],
            kind: .brush,
            style: ScreenshotAnnotationStyle(
                color: ScreenshotAnnotationColor(
                    red: 1,
                    green: 0,
                    blue: 0,
                    alpha: 0.35
                ),
                lineWidth: 12,
                lineStyle: .solid
            )
        )
        let brushImage = try ScreenshotAnnotationRenderer.render(
            source: source,
            selection: selection,
            annotations: [brush]
        )
        let brushColor = try XCTUnwrap(
            NSBitmapImageRep(cgImage: brushImage)
                .colorAt(x: 50, y: 30)?
                .usingColorSpace(.sRGB)
        )
        XCTAssertGreaterThan(brushColor.redComponent, 0.3)
        XCTAssertLessThan(brushColor.redComponent, 0.8)

        let checkerboard = try makeCheckerboardImage(width: 100, height: 60)
        let blur = ScreenshotAnnotation(
            points: [PixelPoint(x: 10, y: 30), PixelPoint(x: 90, y: 30)],
            kind: .mosaicBlur,
            style: ScreenshotAnnotationStyle(
                color: .defaultRed,
                lineWidth: 16,
                lineStyle: .solid
            )
        )
        let blurred = try ScreenshotAnnotationRenderer.render(
            source: try ScreenshotImageSource(
                image: checkerboard,
                geometry: source.geometry
            ),
            selection: selection,
            annotations: [blur]
        )
        XCTAssertNotEqual(try pngLikeData(checkerboard), try pngLikeData(blurred))
    }

    func testBlurBoxUsesTheSameStrongBlurPipelineAsBlurStroke() throws {
        let source = try makeSource(width: 120, height: 80)
        let checkerboard = try makeCheckerboardImage(width: 120, height: 80)
        let selection = PixelRect(x: 0, y: 0, width: 120, height: 80)
        let blur = ScreenshotAnnotation(
            rect: PixelRect(x: 20, y: 20, width: 80, height: 40),
            kind: .blur,
            style: ScreenshotAnnotationStyle(
                color: .defaultRed,
                lineWidth: 18,
                lineStyle: .solid
            )
        )
        let output = try ScreenshotAnnotationRenderer.render(
            source: try ScreenshotImageSource(
                image: checkerboard,
                geometry: source.geometry
            ),
            selection: selection,
            annotations: [blur]
        )

        XCTAssertNotEqual(try pngLikeData(checkerboard), try pngLikeData(output))
        XCTAssertEqual(output.width, 120)
        XCTAssertEqual(output.height, 80)
        let bitmap = NSBitmapImageRep(cgImage: output)
        let brightness = [20, 40, 60, 80, 100].compactMap { x in
            bitmap.colorAt(x: x, y: 40)?.usingColorSpace(.sRGB).map {
                $0.redComponent + $0.greenComponent + $0.blueComponent
            }
        }
        XCTAssertGreaterThan(
            try XCTUnwrap(brightness.max()) - (try XCTUnwrap(brightness.min())),
            0.05,
            "高斯模糊应保留画面层次，不能变成纯灰块"
        )
    }

    func testBlurKeepsADominantColorSoftAndSmoothAtAChromaticEdge() throws {
        let source = try makeTwoColorSplitImage(
            width: 200,
            height: 80,
            left: CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            right: CGColor(red: 0, green: 0.15, blue: 1, alpha: 1)
        )
        let selection = PixelRect(x: 0, y: 0, width: 200, height: 80)
        let blur = ScreenshotAnnotation(
            rect: PixelRect(x: 20, y: 20, width: 160, height: 40),
            kind: .blur,
            style: ScreenshotAnnotationStyle(
                color: .defaultRed,
                lineWidth: 32,
                lineStyle: .solid
            )
        )
        let output = try ScreenshotAnnotationRenderer.render(
            source: source,
            selection: selection,
            annotations: [blur]
        )
        let bitmap = NSBitmapImageRep(cgImage: output)
        let center = try XCTUnwrap(
            bitmap.colorAt(x: 100, y: 40)?.usingColorSpace(.sRGB)
        )

        XCTAssertLessThan(
            abs(center.redComponent - center.blueComponent),
            0.16,
            "对称红蓝交界的高斯模糊不应被额外饱和度推成偏色"
        )

        let leftSample = try XCTUnwrap(
            bitmap.colorAt(x: 30, y: 40)?.usingColorSpace(.sRGB)
        )
        let rightSample = try XCTUnwrap(
            bitmap.colorAt(x: 170, y: 40)?.usingColorSpace(.sRGB)
        )
        XCTAssertGreaterThan(leftSample.redComponent, leftSample.blueComponent * 2)
        XCTAssertGreaterThan(rightSample.blueComponent, rightSample.redComponent * 2)

        let intensity = blur.style.lineWidth
        let radius = max(4, Int((CGFloat(intensity) * 0.85).rounded()))
        let mainProcessed = try XCTUnwrap(ScreenshotPixelProcessor.processedImage(
            source: source.image,
            rect: selection,
            kind: .blur,
            intensity: intensity
        ))
        let fallbackProcessed = try XCTUnwrap(ScreenshotPixelProcessor.processedImage(
            source: source.image,
            rect: selection,
            kind: .blur,
            intensity: intensity,
            forceFallback: true
        ))
        let mainWidth = redTransitionWidth(in: mainProcessed)
        let fallbackWidth = redTransitionWidth(in: fallbackProcessed)
        for width in [mainWidth, fallbackWidth] {
            XCTAssertGreaterThanOrEqual(
                width,
                Int(CGFloat(radius) * 0.65),
                "真实高斯应产生与目标半径成比例的过渡宽度"
            )
            XCTAssertLessThanOrEqual(
                width,
                Int(CGFloat(radius) * 2.8),
                "模糊过渡不应扩散远超目标半径"
            )
        }
        XCTAssertLessThanOrEqual(
            abs(mainWidth - fallbackWidth),
            4,
            "软件 fallback 应与主高斯路径使用同等半径"
        )

        let untouched = try XCTUnwrap(
            bitmap.colorAt(x: 8, y: 40)?.usingColorSpace(.sRGB)
        )
        let sourceBitmap = NSBitmapImageRep(cgImage: source.image)
        let sourceSample = try XCTUnwrap(
            sourceBitmap.colorAt(x: 8, y: 40)?.usingColorSpace(.sRGB)
        )
        XCTAssertEqual(untouched.redComponent, sourceSample.redComponent, accuracy: 0.01)
        XCTAssertEqual(untouched.blueComponent, sourceSample.blueComponent, accuracy: 0.01)
    }

    func testStepSupportsOutlineAndFilledCircleVariants() throws {
        let source = try makeSource(width: 120, height: 80)
        let selection = PixelRect(x: 0, y: 0, width: 120, height: 80)
        var outlined = ScreenshotAnnotation(
            rect: PixelRect(x: 30, y: 20, width: 48, height: 48),
            kind: .step
        )
        outlined.stepNumber = 1
        outlined.style.fillsShape = false
        var filled = outlined
        filled.style.fillsShape = true
        var legacy = outlined
        legacy.style.fillsShape = nil

        let outlineOutput = try ScreenshotAnnotationRenderer.render(
            source: source,
            selection: selection,
            annotations: [outlined]
        )
        let fillOutput = try ScreenshotAnnotationRenderer.render(
            source: source,
            selection: selection,
            annotations: [filled]
        )
        let legacyOutput = try ScreenshotAnnotationRenderer.render(
            source: source,
            selection: selection,
            annotations: [legacy]
        )

        XCTAssertGreaterThan(
            redPixelCount(in: fillOutput),
            redPixelCount(in: outlineOutput)
        )
        XCTAssertEqual(
            redPixelCount(in: fillOutput),
            redPixelCount(in: legacyOutput),
            "旧记录缺少 fillsShape 时必须保持原来的填充圆样式"
        )
        let outlineBitmap = NSBitmapImageRep(cgImage: outlineOutput)
        let circleInterior = try XCTUnwrap(
            outlineBitmap.colorAt(x: 36, y: 44)?.usingColorSpace(.sRGB)
        )
        XCTAssertLessThan(circleInterior.redComponent, 0.3)
    }

    func testRedactionFallbackPreservesColorForMosaicAndBlur() throws {
        let source = try makeTwoColorSplitImage(
            width: 120,
            height: 80,
            left: CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            right: CGColor(red: 0, green: 0.15, blue: 1, alpha: 1)
        )
        let rect = PixelRect(x: 20, y: 15, width: 80, height: 50)

        for kind in [
            ScreenshotAnnotationKind.mosaic,
            .mosaicStroke,
            .blur,
            .mosaicBlur,
        ] {
            let processed = try XCTUnwrap(ScreenshotPixelProcessor.processedImage(
                source: source.image,
                rect: rect,
                kind: kind,
                intensity: 24,
                forceFallback: true
            ))
            XCTAssertEqual(processed.width, rect.width)
            XCTAssertEqual(processed.height, rect.height)
            let bitmap = NSBitmapImageRep(cgImage: processed)
            let left = try XCTUnwrap(
                bitmap.colorAt(x: 8, y: rect.height / 2)?
                    .usingColorSpace(.sRGB)
            )
            let right = try XCTUnwrap(
                bitmap.colorAt(x: rect.width - 8, y: rect.height / 2)?
                    .usingColorSpace(.sRGB)
            )
            XCTAssertGreaterThan(left.redComponent, left.blueComponent, "\(kind)")
            XCTAssertGreaterThan(right.blueComponent, right.redComponent, "\(kind)")
        }
    }

    func testRectangleCornerStyleKeepsRoundedAndSharpModes() throws {
        let rect = PixelRect(x: 10, y: 10, width: 100, height: 60)
        var rounded = ScreenshotAnnotation(rect: rect)
        rounded.style.cornerStyle = .rounded
        var sharp = rounded
        sharp.style.cornerStyle = .sharp

        let viewRect = rect.cgRect
        let roundedPath = ScreenshotAnnotationPath.cgPath(
            for: rounded,
            in: viewRect
        )
        let sharpPath = ScreenshotAnnotationPath.cgPath(
            for: sharp,
            in: viewRect
        )

        XCTAssertFalse(roundedPath.contains(CGPoint(x: viewRect.minX + 1, y: viewRect.minY + 1)))
        XCTAssertTrue(sharpPath.contains(CGPoint(x: viewRect.minX + 1, y: viewRect.minY + 1)))
    }

    @MainActor
    func testCornerStyleChoicesUseVisibleIconsAndKeepAccessibleLabels() throws {
        let toolbar = SelectionToolbarView(
            frame: CGRect(x: 0, y: 0, width: 366, height: 92)
        )
        toolbar.styleControlsEnabled = true
        toolbar.styleKind = .rectangle
        let control = try XCTUnwrap(
            findView(accessibilityLabel: "边角样式", in: toolbar)
                as? NSSegmentedControl
        )

        XCTAssertEqual(control.segmentCount, 2)
        XCTAssertNotNil(control.image(forSegment: 0))
        XCTAssertNotNil(control.image(forSegment: 1))
        XCTAssertEqual(control.toolTip(forSegment: 0), "圆角")
        XCTAssertEqual(control.toolTip(forSegment: 1), "直角")
    }

    @MainActor
    func testStepStyleChoicesUseOutlineAndFilledNumberIcons() throws {
        let toolbar = SelectionToolbarView(
            frame: CGRect(x: 0, y: 0, width: 366, height: 92)
        )
        toolbar.styleControlsEnabled = true
        toolbar.styleKind = .step
        toolbar.style = ScreenshotAnnotationStyle.defaultStyle(for: .step)
        let control = try XCTUnwrap(
            findView(accessibilityLabel: "步骤样式", in: toolbar)
                as? NSSegmentedControl
        )

        XCTAssertFalse(control.isHidden)
        XCTAssertEqual(control.segmentCount, 2)
        XCTAssertNotNil(control.image(forSegment: 0))
        XCTAssertNotNil(control.image(forSegment: 1))
        XCTAssertEqual(control.toolTip(forSegment: 0), "线圈数字")
        XCTAssertEqual(control.toolTip(forSegment: 1), "填充圆数字")
        XCTAssertEqual(control.selectedSegment, 1)

        control.selectedSegment = 0
        XCTAssertTrue(NSApp.sendAction(
            try XCTUnwrap(control.action),
            to: control.target,
            from: control
        ))
        XCTAssertEqual(toolbar.style.fillsShape, false)

        control.selectedSegment = 1
        XCTAssertTrue(NSApp.sendAction(
            try XCTUnwrap(control.action),
            to: control.target,
            from: control
        ))
        XCTAssertEqual(toolbar.style.fillsShape, true)
    }

    @MainActor
    func testPolylineAddsVerticesOnClicksUntilRightClick() throws {
        let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 240, height: 160))
        _ = attachToWindow(view)
        view.sourcePixelSize = try PixelSize(width: 240, height: 160)
        view.setSelection(CGRect(x: 0, y: 0, width: 240, height: 160), notify: false)
        view.setTool(.line)
        view.setDisplayedStyle(ScreenshotAnnotationStyle(
            color: .defaultRed,
            lineWidth: 4,
            lineStyle: .solid
        ))
        var created: ScreenshotAnnotation?
        view.onAnnotationCreated = { created = $0 }

        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: view, at: CGPoint(x: 20, y: 20)))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, in: view, at: CGPoint(x: 20, y: 20)))
        XCTAssertNil(created)

        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: view, at: CGPoint(x: 60, y: 60)))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, in: view, at: CGPoint(x: 60, y: 60)))
        XCTAssertNil(created)

        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: view, at: CGPoint(x: 100, y: 30)))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, in: view, at: CGPoint(x: 100, y: 30)))
        XCTAssertNil(created)

        view.rightMouseDown(with: try mouseEvent(
            .rightMouseDown,
            in: view,
            at: CGPoint(x: 100, y: 30)
        ))

        let annotation = try XCTUnwrap(created)
        XCTAssertEqual(annotation.kind, .line)
        XCTAssertEqual(annotation.points, [
            PixelPoint(x: 20, y: 20),
            PixelPoint(x: 60, y: 60),
            PixelPoint(x: 100, y: 30),
        ])
    }

    func testLineWidthScrollAdjustsWithinKindRange() {
        let range = ScreenshotAnnotationKind.line.lineWidthRange
        XCTAssertEqual(
            ScreenshotLineWidthScroll.adjusted(
                3,
                deltaY: 12,
                precise: true,
                range: range
            ),
            3
        )
        XCTAssertEqual(
            ScreenshotLineWidthScroll.adjusted(
                3,
                deltaY: 1,
                precise: false,
                range: range
            ),
            4
        )
        XCTAssertEqual(
            ScreenshotLineWidthScroll.adjusted(
                3,
                deltaY: -1,
                precise: false,
                range: range
            ),
            2
        )
        XCTAssertEqual(
            ScreenshotLineWidthScroll.adjusted(
                range.upperBound,
                deltaY: 240,
                precise: true,
                range: range
            ),
            range.upperBound
        )
    }

    @MainActor
    func testSelectionEdgesUseHorizontalCursorAndCornersUseDiagonalCursors() {
        for handle in [
            SelectionResizeHandle.top,
            .left,
            .right,
            .bottom,
        ] {
            XCTAssertTrue(handle.cursor === NSCursor.resizeLeftRight)
        }
        XCTAssertFalse(
            SelectionResizeHandle.topLeft.cursor === NSCursor.resizeLeftRight
        )
        XCTAssertFalse(
            SelectionResizeHandle.topRight.cursor === NSCursor.resizeLeftRight
        )
    }

    @MainActor
    func testMosaicToolCombinesEffectAndShapeTabs() throws {
        let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.setSelection(CGRect(x: 0, y: 0, width: 800, height: 600), notify: false)
        view.setTool(.mosaic)

        XCTAssertNil(findButton(titled: L10n.shared.string("马克笔"), in: view))
        XCTAssertNil(findButton(titled: L10n.shared.string("马赛克涂抹"), in: view))
        XCTAssertNil(findButton(titled: L10n.shared.string("模糊"), in: view))
        let effectControl = try XCTUnwrap(
            findView(accessibilityLabel: L10n.shared.string("打码方式"), in: view)
                as? NSSegmentedControl
        )
        let modeControl = try XCTUnwrap(
            findView(accessibilityLabel: L10n.shared.string("打码形状"), in: view)
                as? NSSegmentedControl
        )
        XCTAssertEqual(effectControl.segmentCount, 2)
        XCTAssertEqual(modeControl.segmentCount, 2)
        XCTAssertFalse(effectControl.isHidden)
        XCTAssertFalse(modeControl.isHidden)
        XCTAssertEqual(view.activeAnnotationKind, .mosaic)

        modeControl.selectedSegment = 1
        if let action = modeControl.action {
            NSApp.sendAction(action, to: modeControl.target, from: modeControl)
        }

        XCTAssertEqual(view.activeAnnotationKind, .mosaicStroke)
        XCTAssertEqual(view.activeTool, .mosaic)

        effectControl.selectedSegment = 1
        if let action = effectControl.action {
            NSApp.sendAction(action, to: effectControl.target, from: effectControl)
        }

        XCTAssertEqual(view.activeAnnotationKind, .blur)
        XCTAssertEqual(modeControl.selectedSegment, 0)
        XCTAssertEqual(view.activeTool, .mosaic)

        modeControl.selectedSegment = 1
        if let action = modeControl.action {
            NSApp.sendAction(action, to: modeControl.target, from: modeControl)
        }
        XCTAssertEqual(view.activeAnnotationKind, .mosaicBlur)

        effectControl.selectedSegment = 0
        if let action = effectControl.action {
            NSApp.sendAction(action, to: effectControl.target, from: effectControl)
        }
        XCTAssertEqual(view.activeAnnotationKind, .mosaicStroke)
    }

    @MainActor
    func testSwitchingMosaicModeDoesNotConvertSelectedAnnotation() throws {
        let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.setSelection(CGRect(x: 0, y: 0, width: 800, height: 600), notify: false)
        view.setTool(.objectSelection)
        let annotation = ScreenshotAnnotation(
            rect: PixelRect(x: 40, y: 40, width: 120, height: 80),
            kind: .mosaic
        )
        view.setAnnotations([annotation], selectedID: annotation.id)

        view.setRedactionShape(.stroke)

        XCTAssertEqual(view.annotations.first?.kind, .mosaic)
        XCTAssertNil(view.selectedAnnotationID)
        XCTAssertEqual(view.activeTool, .mosaic)
        XCTAssertEqual(view.activeAnnotationKind, .mosaicStroke)
    }

    func testFreehandExportKeepsTrajectoryOrientation() throws {
        let source = try makeSource(width: 100, height: 60)
        let selection = PixelRect(x: 0, y: 0, width: 100, height: 60)
        let stroke = ScreenshotAnnotation(
            points: [
                PixelPoint(x: 10, y: 10),
                PixelPoint(x: 20, y: 30),
                PixelPoint(x: 90, y: 30),
            ],
            kind: .brush,
            style: ScreenshotAnnotationStyle(
                color: ScreenshotAnnotationColor(red: 1, green: 0, blue: 0, alpha: 1),
                lineWidth: 6,
                lineStyle: .solid
            )
        )
        let image = try ScreenshotAnnotationRenderer.render(
            source: source,
            selection: selection,
            annotations: [stroke]
        )
        let bitmap = NSBitmapImageRep(cgImage: image)
        let lower = try XCTUnwrap(bitmap.colorAt(x: 50, y: 30)?.usingColorSpace(.sRGB))
        let mirrored = try XCTUnwrap(bitmap.colorAt(x: 50, y: 11)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(lower.redComponent, 0.5)
        XCTAssertLessThan(mirrored.redComponent, 0.2)
    }

    @MainActor
    func testBrushPreservesTrajectoryAndSupportsAStationaryDot() throws {
        let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 240, height: 160))
        _ = attachToWindow(view)
        view.sourcePixelSize = try PixelSize(width: 240, height: 160)
        view.setSelection(CGRect(x: 0, y: 0, width: 240, height: 160), notify: false)
        view.setTool(.brush)
        var created: [ScreenshotAnnotation] = []
        view.onAnnotationCreated = { created.append($0) }

        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: view, at: CGPoint(x: 20, y: 20)))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: view, at: CGPoint(x: 35, y: 30)))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: view, at: CGPoint(x: 60, y: 25)))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: view, at: CGPoint(x: 80, y: 60)))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, in: view, at: CGPoint(x: 80, y: 60)))

        let stroke = try XCTUnwrap(created.first)
        XCTAssertEqual(stroke.kind, .brush)
        XCTAssertEqual(stroke.points, [
            PixelPoint(x: 20, y: 20),
            PixelPoint(x: 35, y: 30),
            PixelPoint(x: 60, y: 25),
            PixelPoint(x: 80, y: 60),
        ])
        XCTAssertEqual(stroke.rect, PixelRect(x: 20, y: 20, width: 60, height: 40))

        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: view, at: CGPoint(x: 100, y: 80)))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, in: view, at: CGPoint(x: 100, y: 80)))
        let dot = try XCTUnwrap(created.last)
        XCTAssertEqual(dot.kind, .brush)
        XCTAssertEqual(dot.points, [PixelPoint(x: 100, y: 80)])
    }

    func testBrushRectTransformMovesAndScalesEveryPoint() {
        let annotation = ScreenshotAnnotation(
            brushPoints: [
                PixelPoint(x: 10, y: 20),
                PixelPoint(x: 30, y: 40),
                PixelPoint(x: 50, y: 30),
            ]
        )
        var resized = annotation
        resized.rect = PixelRect(x: 20, y: 10, width: 80, height: 40)

        XCTAssertEqual(resized.points, [
            PixelPoint(x: 20, y: 10),
            PixelPoint(x: 60, y: 50),
            PixelPoint(x: 100, y: 30),
        ])
        XCTAssertEqual(resized.start, resized.points.first)
        XCTAssertEqual(resized.end, resized.points.last)
    }

    func testBrushRendersCompletedStroke() throws {
        let source = try makeSource(width: 100, height: 60)
        let selection = PixelRect(x: 0, y: 0, width: 100, height: 60)
        let stroke = ScreenshotAnnotation(
            brushPoints: [
                PixelPoint(x: 10, y: 10),
                PixelPoint(x: 30, y: 45),
                PixelPoint(x: 75, y: 20),
            ],
            style: ScreenshotAnnotationStyle(
                color: ScreenshotAnnotationColor(red: 1, green: 0, blue: 0, alpha: 1),
                lineWidth: 4,
                lineStyle: .solid
            )
        )
        XCTAssertGreaterThan(
            try renderCount(source: source, selection: selection, annotation: stroke),
            40
        )
    }

    @MainActor
    func testTextEditorCommitsMultilineTextAndDoesNotCommitDuringIMEComposition() throws {
        let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 240, height: 160))
        _ = attachToWindow(view)
        view.sourcePixelSize = try PixelSize(width: 240, height: 160)
        view.setSelection(CGRect(x: 0, y: 0, width: 240, height: 160), notify: false)
        let annotation = ScreenshotAnnotation(
            kind: .text,
            start: PixelPoint(x: 20, y: 20),
            end: PixelPoint(x: 200, y: 100),
            style: ScreenshotAnnotationStyle(
                color: .defaultRed,
                lineWidth: 18,
                lineStyle: .solid
            )
        )
        view.setAnnotations([annotation], selectedID: annotation.id)
        var result: (UUID, String, Bool)?
        view.onTextEditingEnded = { result = ($0, $1, $2) }

        view.beginTextEditing(annotation.id)
        let editor = try XCTUnwrap(findTextView(in: view))
        editor.setMarkedText(
            "ni",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        editor.keyDown(with: try makeKeyEvent(
            characters: "\r",
            keyCode: 36,
            modifiers: [.command]
        ))
        XCTAssertNil(result)

        editor.unmarkText()
        editor.string = "第一行\n第二行"
        editor.didChangeText()
        editor.keyDown(with: try makeKeyEvent(
            characters: "\r",
            keyCode: 36,
            modifiers: [.command]
        ))

        XCTAssertEqual(result?.0, annotation.id)
        XCTAssertEqual(result?.1, "第一行\n第二行")
        XCTAssertEqual(result?.2, true)
        XCTAssertNil(findTextView(in: view))
    }

    @MainActor
    func testTextEditorEscapeCancelsAndRestoresOriginalText() throws {
        let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 240, height: 160))
        _ = attachToWindow(view)
        view.sourcePixelSize = try PixelSize(width: 240, height: 160)
        view.setSelection(CGRect(x: 0, y: 0, width: 240, height: 160), notify: false)
        let annotation = ScreenshotAnnotation(
            kind: .text,
            start: PixelPoint(x: 20, y: 20),
            end: PixelPoint(x: 200, y: 100),
            text: "原文"
        )
        view.setAnnotations([annotation], selectedID: annotation.id)
        var result: (UUID, String, Bool)?
        view.onTextEditingEnded = { result = ($0, $1, $2) }
        view.beginTextEditing(annotation.id)
        let editor = try XCTUnwrap(findTextView(in: view))
        editor.string = "修改"
        editor.didChangeText()

        editor.keyDown(with: try makeKeyEvent(characters: "\u{1b}", keyCode: 53))

        XCTAssertEqual(result?.1, "原文")
        XCTAssertEqual(result?.2, false)
        XCTAssertEqual(view.annotations.first?.text, "原文")
    }

    @MainActor
    func testTextResizeChangesWidthAndKeepsFontSize() throws {
        let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 240, height: 180))
        _ = attachToWindow(view)
        view.sourcePixelSize = try PixelSize(width: 240, height: 180)
        view.setSelection(CGRect(x: 0, y: 0, width: 240, height: 180), notify: false)
        let annotation = ScreenshotAnnotation(
            kind: .text,
            start: PixelPoint(x: 20, y: 20),
            end: PixelPoint(x: 140, y: 60),
            style: ScreenshotAnnotationStyle(
                color: .defaultRed,
                lineWidth: 18,
                lineStyle: .solid
            ),
            text: "缩放"
        )
        view.setAnnotations([annotation], selectedID: annotation.id)
        view.setTool(.objectSelection)
        var changedStyle: ScreenshotAnnotationStyle?
        view.onAnnotationChanged = { _, _, style in changedStyle = style }

        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: view, at: CGPoint(x: 140, y: 40)))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: view, at: CGPoint(x: 165, y: 80)))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, in: view, at: CGPoint(x: 165, y: 80)))

        XCTAssertNil(changedStyle)
        XCTAssertEqual(view.annotations.first?.style.lineWidth, 18)
        let textRect = try XCTUnwrap(view.annotations.first?.rect)
        XCTAssertEqual(textRect.width, 145)
        XCTAssertLessThan(textRect.height, 40)
    }

    @MainActor
    func testShapeResizeIsFreeformAndKeepsStrokeWidth() throws {
        let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 240, height: 180))
        _ = attachToWindow(view)
        view.sourcePixelSize = try PixelSize(width: 240, height: 180)
        view.setSelection(CGRect(x: 0, y: 0, width: 240, height: 180), notify: false)
        let annotation = ScreenshotAnnotation(
            kind: .rectangle,
            start: PixelPoint(x: 20, y: 20),
            end: PixelPoint(x: 120, y: 70),
            style: ScreenshotAnnotationStyle(
                color: .defaultRed,
                lineWidth: 7,
                lineStyle: .solid
            )
        )
        view.setAnnotations([annotation], selectedID: annotation.id)
        view.setTool(.objectSelection)

        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: view, at: CGPoint(x: 120, y: 70)))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: view, at: CGPoint(x: 170, y: 110)))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, in: view, at: CGPoint(x: 170, y: 110)))

        let resized = try XCTUnwrap(view.annotations.first)
        XCTAssertEqual(resized.rect, PixelRect(x: 20, y: 20, width: 150, height: 90))
        XCTAssertEqual(resized.style.lineWidth, 7)
    }

    func testCustomColorPaletteAndHexParser() throws {
        XCTAssertEqual(
            ScreenshotColorPalette.parseHex("#2978F2"),
            ScreenshotAnnotationColor(
                red: 41.0 / 255.0,
                green: 120.0 / 255.0,
                blue: 242.0 / 255.0,
                alpha: 1
            )
        )
        XCTAssertEqual(
            ScreenshotColorPalette.parseHex("f00")?.hexText,
            "#FF0000"
        )
        XCTAssertEqual(ScreenshotColorPalette.color(column: 0, row: 0).hexText.count, 7)
        XCTAssertEqual(ScreenshotColorPalette.rowCount, 8)
        XCTAssertEqual(ScreenshotColorPalette.brightnessLevels.count, 8)
        for column in 0..<ScreenshotColorPalette.columnCount {
            let colors = (0..<ScreenshotColorPalette.rowCount).map {
                ScreenshotColorPalette.color(column: column, row: $0)
            }
            zip(colors, colors.dropFirst()).forEach { lighter, darker in
                XCTAssertGreaterThan(lighter.red, darker.red)
                XCTAssertTrue(
                    [lighter.red, lighter.green, lighter.blue,
                     darker.red, darker.green, darker.blue]
                        .allSatisfy { (0...1).contains($0) }
                )
            }
        }
        XCTAssertGreaterThan(
            ScreenshotColorPalette.color(column: 0, row: 0).red,
            ScreenshotColorPalette.color(column: 0, row: 6).red
        )
    }

    @MainActor
    func testRedactionBoxAndStrokeShowIntensityAdjustments() throws {
        let toolbar = SelectionToolbarView(
            frame: CGRect(x: 0, y: 0, width: 366, height: 92)
        )
        toolbar.styleControlsEnabled = true
        toolbar.styleKind = .mosaic

        XCTAssertTrue(
            try XCTUnwrap(findView(accessibilityLabel: "标注颜色", in: toolbar)).isHidden
        )
        XCTAssertTrue(
            try XCTUnwrap(findView(accessibilityLabel: "线型", in: toolbar)).isHidden
        )
        XCTAssertFalse(
            try XCTUnwrap(findView(accessibilityLabel: "标注参数", in: toolbar)).isHidden
        )

        toolbar.styleKind = .mosaicStroke
        let widthControl = try XCTUnwrap(
            findView(accessibilityLabel: "标注参数", in: toolbar)
        )
        XCTAssertFalse(widthControl.isHidden)
        XCTAssertEqual(
            ScreenshotAnnotationKind.mosaicStroke.lineWidthRange.upperBound,
            60
        )
    }

    @MainActor
    func testAnnotationStyleRowIsSeparatedFromToolRow() throws {
        let toolbar = SelectionToolbarView(
            frame: CGRect(x: 0, y: 0, width: 366, height: 84)
        )
        let separator = try XCTUnwrap(findView(
            identifier: "annotationStyleSeparator",
            in: toolbar
        ))
        XCTAssertTrue(separator.isHidden)

        toolbar.styleKind = .rectangle
        toolbar.styleControlsEnabled = true
        XCTAssertFalse(separator.isHidden)

        toolbar.styleControlsEnabled = false
        XCTAssertTrue(separator.isHidden)
    }

    @MainActor
    func testColorPopoverUsesCustomPaletteAndHexField() throws {
        let controller = ScreenshotColorPopoverViewController(color: .defaultRed)
        _ = controller.view

        XCTAssertNil(findColorWell(in: controller.view))
        let hexField = try XCTUnwrap(findTextField(in: controller.view))
        XCTAssertEqual(hexField.stringValue, "#FF3B30")
        hexField.stringValue = "#2978F2"
        XCTAssertTrue(NSApp.sendAction(
            try XCTUnwrap(hexField.action),
            to: hexField.target,
            from: hexField
        ))
        XCTAssertEqual(controller.color.hexText, "#2978F2")
    }

    @MainActor
    func testSelectingAnnotationToolShowsStyleRowAndUpdatesActiveTool() throws {
        let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 700, height: 400))
        _ = attachToWindow(view)
        view.setSelection(CGRect(x: 40, y: 40, width: 600, height: 300), notify: false)

        let rectangle = try XCTUnwrap(findButton(titled: "矩形", in: view))
        rectangle.performClick(nil)

        XCTAssertEqual(view.activeTool, .rectangle)
        XCTAssertEqual(try XCTUnwrap(findButton(titled: "选区", in: view)).state, .off)
        XCTAssertEqual(try XCTUnwrap(findButton(titled: "选择标注", in: view)).state, .off)
        let swatch = try XCTUnwrap(findView(accessibilityLabel: "标注颜色", in: view) as? NSButton)
        XCTAssertFalse(swatch.isHidden)
        XCTAssertTrue(swatch.title.isEmpty)
        XCTAssertFalse(try XCTUnwrap(findView(
            accessibilityLabel: "线型",
            in: view
        )).isHidden)
    }

    @MainActor
    func testSwitchingDrawingToolsClearsSelectedAnnotation() throws {
        let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.setSelection(CGRect(x: 40, y: 40, width: 600, height: 300), notify: false)
        view.setTool(.arrow)
        let arrow = ScreenshotAnnotation(
            kind: .arrow, start: PixelPoint(x: 60, y: 60), end: PixelPoint(x: 100, y: 80)
        )
        view.setAnnotations([arrow], selectedID: arrow.id)
        let rectangle = try XCTUnwrap(findButton(titled: L10n.shared.string("矩形"), in: view))

        rectangle.performClick(nil)

        XCTAssertEqual(view.activeTool, .rectangle)
        XCTAssertNil(view.selectedAnnotationID)
        XCTAssertEqual(rectangle.state, .on)
    }

    @MainActor
    func testSelectingAnnotationHighlightsItsToolWithoutChangingDrawingMode() throws {
        let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.setSelection(CGRect(x: 40, y: 40, width: 600, height: 300), notify: false)
        view.setTool(.objectSelection)
        let annotation = ScreenshotAnnotation(kind: .arrow, start: PixelPoint(x: 60, y: 60),
                                              end: PixelPoint(x: 100, y: 80))
        view.setAnnotations([annotation], selectedID: annotation.id)
        XCTAssertEqual(view.activeTool, .objectSelection)
        XCTAssertEqual(try XCTUnwrap(findButton(titled: "箭头", in: view)).state, .on)
        XCTAssertEqual(try XCTUnwrap(findButton(titled: "矩形", in: view)).state, .off)
    }

    func testAllNylaiIconsRenderAsTemplateImages() {
        for icon in NylaiIcon.allCases {
            if icon != .stepFilled {
                XCTAssertNotNil(NSImage(named: icon.assetName), icon.rawValue)
            }
            let image = icon.image(pointSize: 14)
            XCTAssertTrue(image.isTemplate, icon.rawValue)
            XCTAssertEqual(image.size, NSSize(width: 14, height: 14), icon.rawValue)
        }
    }

    func testBlurIconUsesASoftSquareEdge() throws {
        let size = NSSize(width: 32, height: 32)
        let image = NSImage(size: size)
        image.lockFocus()
        NylaiIcon.blur.image(pointSize: size.width).draw(
            in: CGRect(origin: .zero, size: size)
        )
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            data: try XCTUnwrap(image.tiffRepresentation)
        ))
        let topEdge = try XCTUnwrap(
            bitmap.colorAt(x: 16, y: 6)?.alphaComponent
        )
        let corner = try XCTUnwrap(
            bitmap.colorAt(x: 6, y: 6)?.alphaComponent
        )
        let outside = try XCTUnwrap(
            bitmap.colorAt(x: 1, y: 1)?.alphaComponent
        )

        XCTAssertGreaterThan(topEdge, corner)
        XCTAssertGreaterThan(topEdge, outside)
        XCTAssertLessThan(outside, 0.05)
    }

    func testSolidAndDashedLineIconsAreHorizontal() throws {
        for icon in [NylaiIcon.solidLine, NylaiIcon.dashedLine] {
            let bounds = try iconInkBounds(icon)
            XCTAssertGreaterThan(
                bounds.width,
                bounds.height * 4,
                "\(icon.rawValue) should render as a horizontal line"
            )
        }
    }

    @MainActor
    func testRemixToolbarIconsRemainDistinctAtRenderedSize() throws {
        let toolbar = SelectionToolbarView(frame: CGRect(x: 0, y: 0, width: 330, height: 78))
        toolbar.styleControlsEnabled = true
        toolbar.styleKind = .arrow
        toolbar.style = ScreenshotAnnotationStyle.defaultStyle(for: .arrow)
        let window = attachToWindow(toolbar)
        defer { window.orderOut(nil) }
        toolbar.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(toolbar.bitmapImageRepForCachingDisplay(in: toolbar.bounds))
        toolbar.cacheDisplay(in: toolbar.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/nylai-remix-toolbar-preview.png"))

        for (first, second) in [
            (NylaiIcon.solidLine, NylaiIcon.dashedLine),
            (NylaiIcon.mosaic, NylaiIcon.rectangle),
            (NylaiIcon.mosaic, NylaiIcon.blur),
            (NylaiIcon.scroll, NylaiIcon.reselect),
        ] {
            let firstData = try renderedPNG(first, pointSize: 15)
            let secondData = try renderedPNG(second, pointSize: 15)
            XCTAssertNotEqual(firstData, secondData, "\(first.rawValue) / \(second.rawValue)")
        }
    }

    func testMosaicIconUsesStrictTwoByTwoDiagonalFill() throws {
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size)
        image.lockFocus()
        NylaiIcon.mosaic.image(pointSize: 24).draw(
            in: CGRect(origin: .zero, size: size)
        )
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            data: try XCTUnwrap(image.tiffRepresentation)
        ))
        func alpha(_ x: Int, _ y: Int) -> CGFloat {
            bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
        }

        let quadrants = [
            alpha(7, 7) > 0.2,
            alpha(17, 7) > 0.2,
            alpha(7, 17) > 0.2,
            alpha(17, 17) > 0.2,
        ]
        XCTAssertTrue(
            quadrants == [true, false, false, true]
                || quadrants == [false, true, true, false],
            "马赛克图标必须只有对角两格填充，当前为 \(quadrants)"
        )
    }

    private func renderedPNG(_ icon: NylaiIcon, pointSize: CGFloat) throws -> Data {
        let size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: size)
        image.lockFocus()
        icon.image(pointSize: pointSize).draw(in: CGRect(origin: .zero, size: size))
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            data: image.tiffRepresentation ?? Data()
        ))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func iconInkBounds(_ icon: NylaiIcon) throws -> CGRect {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        icon.image(pointSize: size.width).draw(
            in: CGRect(origin: .zero, size: size)
        )
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            data: try XCTUnwrap(image.tiffRepresentation)
        ))
        var minX = bitmap.pixelsWide
        var minY = bitmap.pixelsHigh
        var maxX = 0
        var maxY = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.02 else {
                    continue
                }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        XCTAssertLessThan(minX, maxX)
        XCTAssertLessThan(minY, maxY)
        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
    }

    func testMagnifierKeepsAspectRatioAndCompactInsets() {
        let panel = CGRect(
            origin: .zero,
            size: ScreenshotMagnifierLayout.panelSize
        )
        let imageRect = ScreenshotMagnifierLayout.imageRect(in: panel)

        XCTAssertEqual(imageRect.width, imageRect.height)
        XCTAssertEqual(imageRect.minX - panel.minX, ScreenshotMagnifierLayout.inset)
        XCTAssertEqual(imageRect.minY - panel.minY, ScreenshotMagnifierLayout.inset)
    }

    func testMagnifierPanelStaysInsideEveryScreenEdge() {
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let safeBounds = bounds.insetBy(dx: 12, dy: 12)
        let points = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1199, y: 0),
            CGPoint(x: 0, y: 799),
            CGPoint(x: 1199, y: 799),
            CGPoint(x: 600, y: 400),
        ]

        for point in points {
            let panel = ScreenshotMagnifierLayout.panel(for: point, in: bounds)
            XCTAssertEqual(panel.size, ScreenshotMagnifierLayout.panelSize)
            XCTAssertTrue(safeBounds.contains(panel), "\(point) -> \(panel)")
        }
    }

    @MainActor
    func testMagnifierColorsFollowApplicationAppearance() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))

        XCTAssertFalse(NylaiTheme.isDark(light))
        XCTAssertTrue(NylaiTheme.isDark(dark))
        let lightBackground = try XCTUnwrap(
            NylaiTheme.panelBackground(for: light).usingColorSpace(.sRGB)
        )
        let darkBackground = try XCTUnwrap(
            NylaiTheme.panelBackground(for: dark).usingColorSpace(.sRGB)
        )
        XCTAssertGreaterThan(lightBackground.redComponent, darkBackground.redComponent)
        let lightText = try XCTUnwrap(
            NylaiTheme.primaryText(for: light).usingColorSpace(.sRGB)
        )
        let darkText = try XCTUnwrap(
            NylaiTheme.primaryText(for: dark).usingColorSpace(.sRGB)
        )
        XCTAssertLessThan(lightText.redComponent, darkText.redComponent)
    }

    @MainActor
    func testToolbarAnchorKeepsEditingAndOutputControlsInsideViewport() throws {
        let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 900, height: 1_200))
        _ = attachToWindow(view)
        view.sourcePixelSize = try PixelSize(width: 900, height: 1_200)
        view.setSelection(CGRect(x: 0, y: 0, width: 900, height: 1_200), notify: false)
        view.setTool(.objectSelection)
        let viewport = CGRect(x: 40, y: 680, width: 820, height: 320)

        view.toolbarAnchorRect = viewport

        let rectangle = try XCTUnwrap(findButton(titled: "矩形", in: view))
        let copy = try XCTUnwrap(findButton(titled: "复制", in: view))
        XCTAssertTrue(viewport.intersects(rectangle.convert(rectangle.bounds, to: view)))
        XCTAssertTrue(viewport.intersects(copy.convert(copy.bounds, to: view)))
    }

    @MainActor
    func testStepClickUsesConfiguredDiameter() throws {
        let view = ScreenshotOverlayView(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
        _ = attachToWindow(view)
        view.sourcePixelSize = try PixelSize(width: 200, height: 120)
        view.setSelection(CGRect(x: 0, y: 0, width: 200, height: 120), notify: false)
        view.setTool(.step)
        view.setDisplayedStyle(
            ScreenshotAnnotationStyle(
                color: .defaultRed,
                lineWidth: 48,
                lineStyle: .solid
            )
        )
        var created: ScreenshotAnnotation?
        view.onAnnotationCreated = { created = $0 }

        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: view, at: CGPoint(x: 40, y: 30)))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, in: view, at: CGPoint(x: 40, y: 30)))

        XCTAssertEqual(created?.kind, .step)
        XCTAssertEqual(created?.rect, PixelRect(x: 40, y: 30, width: 48, height: 48))
        XCTAssertEqual(created?.style.lineWidth, 48)
    }

    @MainActor
    func testStepNumbersRemainStableAfterDeletion() throws {
        let session = ScreenshotSession()
        session.begin(with: try makeSource(width: 200, height: 120))
        try session.select(pixelRect: PixelRect(x: 0, y: 0, width: 200, height: 120))
        var first = ScreenshotAnnotation(
            kind: .step,
            start: PixelPoint(x: 20, y: 20),
            end: PixelPoint(x: 50, y: 50)
        )
        first.stepNumber = ScreenshotStepNumbering.next(after: session.annotations)
        try session.addAnnotation(first)
        var second = ScreenshotAnnotation(
            kind: .step,
            start: PixelPoint(x: 60, y: 20),
            end: PixelPoint(x: 90, y: 50)
        )
        second.stepNumber = ScreenshotStepNumbering.next(after: session.annotations)
        try session.addAnnotation(second)
        session.deleteAnnotation(first.id)
        let next = ScreenshotStepNumbering.next(after: session.annotations)

        XCTAssertEqual(second.stepNumber, 2)
        XCTAssertEqual(next, 3)
    }

    func testTextAndStepAnnotationsRenderVisiblePixels() throws {
        let source = try makeSource(width: 220, height: 100)
        let selection = PixelRect(x: 0, y: 0, width: 220, height: 100)
        let text = ScreenshotAnnotation(
            kind: .text,
            start: PixelPoint(x: 10, y: 10),
            end: PixelPoint(x: 200, y: 70),
            style: ScreenshotAnnotationStyle(
                color: ScreenshotAnnotationColor(red: 1, green: 0, blue: 0, alpha: 1),
                lineWidth: 18,
                lineStyle: .solid
            ),
            text: "截图文字\nSecond line"
        )
        var step = ScreenshotAnnotation(
            kind: .step,
            start: PixelPoint(x: 180, y: 70),
            end: PixelPoint(x: 210, y: 100)
        )
        step.stepNumber = 1
        let rendered = try ScreenshotAnnotationRenderer.render(
            source: source,
            selection: selection,
            annotations: [text, step]
        )
        let bitmap = NSBitmapImageRep(cgImage: rendered)
        var colored = 0
        var white = 0
        for y in 0..<rendered.height {
            for x in 0..<rendered.width {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    continue
                }
                if color.redComponent > 0.8, color.greenComponent < 0.5 {
                    colored += 1
                }
                if color.redComponent > 0.9,
                   color.greenComponent > 0.9,
                   color.blueComponent > 0.9 {
                    white += 1
                }
            }
        }
        XCTAssertGreaterThan(colored, 100)
        XCTAssertGreaterThan(white, 5)
    }

    func testMosaicChangesSourcePixelsAndDeletingRestoresSource() throws {
        let image = try makeCheckerboardImage(width: 80, height: 60)
        let geometry = try ScreenshotSourceGeometry(
            kind: .window(1),
            globalFrame: CGRect(x: 0, y: 0, width: 80, height: 60),
            pointPixelScale: 1,
            pixelSize: PixelSize(width: 80, height: 60)
        )
        let source = try ScreenshotImageSource(image: image, geometry: geometry)
        let selection = PixelRect(x: 0, y: 0, width: 80, height: 60)
        let region = PixelRect(x: 18, y: 14, width: 38, height: 28)
        let original = try ScreenshotAnnotationRenderer.render(
            source: source,
            selection: selection,
            annotations: []
        )
        let mosaic = ScreenshotAnnotation(
            kind: .mosaic,
            start: PixelPoint(x: region.minX, y: region.minY),
            end: PixelPoint(x: region.maxX, y: region.maxY),
            style: ScreenshotAnnotationStyle(
                color: .defaultRed,
                lineWidth: 12,
                lineStyle: .solid
            )
        )
        let mosaicOutput = try ScreenshotAnnotationRenderer.render(
            source: source,
            selection: selection,
            annotations: [mosaic]
        )
        XCTAssertNotEqual(try pngLikeData(original), try pngLikeData(mosaicOutput))
        XCTAssertLessThan(
            horizontalTransitions(in: mosaicOutput, rect: region),
            horizontalTransitions(in: original, rect: region) / 2
        )

        let movedMosaic = ScreenshotAnnotation(
            kind: .mosaic,
            start: PixelPoint(x: 45, y: 25),
            end: PixelPoint(x: 75, y: 50),
            style: mosaic.style
        )
        let movedOutput = try ScreenshotAnnotationRenderer.render(
            source: source,
            selection: selection,
            annotations: [movedMosaic]
        )
        let movedBitmap = NSBitmapImageRep(cgImage: movedOutput)
        let originalBitmap = NSBitmapImageRep(cgImage: original)
        XCTAssertEqual(
            movedBitmap.colorAt(x: 2, y: 2),
            originalBitmap.colorAt(x: 2, y: 2)
        )
    }

    private func pathContains(
        _ point: CGPoint,
        annotation: ScreenshotAnnotation
    ) -> Bool {
        ScreenshotAnnotationPath.cgPath(for: annotation, in: annotation.rect.cgRect)
            .copy(
                strokingWithWidth: 6,
                lineCap: .round,
                lineJoin: .round,
                miterLimit: 10
            )
            .contains(point)
    }

    private func renderCount(
        source: ScreenshotImageSource,
        selection: PixelRect,
        annotation: ScreenshotAnnotation
    ) throws -> Int {
        let rendered = try ScreenshotAnnotationRenderer.render(
            source: source,
            selection: selection,
            annotations: [annotation]
        )
        let bitmap = NSBitmapImageRep(cgImage: rendered)
        var count = 0
        for y in 0..<rendered.height {
            for x in 0..<rendered.width {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    continue
                }
                if color.redComponent > 0.8,
                   color.redComponent > color.greenComponent * 1.5,
                   color.redComponent > color.blueComponent * 1.5 {
                    count += 1
                }
            }
        }
        return count
    }

    private func makeSource(width: Int, height: Int) throws -> ScreenshotImageSource {
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
        context.setFillColor(CGColor(red: 0.1, green: 0.35, blue: 0.15, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let geometry = try ScreenshotSourceGeometry(
            kind: .window(1),
            globalFrame: CGRect(x: 0, y: 0, width: width, height: height),
            pointPixelScale: 1,
            pixelSize: PixelSize(width: width, height: height)
        )
        return try ScreenshotImageSource(image: image, geometry: geometry)
    }

    private func makeCheckerboardImage(width: Int, height: Int) throws -> CGImage {
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
        for y in 0..<height {
            for x in 0..<width {
                context.setFillColor(
                    (x + y).isMultiple(of: 2)
                        ? CGColor(red: 1, green: 0, blue: 0, alpha: 1)
                        : CGColor(red: 0, green: 0.2, blue: 1, alpha: 1)
                )
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func makeTwoColorSplitImage(
        width: Int,
        height: Int,
        left: CGColor,
        right: CGColor
    ) throws -> ScreenshotImageSource {
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
        context.setFillColor(left)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(right)
        context.fill(CGRect(
            x: width / 2,
            y: 0,
            width: width - width / 2,
            height: height
        ))
        let image = try XCTUnwrap(context.makeImage())
        let geometry = try ScreenshotSourceGeometry(
            kind: .window(1),
            globalFrame: CGRect(x: 0, y: 0, width: width, height: height),
            pointPixelScale: 1,
            pixelSize: PixelSize(width: width, height: height)
        )
        return try ScreenshotImageSource(image: image, geometry: geometry)
    }

    private func redConnectedComponentCount(in image: CGImage) -> Int {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let width = image.width
        let height = image.height
        var visited = Array(repeating: false, count: width * height)
        var components = 0

        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                guard !visited[index],
                      isRedAnnotationPixel(bitmap.colorAt(x: x, y: y)) else {
                    continue
                }
                components += 1
                var queue = [index]
                visited[index] = true
                var cursor = 0
                while cursor < queue.count {
                    let current = queue[cursor]
                    cursor += 1
                    let currentX = current % width
                    let currentY = current / width
                    for deltaY in -1...1 {
                        for deltaX in -1...1 where deltaX != 0 || deltaY != 0 {
                            let nextX = currentX + deltaX
                            let nextY = currentY + deltaY
                            guard nextX >= 0, nextX < width,
                                  nextY >= 0, nextY < height else {
                                continue
                            }
                            let next = nextY * width + nextX
                            guard !visited[next],
                                  isRedAnnotationPixel(
                                      bitmap.colorAt(x: nextX, y: nextY)
                                  ) else {
                                continue
                            }
                            visited[next] = true
                            queue.append(next)
                        }
                    }
                }
            }
        }
        return components
    }

    private func isRedAnnotationPixel(_ color: NSColor?) -> Bool {
        guard let color = color?.usingColorSpace(.sRGB) else { return false }
        return color.alphaComponent > 0.5
            && color.redComponent > 0.65
            && color.redComponent > color.greenComponent * 1.8
            && color.redComponent > color.blueComponent * 1.8
    }

    private func redPixelCount(in image: CGImage) -> Int {
        let bitmap = NSBitmapImageRep(cgImage: image)
        var count = 0
        for y in 0..<image.height {
            for x in 0..<image.width where isRedAnnotationPixel(
                bitmap.colorAt(x: x, y: y)
            ) {
                count += 1
            }
        }
        return count
    }

    private func redTransitionWidth(in image: CGImage) -> Int {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let transition = (0..<image.width).filter { x in
            guard let red = bitmap.colorAt(x: x, y: image.height / 2)?
                .usingColorSpace(.sRGB)?.redComponent else {
                return false
            }
            return red > 0.2 && red < 0.8
        }
        guard let first = transition.first, let last = transition.last else {
            return 0
        }
        return last - first + 1
    }

    private func uniqueColors(in image: CGImage, rect: PixelRect) -> Int {
        let bitmap = NSBitmapImageRep(cgImage: image)
        var colors = Set<String>()
        for y in rect.minY..<min(rect.maxY, image.height) {
            for x in rect.minX..<min(rect.maxX, image.width) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    continue
                }
                colors.insert(String(
                    format: "%02x%02x%02x",
                    Int(color.redComponent * 255),
                    Int(color.greenComponent * 255),
                    Int(color.blueComponent * 255)
                ))
            }
        }
        return colors.count
    }

    private func horizontalTransitions(in image: CGImage, rect: PixelRect) -> Int {
        let bitmap = NSBitmapImageRep(cgImage: image)
        var transitions = 0
        for y in rect.minY..<min(rect.maxY, image.height) {
            var previous: NSColor?
            for x in rect.minX..<min(rect.maxX, image.width) {
                let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                if let previous, let color,
                   abs(previous.redComponent - color.redComponent) > 0.2 {
                    transitions += 1
                }
                previous = color
            }
        }
        return transitions
    }

    private func pngLikeData(_ image: CGImage) throws -> Data {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    @MainActor
    private func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView {
            return textView
        }
        for subview in view.subviews {
            if let textView = findTextView(in: subview) {
                return textView
            }
        }
        return nil
    }

    @MainActor
    private func findColorWell(in view: NSView) -> NSColorWell? {
        if let colorWell = view as? NSColorWell {
            return colorWell
        }
        for subview in view.subviews {
            if let colorWell = findColorWell(in: subview) {
                return colorWell
            }
        }
        return nil
    }

    @MainActor
    private func findTextField(in view: NSView) -> NSTextField? {
        if let textField = view as? NSTextField {
            return textField
        }
        for subview in view.subviews {
            if let textField = findTextField(in: subview) {
                return textField
            }
        }
        return nil
    }

    @MainActor
    private func findButton(titled title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title {
            return button
        }
        for subview in view.subviews {
            if let button = findButton(titled: title, in: subview) {
                return button
            }
        }
        return nil
    }

    @MainActor
    private func findView(accessibilityLabel: String, in view: NSView) -> NSView? {
        if view.accessibilityLabel() == accessibilityLabel {
            return view
        }
        for subview in view.subviews {
            if let match = findView(accessibilityLabel: accessibilityLabel, in: subview) {
                return match
            }
        }
        return nil
    }

    @MainActor
    private func findView(identifier: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == identifier {
            return view
        }
        for subview in view.subviews {
            if let match = findView(identifier: identifier, in: subview) {
                return match
            }
        }
        return nil
    }

    private func makeKeyEvent(
        characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters.lowercased(),
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    @MainActor
    private func attachToWindow(_ view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        return window
    }

    @MainActor
    private func mouseEvent(
        _ type: NSEvent.EventType,
        in view: NSView,
        at viewPoint: CGPoint,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: CGPoint(x: viewPoint.x, y: view.bounds.height - viewPoint.y),
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }
}
