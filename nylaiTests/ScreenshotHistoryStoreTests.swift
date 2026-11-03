import AppKit
import XCTest
@testable import nylai

@MainActor
final class ScreenshotHistoryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nylai-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    func testAddsAtMostFiftyAndEvictsOldestFiles() throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let files = TestHistoryFileManager()
        let store = ScreenshotHistoryStore(
            directory: directory,
            fileManager: files,
            now: {
                defer { now = now.addingTimeInterval(1) }
                return now
            }
        )

        for index in 0..<51 {
            try store.add(try makeImage(width: 20 + index, height: 10 + index))
        }

        XCTAssertEqual(store.records.count, ScreenshotHistoryStore.maximumRecordCount)
        XCTAssertEqual(store.records.first?.width, 70)
        XCTAssertEqual(store.records.last?.width, 21)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("\(store.records[0].id)-missing.png").path
        ))
        let filesInDirectory = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(filesInDirectory.count, 101)
    }

    func testReloadRestoresIndexAndLoadsFiles() throws {
        let store = ScreenshotHistoryStore(directory: directory)
        let record = try XCTUnwrap(try store.add(try makeImage(width: 80, height: 50)))

        let reloaded = ScreenshotHistoryStore(directory: directory)

        XCTAssertEqual(reloaded.records, [record])
        XCTAssertNil(reloaded.loadError)
        XCTAssertNotNil(reloaded.image(for: record))
        XCTAssertNotNil(reloaded.thumbnail(for: record))
    }

    func testCorruptIndexIsReportedAndPreserved() throws {
        let indexURL = directory.appendingPathComponent("index.json")
        try Data("not-json".utf8).write(to: indexURL)

        let store = ScreenshotHistoryStore(directory: directory)

        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNotNil(store.loadError)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("index.corrupt-") })
    }

    func testImageWriteFailureLeavesNoRecordOrPartialFiles() throws {
        let files = TestHistoryFileManager()
        files.failImageWrites = true
        let store = ScreenshotHistoryStore(directory: directory, fileManager: files)

        XCTAssertThrowsError(try store.add(try makeImage(width: 30, height: 20)))

        XCTAssertTrue(store.records.isEmpty)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testIndexWriteFailureRollsBackImageAndKeepsExistingRecord() throws {
        let files = TestHistoryFileManager()
        let store = ScreenshotHistoryStore(directory: directory, fileManager: files)
        let existing = try XCTUnwrap(try store.add(try makeImage(width: 30, height: 20)))
        files.failIndexWrites = true

        XCTAssertThrowsError(try store.add(try makeImage(width: 40, height: 30))) { error in
            XCTAssertEqual(error as? ScreenshotHistoryStoreError, .indexWriteFailed)
        }

        XCTAssertEqual(store.records, [existing])
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(remaining.count, 3)
    }

    func testDeleteAndClearRemoveOnlyManagedFiles() throws {
        let store = ScreenshotHistoryStore(directory: directory)
        let first = try XCTUnwrap(try store.add(try makeImage(width: 30, height: 20)))
        let second = try XCTUnwrap(try store.add(try makeImage(width: 40, height: 30)))
        let external = directory.appendingPathComponent("user-file.png")
        try Data("external".utf8).write(to: external)

        try store.delete(first)
        XCTAssertEqual(store.records, [second])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(first.imageFileName).path
        ))

        try store.clear()
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.json").path))
    }

    func testCorruptIndexCannotReadOrDeleteFilesOutsideManagedDirectory() throws {
        let external = directory.deletingLastPathComponent()
            .appendingPathComponent("nylai-history-outside-\(UUID().uuidString).png")
        try Data("outside".utf8).write(to: external)
        defer { try? FileManager.default.removeItem(at: external) }
        let unsafeRecord = ScreenshotHistoryRecord(
            id: UUID(),
            imageFileName: "../\(external.lastPathComponent)",
            thumbnailFileName: external.path,
            createdAt: Date(),
            width: 1,
            height: 1
        )
        let index = TestScreenshotHistoryIndex(version: 1, records: [unsafeRecord])
        try JSONEncoder().encode(index)
            .write(to: directory.appendingPathComponent("index.json"))
        let store = ScreenshotHistoryStore(directory: directory)

        XCTAssertEqual(store.records, [unsafeRecord])
        XCTAssertNil(store.image(for: unsafeRecord))
        XCTAssertNil(store.thumbnail(for: unsafeRecord))
        try store.delete(unsafeRecord)
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
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
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}

private struct TestScreenshotHistoryIndex: Codable {
    let version: Int
    let records: [ScreenshotHistoryRecord]
}

private final class TestHistoryFileManager: ScreenshotHistoryFileManaging {
    private let fileManager = FileManager.default
    var failImageWrites = false
    var failIndexWrites = false

    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates
        )
    }

    func fileExists(atPath path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }

    func contents(atPath path: String) -> Data? {
        fileManager.contents(atPath: path)
    }

    func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        if failIndexWrites, url.lastPathComponent == "index.json" {
            throw CocoaError(.fileWriteUnknown)
        }
        if failImageWrites, url.pathExtension == "png" {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: options)
    }

    func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }
}
