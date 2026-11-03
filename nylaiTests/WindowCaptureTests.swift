import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import nylai

final class WindowCaptureTests: XCTestCase {
    func testFrontToBackOrderingExcludesOwnProcessAndNonZeroLayers() throws {
        let ids = ScreenCaptureService.frontToBackWindowIDs(
            excludingProcessID: ProcessInfo.processInfo.processIdentifier
        )
        let uniqued = ids.reduce(into: [CGWindowID]()) { result, id in
            if result.last != id {
                result.append(id)
            }
        }
        XCTAssertEqual(ids, uniqued)
    }

    func testCoreGraphicsWindowFrameConvertsToAppKitCoordinates() throws {
        let spaces = [
            ScreenCaptureService.DisplayCoordinateSpace(
                coreGraphicsBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                appKitFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
            ),
            ScreenCaptureService.DisplayCoordinateSpace(
                coreGraphicsBounds: CGRect(x: 0, y: 1080, width: 1920, height: 1080),
                appKitFrame: CGRect(x: 0, y: -1080, width: 1920, height: 1080)
            ),
        ]

        XCTAssertEqual(
            ScreenCaptureService.appKitWindowFrame(
                fromCoreGraphicsFrame: CGRect(x: 180, y: 428, width: 560, height: 392),
                displaySpaces: spaces
            ),
            CGRect(x: 180, y: 260, width: 560, height: 392)
        )
        XCTAssertEqual(
            ScreenCaptureService.appKitWindowFrame(
                fromCoreGraphicsFrame: CGRect(x: 100, y: 1200, width: 500, height: 300),
                displaySpaces: spaces
            ),
            CGRect(x: 100, y: -420, width: 500, height: 300)
        )
    }

    func testAppKitPointConvertsToCoreGraphicsForPrimaryAndStackedDisplay() throws {
        let spaces = [
            ScreenCaptureService.DisplayCoordinateSpace(
                coreGraphicsBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                appKitFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
            ),
            ScreenCaptureService.DisplayCoordinateSpace(
                coreGraphicsBounds: CGRect(x: 0, y: 1080, width: 1920, height: 1080),
                appKitFrame: CGRect(x: 0, y: -1080, width: 1920, height: 1080)
            ),
        ]

        XCTAssertEqual(
            ScreenCaptureService.coreGraphicsPoint(
                fromAppKitPoint: CGPoint(x: 36, y: 1080),
                displaySpaces: spaces
            ),
            CGPoint(x: 36, y: 0)
        )
        XCTAssertEqual(
            ScreenCaptureService.coreGraphicsPoint(
                fromAppKitPoint: CGPoint(x: 100, y: -420),
                displaySpaces: spaces
            ),
            CGPoint(x: 100, y: 1500)
        )
        XCTAssertNil(ScreenCaptureService.coreGraphicsPoint(
            fromAppKitPoint: CGPoint(x: -20, y: 500),
            displaySpaces: spaces
        ))
    }

    @MainActor
    func testManualIndependentWindowCapture() async throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: "/tmp/nylai-c01-opt-in"),
            "仅在显式人工验证时捕获真实窗口"
        )
        let target = makeWindow(
            frame: NSRect(x: 180, y: 260, width: 560, height: 360),
            color: NSColor.systemRed.withAlphaComponent(0.88),
            text: "TARGET WINDOW\n仅应出现红色窗口"
        )
        let occluder = makeWindow(
            frame: NSRect(x: 410, y: 170, width: 560, height: 360),
            color: NSColor.systemBlue.withAlphaComponent(0.95),
            text: "OCCLUDER\n不得进入目标截图"
        )
        target.orderFront(nil)
        occluder.orderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(350))
        defer {
            target.close()
            occluder.close()
        }

        let service = ScreenCaptureService(
            requestAccess: { CGPreflightScreenCaptureAccess() }
        )
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("测试宿主尚未获得屏幕录制权限；已用独立验证程序确认独立窗口捕获结果")
        }
        let image = try await service.captureWindow(CGWindowID(target.windowNumber))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("nylai-c01-target.png")
        try await PNGImageWriter().write(image, to: output)
        print("C01_CAPTURE_OUTPUT=\(output.path)")
        print("C01_CAPTURE_SIZE=\(image.width)x\(image.height)")

        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)
    }

    @MainActor
    private func makeWindow(frame: NSRect, color: NSColor, text: String) -> NSWindow {
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = text.components(separatedBy: "\n").first ?? "C-01"
        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = color.cgColor

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 30, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 24, y: 80, width: frame.width - 48, height: 100)
        content.addSubview(label)
        window.contentView = content
        return window
    }
}
