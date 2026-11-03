import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import XCTest
@testable import nylai

final class ScreenshotTests: XCTestCase {
    @MainActor
    func testSuccessfulCaptureDoesNotRequestPermission() async throws {
        var requestCount = 0
        let recovery = ScreenCapturePermissionRecovery(
            isAccessGranted: { false },
            requestAccess: {
                requestCount += 1
                return true
            }
        )

        let value = try await recovery.perform { 42 }

        XCTAssertEqual(value, 42)
        XCTAssertEqual(requestCount, 0)
    }

    @MainActor
    func testPermissionFailureRequestsAccessAndRetriesOnce() async throws {
        var requestCount = 0
        var operationCount = 0
        let recovery = ScreenCapturePermissionRecovery(
            isAccessGranted: { false },
            requestAccess: {
                requestCount += 1
                return true
            }
        )

        let value = try await recovery.perform {
            operationCount += 1
            if operationCount == 1 {
                throw NSError(
                    domain: SCStreamErrorDomain,
                    code: SCStreamError.Code.userDeclined.rawValue
                )
            }
            return 42
        }

        XCTAssertEqual(value, 42)
        XCTAssertEqual(operationCount, 2)
        XCTAssertEqual(requestCount, 1)
    }

    @MainActor
    func testDeniedPermissionStopsWithoutRetryingCapture() async {
        var requestCount = 0
        var operationCount = 0
        let recovery = ScreenCapturePermissionRecovery(
            isAccessGranted: { false },
            requestAccess: {
                requestCount += 1
                return false
            }
        )

        do {
            _ = try await recovery.perform {
                operationCount += 1
                throw NSError(
                    domain: SCStreamErrorDomain,
                    code: SCStreamError.Code.userDeclined.rawValue
                )
            }
            XCTFail("拒绝权限后不应返回结果")
        } catch {
            XCTAssertEqual(error as? ScreenshotError, .permissionRequired)
        }

        XCTAssertEqual(operationCount, 1)
        XCTAssertEqual(requestCount, 1)
    }

    @MainActor
    func testGrantedButStalePermissionRequiresRestartWithoutRequestingAgain() async {
        var requestCount = 0
        var operationCount = 0
        let recovery = ScreenCapturePermissionRecovery(
            isAccessGranted: { true },
            requestAccess: {
                requestCount += 1
                return true
            }
        )

        do {
            _ = try await recovery.perform {
                operationCount += 1
                throw NSError(
                    domain: SCStreamErrorDomain,
                    code: SCStreamError.Code.userDeclined.rawValue
                )
            }
            XCTFail("权限缓存未生效时不应返回结果")
        } catch {
            XCTAssertEqual(error as? ScreenshotError, .permissionRestartRequired)
        }

        XCTAssertEqual(operationCount, 1)
        XCTAssertEqual(requestCount, 0)
    }

    @MainActor
    func testNewlyGrantedPermissionStillFailsRequiresRestart() async {
        var requestCount = 0
        var operationCount = 0
        var granted = false
        let recovery = ScreenCapturePermissionRecovery(
            isAccessGranted: { granted },
            requestAccess: {
                requestCount += 1
                granted = true
                return true
            }
        )

        do {
            _ = try await recovery.perform {
                operationCount += 1
                throw NSError(
                    domain: SCStreamErrorDomain,
                    code: SCStreamError.Code.userDeclined.rawValue
                )
            }
            XCTFail("授权后当前进程仍失败时应要求重启")
        } catch {
            XCTAssertEqual(error as? ScreenshotError, .permissionRestartRequired)
        }

        XCTAssertEqual(operationCount, 2)
        XCTAssertEqual(requestCount, 1)
    }

    @MainActor
    func testNonPermissionFailureDoesNotRequestAccess() async {
        var requestCount = 0
        let recovery = ScreenCapturePermissionRecovery(
            isAccessGranted: { false },
            requestAccess: {
                requestCount += 1
                return true
            }
        )

        do {
            _ = try await recovery.perform {
                throw ScreenshotError.displayUnavailable
            }
            XCTFail("非权限错误不应被当作授权失败")
        } catch {
            XCTAssertEqual(error as? ScreenshotError, .displayUnavailable)
        }

        XCTAssertEqual(requestCount, 0)
    }

    func testPNGFilePreservesPixelDimensionsAndCanBeDecoded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("capture.png")
        let image = try makeImage()
        try await PNGImageWriter().write(image, to: url)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, image.width)
        XCTAssertEqual(decoded.height, image.height)
    }

    func testPNGWriteToMissingDirectoryFailsWithoutCreatingAFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("capture.png")
        do {
            try await PNGImageWriter().write(try makeImage(), to: url)
            XCTFail("不存在的目录不应保存成功")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }
}

private func makeImage() throws -> CGImage {
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try XCTUnwrap(CGContext(
        data: nil, width: 32, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
    return try XCTUnwrap(context.makeImage())
}
