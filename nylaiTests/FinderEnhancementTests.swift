import Foundation
import AppKit
import XCTest
@testable import nylai

final class FinderEnhancementTests: XCTestCase {
    @MainActor
    func testFinderProxyMenuItemDoesNotNeedRepresentedObject() throws {
        let store = FinderMenuActionStore()
        let firstURL = makeURL(action: "copy-path", target: URL(fileURLWithPath: "/tmp/first.txt"))
        let secondURL = makeURL(action: "copy-path", target: URL(fileURLWithPath: "/tmp/second.txt"))
        let tag = store.register(firstURL)
        let proxyItem = NSMenuItem(title: "Copy Path", action: nil, keyEquivalent: "")
        proxyItem.tag = tag
        _ = store.register(secondURL)

        XCTAssertNil(proxyItem.representedObject)
        let action = try XCTUnwrap(store.action(for: proxyItem))
        XCTAssertEqual(try XCTUnwrap(FinderEnhancementRequest(url: action)).target.path, "/tmp/first.txt")
        XCTAssertNil(store.action(for: NSMenuItem()))
    }
    func testRequestPreservesRightClickTargetWithSpecialCharacters() throws {
        let target = URL(fileURLWithPath: "/tmp/中文 & 'quoted'\nfile.txt")
        let request = try XCTUnwrap(FinderEnhancementRequest(url: makeURL(action: "copy-path", target: target)))
        XCTAssertEqual(request.action, .copyPath)
        XCTAssertEqual(request.target.path, target.path)
        XCTAssertNil(FinderEnhancementRequest(url: URL(string: "nylai://finder/execute?target=file:///tmp")!))
        XCTAssertNil(FinderEnhancementRequest(url: makeURL(action: "copy-path", target: URL(string: "https://example.com")!)))
    }

    func testMultipleSelectionCapturesPositionAndRejectsInvalidCoordinates() throws {
        var components = try XCTUnwrap(URLComponents(
            url: makeURL(action: "copy-path", target: URL(fileURLWithPath: "/tmp")),
            resolvingAgainstBaseURL: false
        ))
        let paths = ["file:///tmp/first.txt", "file:///tmp/second.txt"]
        let selection = try JSONEncoder().encode(paths).base64EncodedString()
        components.queryItems?.append(contentsOf: [
            URLQueryItem(name: "selection", value: selection),
            URLQueryItem(name: "point", value: "500,700"),
            URLQueryItem(name: "createdAt", value: "123"),
        ])
        let request = try XCTUnwrap(FinderEnhancementRequest(url: try XCTUnwrap(components.url)))
        XCTAssertEqual(request.selection.map(\.path), ["/tmp/first.txt", "/tmp/second.txt"])
        XCTAssertEqual(request.clickPoint, CGPoint(x: 500, y: 700))
        XCTAssertEqual(request.menuCreatedAt, 123)
        components.queryItems?[3].value = "nan,700"
        XCTAssertNil(FinderEnhancementRequest(url: try XCTUnwrap(components.url)))
    }

    func testFolderAndFileResolveToCorrectTerminalDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try FinderEnhancementRequest.createFile(named: "hello.txt", in: root)
        let folderRequest = try XCTUnwrap(FinderEnhancementRequest(url: makeURL(action: "terminal", target: root)))
        let fileRequest = try XCTUnwrap(FinderEnhancementRequest(url: makeURL(action: "terminal", target: file)))
        XCTAssertEqual(try folderRequest.directory().path, root.path)
        XCTAssertEqual(try fileRequest.directory().path, root.path)
    }

    func testNewFileNeverOverwritesOrEscapesDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("keep.txt")
        try Data("original".utf8).write(to: existing)
        XCTAssertThrowsError(try FinderEnhancementRequest.createFile(named: "keep.txt", in: root))
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "original")
        for invalid in ["", ".", "..", "../escape", "/tmp/escape", "bad:name"] {
            XCTAssertThrowsError(try FinderEnhancementRequest.createFile(named: invalid, in: root))
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: try FinderEnhancementRequest.createFile(named: "中文 空格.md", in: root).path
        ))
    }

    func testUntitledFilesAreCreatedImmediatelyWithUniqueNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try FinderEnhancementRequest.createUntitledFile(in: root, name: "未命名.txt")
        try Data("keep".utf8).write(to: first)
        let second = try FinderEnhancementRequest.createUntitledFile(in: root, name: "未命名.txt")
        XCTAssertEqual(first.lastPathComponent, "未命名.txt")
        XCTAssertEqual(second.lastPathComponent, "未命名 2.txt")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "keep")
        XCTAssertEqual(try Data(contentsOf: second), Data())
    }

    func testContainerContextIsCapturedAndUnknownContextsAreRejected() throws {
        var components = try XCTUnwrap(URLComponents(
            url: makeURL(action: "copy-path", target: URL(fileURLWithPath: "/tmp")), resolvingAgainstBaseURL: false
        ))
        components.queryItems?[1].value = "container"
        XCTAssertTrue(try XCTUnwrap(FinderEnhancementRequest(url: try XCTUnwrap(components.url))).isContainer)
        components.queryItems?[1].value = "unknown"
        XCTAssertNil(FinderEnhancementRequest(url: try XCTUnwrap(components.url)))
    }

    private func makeURL(action: String, target: URL) -> URL {
        var components = URLComponents()
        components.scheme = "nylai"
        components.host = "finder"
        components.path = "/" + action
        components.queryItems = [
            URLQueryItem(name: "target", value: target.absoluteString),
            URLQueryItem(name: "context", value: "item"),
        ]
        return components.url!
    }
}
