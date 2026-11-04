import AppKit
import CryptoKit
import SwiftUI
import XCTest
@testable import nylai

@MainActor
final class ClipboardTests: XCTestCase {
    func testHistoryPanelReopensWithItsRecordsAndClosesAgain() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.remove() }
        let store = try XCTUnwrap(fixture.store)
        let record = try XCTUnwrap(store.add(ClipboardCapture(
            content: .text("剪贴板回归测试"), sourceBundleIdentifier: nil, sourceName: nil,
            contentHash: try XCTUnwrap(ClipboardContentIdentifier.text("剪贴板回归测试"))
        )))
        let controller = ClipboardPanelController(store: store)
        defer { controller.close() }
        controller.present()
        let panel = try XCTUnwrap(controller.window)
        let host = try XCTUnwrap(panel.contentView as? NSHostingView<ClipboardPanelView>)
        XCTAssertEqual(host.rootView.model.visibleRecords.map(\.id), [record.id])
        host.rootView.model.onClose()
        try await Task.sleep(for: .milliseconds(230))
        XCTAssertFalse(panel.isVisible)
        controller.present()
        XCTAssertTrue(controller.window === panel)
        let reopened = try XCTUnwrap(panel.contentView as? NSHostingView<ClipboardPanelView>)
        XCTAssertEqual(reopened.rootView.model.visibleRecords.map(\.id), [record.id])
        try await Task.sleep(for: .milliseconds(260))
        controller.toggle()
        let deadline = ContinuousClock.now + .seconds(1)
        while panel.isVisible && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(panel.isVisible)
    }

    func testStoreDeduplicatesTextUpdatesTimeAndKeepsPinnedOrder() throws {
        let fixture = try ClipboardFixture()
        defer { fixture.remove() }
        let store = try XCTUnwrap(fixture.store)
        fixture.now = Date(timeIntervalSince1970: 100)
        let firstHash = try XCTUnwrap(ClipboardContentIdentifier.text("hello"))
        let first = try XCTUnwrap(store.add(ClipboardCapture(
            content: .text("hello"),
            sourceBundleIdentifier: "com.example.Editor",
            sourceName: "Editor",
            contentHash: firstHash
        )))
        try store.setPinned(true, id: first.id)
        let pinnedAt = try XCTUnwrap(store.index.records.first?.pinnedAt)

        fixture.now = Date(timeIntervalSince1970: 200)
        let secondHash = try XCTUnwrap(ClipboardContentIdentifier.text("world"))
        let second = try XCTUnwrap(store.add(ClipboardCapture(
            content: .text("world"),
            sourceBundleIdentifier: "com.example.Browser",
            sourceName: "Browser",
            contentHash: secondHash
        )))
        fixture.now = Date(timeIntervalSince1970: 300)
        let duplicate = try XCTUnwrap(store.add(ClipboardCapture(
            content: .text("hello"),
            sourceBundleIdentifier: "com.example.Terminal",
            sourceName: "Terminal",
            contentHash: firstHash
        )))

        XCTAssertEqual(store.index.records.count, 2)
        XCTAssertEqual(duplicate.id, first.id)
        XCTAssertEqual(duplicate.pinnedAt, pinnedAt)
        XCTAssertEqual(duplicate.sourceName, "Terminal")
        XCTAssertEqual(store.pinnedRecords.map(\.id), [first.id])
        XCTAssertEqual(store.ordinaryRecords.map(\.id), [second.id])
        XCTAssertEqual(store.text(for: duplicate), "hello")
    }

    func testMaximumAndRetentionOnlyRemoveOrdinaryRecords() throws {
        let fixture = try ClipboardFixture()
        defer { fixture.remove() }
        let store = try XCTUnwrap(fixture.store)
        for index in 0..<5 {
            fixture.now = Date(timeIntervalSince1970: Double(index))
            let text = "item-\(index)"
            _ = try store.add(ClipboardCapture(
                content: .text(text),
                sourceBundleIdentifier: nil,
                sourceName: nil,
                contentHash: try XCTUnwrap(ClipboardContentIdentifier.text(text))
            ))
        }
        let pinned = try XCTUnwrap(store.ordinaryRecords.first)
        try store.setPinned(true, id: pinned.id)

        var settings = store.settings
        settings.maximumItems = 2
        try store.updateSettings(settings)
        XCTAssertEqual(store.pinnedRecords.count, 1)
        XCTAssertEqual(store.ordinaryRecords.count, 2)

        settings.retentionEnabled = true
        settings.retentionDays = 1
        fixture.now = Date(timeIntervalSince1970: 3 * 86_400)
        try store.updateSettings(settings)
        XCTAssertEqual(store.pinnedRecords.count, 1)
        XCTAssertTrue(store.ordinaryRecords.isEmpty)
        XCTAssertNotNil(store.text(for: try XCTUnwrap(store.pinnedRecords.first)))
    }

    func testDefaultMaximumEvictsOldestAtTwoHundredAndFirst() throws {
        let fixture = try ClipboardFixture()
        defer { fixture.remove() }
        let store = try XCTUnwrap(fixture.store)
        XCTAssertEqual(store.settings.maximumItems, 200)

        for index in 0...200 {
            fixture.now = Date(timeIntervalSince1970: Double(index))
            _ = try store.add(ClipboardCapture(
                content: .text("item-\(index)"),
                sourceBundleIdentifier: nil,
                sourceName: nil,
                contentHash: try XCTUnwrap(ClipboardContentIdentifier.text("item-\(index)"))
            ))
        }

        XCTAssertEqual(store.ordinaryRecords.count, 200)
        XCTAssertEqual(store.ordinaryRecords.last?.copiedAt, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(store.ordinaryRecords.first?.copiedAt, Date(timeIntervalSince1970: 200))
        XCTAssertFalse(store.index.records.contains {
            $0.contentHash == ClipboardContentIdentifier.text("item-0")
        })
    }

    func testPinnedRecordsDoNotConsumeOrdinaryLimit() throws {
        let fixture = try ClipboardFixture()
        defer { fixture.remove() }
        let store = try XCTUnwrap(fixture.store)
        var settings = store.settings
        settings.maximumItems = 2
        try store.updateSettings(settings)

        fixture.now = Date(timeIntervalSince1970: 0)
        let oldest = try XCTUnwrap(addText("oldest", fixture: fixture, store: store))
        try store.setPinned(true, id: oldest.id)
        fixture.now = Date(timeIntervalSince1970: 1)
        _ = try addText("middle", fixture: fixture, store: store)
        fixture.now = Date(timeIntervalSince1970: 2)
        _ = try addText("newest", fixture: fixture, store: store)

        XCTAssertEqual(store.pinnedRecords.map(\.id), [oldest.id])
        XCTAssertEqual(store.ordinaryRecords.map(\.contentHash), [
            try XCTUnwrap(ClipboardContentIdentifier.text("newest")),
            try XCTUnwrap(ClipboardContentIdentifier.text("middle")),
        ])
        XCTAssertEqual(store.index.records.count, 3)
    }

    func testRetentionRemovesAtExactBoundaryButKeepsOneInstantBefore() throws {
        let fixture = try ClipboardFixture()
        defer { fixture.remove() }
        let store = try XCTUnwrap(fixture.store)
        fixture.now = Date(timeIntervalSince1970: 0)
        let record = try XCTUnwrap(addText("boundary", fixture: fixture, store: store))
        var settings = store.settings
        settings.retentionEnabled = true
        settings.retentionDays = 1
        try store.updateSettings(settings)

        fixture.now = Date(timeIntervalSince1970: 86_399.999)
        try store.applyCleanupNow()
        XCTAssertEqual(store.index.records.map(\.id), [record.id])

        fixture.now = Date(timeIntervalSince1970: 86_400)
        try store.applyCleanupNow()
        XCTAssertTrue(store.index.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.directory.appending(path: record.fileName).path
        ))
    }

    func testDuplicateRefreshesTimeAndSourceBeforeRetentionAndOrdering() throws {
        let fixture = try ClipboardFixture()
        defer { fixture.remove() }
        let store = try XCTUnwrap(fixture.store)
        fixture.now = Date(timeIntervalSince1970: 0)
        let older = try XCTUnwrap(addText(
            "refresh-me",
            source: "com.example.Old",
            sourceName: "Old",
            fixture: fixture,
            store: store
        ))
        fixture.now = Date(timeIntervalSince1970: 10)
        _ = try addText("newer", fixture: fixture, store: store)
        fixture.now = Date(timeIntervalSince1970: 20)
        let duplicate = try XCTUnwrap(addText(
            "refresh-me",
            source: "com.example.New",
            sourceName: "New",
            fixture: fixture,
            store: store
        ))

        XCTAssertEqual(duplicate.id, older.id)
        XCTAssertEqual(duplicate.copiedAt, Date(timeIntervalSince1970: 20))
        XCTAssertEqual(duplicate.sourceBundleIdentifier, "com.example.New")
        XCTAssertEqual(duplicate.sourceName, "New")
        XCTAssertEqual(store.ordinaryRecords.first?.id, older.id)

        var settings = store.settings
        settings.retentionEnabled = true
        settings.retentionDays = 1
        try store.updateSettings(settings)
        fixture.now = Date(timeIntervalSince1970: 20 + 86_400)
        try store.applyCleanupNow()
        XCTAssertTrue(store.index.records.isEmpty)
    }

    func testUnpinAppliesLimitAndClearKeepsFilesInsideManagedDirectoryOnly() throws {
        let fixture = try ClipboardFixture()
        defer { fixture.remove() }
        let store = try XCTUnwrap(fixture.store)
        var records: [ClipboardRecord] = []
        for index in 0..<3 {
            fixture.now = Date(timeIntervalSince1970: Double(index))
            let text = "value-\(index)"
            records.append(try XCTUnwrap(store.add(ClipboardCapture(
                content: .text(text),
                sourceBundleIdentifier: nil,
                sourceName: nil,
                contentHash: try XCTUnwrap(ClipboardContentIdentifier.text(text))
            ))))
        }
        try store.setPinned(true, id: records[0].id)
        var settings = store.settings
        settings.maximumItems = 1
        try store.updateSettings(settings)
        XCTAssertEqual(store.index.records.count, 2)

        try store.setPinned(false, id: records[0].id)
        XCTAssertEqual(store.index.records.count, 1)
        let outside = fixture.directory.deletingLastPathComponent().appending(path: "keep-me.txt")
        try Data("keep".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        try store.clearOrdinary()
        XCTAssertTrue(store.index.records.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testImageDedupUsesNormalizedPixelsAndThumbnailExists() throws {
        let fixture = try ClipboardFixture()
        defer { fixture.remove() }
        let firstImage = try makeImage(red: 1, green: 0, blue: 0)
        let secondImage = try makeImage(red: 1, green: 0, blue: 0)
        let store = try XCTUnwrap(fixture.store)
        let firstHash = try XCTUnwrap(ClipboardContentIdentifier.image(firstImage))
        XCTAssertEqual(firstHash, try XCTUnwrap(ClipboardContentIdentifier.image(secondImage)))
        let first = try XCTUnwrap(store.add(ClipboardCapture(
            content: .image(firstImage),
            sourceBundleIdentifier: "com.example.Preview",
            sourceName: "Preview",
            contentHash: firstHash
        )))
        let second = try XCTUnwrap(store.add(ClipboardCapture(
            content: .image(secondImage),
            sourceBundleIdentifier: "com.example.Preview",
            sourceName: "Preview",
            contentHash: firstHash
        )))

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.index.records.count, 1)
        XCTAssertNotNil(store.thumbnail(for: first))
        guard case .image = store.content(for: first) else {
            return XCTFail("图片内容必须可恢复")
        }
    }

    func testDuplicateReturnMatchesContentKindWhenHashesCollide() throws {
        let fixture = try ClipboardFixture()
        defer { fixture.remove() }
        let store = try XCTUnwrap(fixture.store)
        let hash = "shared-hash"
        let text = try XCTUnwrap(store.add(ClipboardCapture(
            content: .text("text"),
            sourceBundleIdentifier: nil,
            sourceName: nil,
            contentHash: hash
        )))
        let image = try XCTUnwrap(store.add(ClipboardCapture(
            content: .image(try makeImage(red: 1, green: 0, blue: 0)),
            sourceBundleIdentifier: nil,
            sourceName: nil,
            contentHash: hash
        )))

        let returnedText = try XCTUnwrap(store.add(ClipboardCapture(
            content: .text("text"),
            sourceBundleIdentifier: nil,
            sourceName: nil,
            contentHash: hash
        )))
        let returnedImage = try XCTUnwrap(store.add(ClipboardCapture(
            content: .image(try makeImage(red: 1, green: 0, blue: 0)),
            sourceBundleIdentifier: nil,
            sourceName: nil,
            contentHash: hash
        )))

        XCTAssertEqual(returnedText.kind, text.kind)
        XCTAssertEqual(returnedImage.kind, image.kind)
    }

    func testSubsecondCopyTimesSurviveReloadAndKeepOrder() throws {
        let fixture = try ClipboardFixture()
        defer { fixture.remove() }
        let store = try XCTUnwrap(fixture.store)
        fixture.now = Date(timeIntervalSince1970: 100.2)
        let older = try XCTUnwrap(store.add(ClipboardCapture(
            content: .text("older"),
            sourceBundleIdentifier: nil,
            sourceName: nil,
            contentHash: try XCTUnwrap(ClipboardContentIdentifier.text("older"))
        )))
        fixture.now = Date(timeIntervalSince1970: 100.9)
        let newer = try XCTUnwrap(store.add(ClipboardCapture(
            content: .text("newer"),
            sourceBundleIdentifier: nil,
            sourceName: nil,
            contentHash: try XCTUnwrap(ClipboardContentIdentifier.text("newer"))
        )))

        let reloaded = try fixture.makeStore()

        XCTAssertEqual(reloaded.ordinaryRecords.map(\.id), [newer.id, older.id])
        XCTAssertGreaterThan(
            try XCTUnwrap(reloaded.ordinaryRecords.first?.copiedAt),
            try XCTUnwrap(reloaded.ordinaryRecords.last?.copiedAt)
        )
    }

    func testCorruptIndexIsReportedAndPreserved() throws {
        let fixture = try ClipboardFixture(writeInitialIndex: false)
        defer { fixture.remove() }
        let original = Data("{\"version\":1,\"records\":".utf8)
        try original.write(to: fixture.directory.appending(path: "index.json"))

        XCTAssertThrowsError(try fixture.makeStore()) { error in
            XCTAssertEqual(error as? ClipboardStoreError, .corruptedIndex)
        }
        XCTAssertEqual(
            try Data(contentsOf: fixture.directory.appending(path: "index.json")),
            original
        )
    }

    func testIndexCannotReadOrDeleteFilesOutsideManagedDirectory() throws {
        let fixture = try ClipboardFixture()
        defer { fixture.remove() }
        let external = fixture.root.appending(path: "outside.txt")
        try Data("outside".utf8).write(to: external)
        let record = ClipboardRecord(
            id: UUID(),
            kind: .text,
            contentHash: "unsafe",
            fileName: "../outside.txt",
            thumbnailFileName: external.path,
            pixelWidth: nil,
            pixelHeight: nil,
            sourceBundleIdentifier: nil,
            sourceName: nil,
            copiedAt: Date(),
            pinnedAt: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(ClipboardIndex(version: 1, records: [record]))
            .write(to: fixture.directory.appending(path: "index.json"))
        let store = try fixture.makeStore()

        XCTAssertNil(store.content(for: record))
        XCTAssertNil(store.thumbnail(for: record))
        try store.delete(id: record.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
    }

    func testMonitorSkipsBaselineSensitiveSelfWriteBlacklistAndRecordsLaterChange() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.remove() }
        let pasteboard = FakeClipboardPasteboard()
        pasteboard.changeCount = 5
        pasteboard.setItem(types: [SystemClipboardPasteboard.textType], text: "old")
        let store = try XCTUnwrap(fixture.store)
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)
        monitor.start()
        XCTAssertTrue(store.index.records.isEmpty)

        pasteboard.changeCount = 6
        pasteboard.setItem(
            types: [SystemClipboardPasteboard.textType],
            text: "new",
            source: "com.example.Editor"
        )
        await monitor.pollNow()
        XCTAssertEqual(store.index.records.count, 1)
        XCTAssertEqual(store.text(for: try XCTUnwrap(store.index.records.first)), "new")

        pasteboard.changeCount = 7
        pasteboard.setItem(types: [
            SystemClipboardPasteboard.textType,
            SystemClipboardPasteboard.concealedType,
        ], text: "secret")
        await monitor.pollNow()
        XCTAssertEqual(store.index.records.count, 1)

        pasteboard.changeCount = 8
        pasteboard.setItem(types: [
            SystemClipboardPasteboard.textType,
            SystemClipboardPasteboard.selfWriteType,
        ], text: "self")
        await monitor.pollNow()
        XCTAssertEqual(store.index.records.count, 1)

        var settings = store.settings
        settings.disabledBundleIdentifiers = ["com.example.Blocked"]
        try store.updateSettings(settings)
        pasteboard.changeCount = 9
        pasteboard.setItem(
            types: [SystemClipboardPasteboard.textType],
            text: "blocked",
            source: "com.example.Blocked"
        )
        await monitor.pollNow()
        XCTAssertEqual(store.index.records.count, 1)

        pasteboard.changeCount = 10
        pasteboard.setItem(
            types: [SystemClipboardPasteboard.textType],
            text: "after",
            source: "com.example.Browser"
        )
        await monitor.pollNow()
        XCTAssertEqual(store.index.records.count, 2)

        monitor.stop()
        pasteboard.changeCount = 11
        pasteboard.setItem(types: [SystemClipboardPasteboard.textType], text: "ignored")
        await monitor.pollNow()
        XCTAssertEqual(store.index.records.count, 2)
    }

    func testMonitorDropsChangeWhenPasteboardVersionMovesDuringRead() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.remove() }
        let pasteboard = FakeClipboardPasteboard()
        pasteboard.changeCount = 0
        let store = try XCTUnwrap(fixture.store)
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)
        monitor.start()

        pasteboard.changeCount = 1
        pasteboard.setItem(types: [SystemClipboardPasteboard.textType], text: "racy")
        pasteboard.changeCountAfterInspect = 2
        await monitor.pollNow()

        XCTAssertTrue(store.index.records.isEmpty)
        pasteboard.changeCountAfterInspect = nil
        pasteboard.changeCount = 3
        pasteboard.setItem(types: [SystemClipboardPasteboard.textType], text: "stable")
        await monitor.pollNow()
        XCTAssertEqual(store.index.records.count, 1)
    }

    func testMonitorRetriesFinalVersionAfterVersionMovesDuringRead() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.remove() }
        let pasteboard = FakeClipboardPasteboard()
        let store = try XCTUnwrap(fixture.store)
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)
        monitor.start()

        pasteboard.changeCount = 1
        pasteboard.setItem(types: [SystemClipboardPasteboard.textType], text: "racing")
        pasteboard.changeCountAfterInspect = 2
        await monitor.pollNow()
        XCTAssertTrue(store.index.records.isEmpty)

        pasteboard.setItem(types: [SystemClipboardPasteboard.textType], text: "final")
        await monitor.pollNow()

        XCTAssertEqual(store.index.records.count, 1)
        XCTAssertEqual(store.text(for: try XCTUnwrap(store.index.records.first)), "final")
    }

    func testStopDuringBackgroundDecodePreventsOldGenerationCommit() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.remove() }
        let pasteboard = FakeClipboardPasteboard()
        pasteboard.changeCount = 0
        let store = try XCTUnwrap(fixture.store)
        let gate = ClipboardDecodeGate()
        let monitor = ClipboardMonitor(
            store: store,
            pasteboard: pasteboard,
            decoder: { snapshot in
                await gate.markStarted()
                try? await Task.sleep(for: .milliseconds(80))
                return await ClipboardChangeReader.decode(snapshot)
            }
        )
        monitor.start()
        pasteboard.changeCount = 1
        pasteboard.setItem(types: [SystemClipboardPasteboard.textType], text: "late")

        let pollTask = Task { await monitor.pollNow() }
        await gate.waitUntilStarted()
        monitor.stop()
        await pollTask.value

        XCTAssertTrue(store.index.records.isEmpty)
    }

    func testStopDuringBackgroundFileWritePreventsOldGenerationCommit() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.remove() }
        let pasteboard = FakeClipboardPasteboard()
        pasteboard.changeCount = 0
        let store = try XCTUnwrap(fixture.store)
        let gate = ClipboardDecodeGate()
        let monitor = ClipboardMonitor(
            store: store,
            pasteboard: pasteboard,
            decoder: { snapshot in
                var decoded = await ClipboardChangeReader.decode(snapshot)
                await gate.markStarted()
                try? await Task.sleep(for: .milliseconds(80))
                decoded = ClipboardObservedChange(
                    changeCount: decoded.changeCount,
                    items: decoded.items,
                    sourceBundleIdentifier: decoded.sourceBundleIdentifier,
                    frontmostBundleIdentifier: decoded.frontmostBundleIdentifier,
                    sourceName: decoded.sourceName,
                    isSelfWrite: decoded.isSelfWrite,
                    isSensitive: decoded.isSensitive
                )
                return decoded
            }
        )
        monitor.start()
        pasteboard.changeCount = 1
        pasteboard.setItem(
            types: [SystemClipboardPasteboard.textType],
            text: "late-image-write"
        )

        let pollTask = Task { await monitor.pollNow() }
        await gate.waitUntilStarted()
        monitor.stop()
        await pollTask.value

        XCTAssertTrue(store.index.records.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(
            atPath: fixture.directory.path
        )
        XCTAssertEqual(files.filter { !$0.hasPrefix("index.json") }, [])
    }

    func testMonitorDoesNotPollAfterAccessIsDenied() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.remove() }
        let pasteboard = FakeClipboardPasteboard()
        pasteboard.accessState = .denied
        let monitor = ClipboardMonitor(
            store: try XCTUnwrap(fixture.store),
            pasteboard: pasteboard,
            pollInterval: .milliseconds(10)
        )

        monitor.start()

        guard case .failed = monitor.runtimeStatus else {
            return XCTFail("拒绝访问时必须显示失败状态")
        }
        XCTAssertFalse(monitor.isActive)
        XCTAssertEqual(pasteboard.inspectCount, 0)
    }

    func testStoppedMonitorDoesNotReadPasteboardChangeCount() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.remove() }
        let pasteboard = FakeClipboardPasteboard()
        let monitor = ClipboardMonitor(
            store: try XCTUnwrap(fixture.store),
            pasteboard: pasteboard
        )
        monitor.start()
        let readsAfterStart = pasteboard.changeCountReadCount

        monitor.stop()
        monitor.stop()
        await monitor.pollNow()

        XCTAssertEqual(pasteboard.changeCountReadCount, readsAfterStart)
    }

    func testMonitorProbesAskStateOnceAndStopsUntilRetry() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.remove() }
        let pasteboard = FakeClipboardPasteboard()
        pasteboard.accessState = .ask
        let monitor = ClipboardMonitor(
            store: try XCTUnwrap(fixture.store),
            pasteboard: pasteboard,
            pollInterval: .milliseconds(10)
        )

        monitor.start()
        monitor.retry()

        guard case .failed = monitor.runtimeStatus else {
            return XCTFail("未授权时必须显示失败状态")
        }
        XCTAssertFalse(monitor.isActive)
        XCTAssertEqual(pasteboard.inspectCount, 2)

        pasteboard.accessState = .allowed
        monitor.retry()

        XCTAssertTrue(monitor.isActive)
        XCTAssertEqual(monitor.runtimeStatus, .running)
    }

    func testSleepAndWakeUseNewBaselineAndIgnoreContentChangedWhileAsleep() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.remove() }
        let pasteboard = FakeClipboardPasteboard()
        let center = NotificationCenter()
        let store = try XCTUnwrap(fixture.store)
        let monitor = ClipboardMonitor(
            store: store,
            pasteboard: pasteboard,
            notificationCenter: center,
            frontmostApplication: { nil }
        )
        monitor.start()

        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        await waitUntil { monitor.isSleeping }
        pasteboard.changeCount = 1
        pasteboard.setItem(types: [SystemClipboardPasteboard.textType], text: "while-asleep")
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        await waitUntil { !monitor.isSleeping }
        await monitor.pollNow()
        XCTAssertTrue(store.index.records.isEmpty)

        pasteboard.changeCount = 2
        pasteboard.setItem(types: [SystemClipboardPasteboard.textType], text: "after-wake")
        await monitor.pollNow()
        XCTAssertEqual(store.index.records.count, 1)
        XCTAssertEqual(store.text(for: try XCTUnwrap(store.index.records.first)), "after-wake")
    }

    func testBlacklistSkipsCompletelyUnknownSource() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.remove() }
        let pasteboard = FakeClipboardPasteboard()
        let store = try XCTUnwrap(fixture.store)
        var settings = store.settings
        settings.disabledBundleIdentifiers = ["com.example.Blocked"]
        try store.updateSettings(settings)
        let monitor = ClipboardMonitor(
            store: store,
            pasteboard: pasteboard,
            frontmostApplication: { nil }
        )
        monitor.start()

        pasteboard.changeCount = 1
        pasteboard.setItem(types: [SystemClipboardPasteboard.textType], text: "unknown")
        await monitor.pollNow()
        XCTAssertTrue(store.index.records.isEmpty)
    }

    func testBlacklistHitDoesNotAddOrRefreshExistingRecord() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.remove() }
        let pasteboard = FakeClipboardPasteboard()
        let store = try XCTUnwrap(fixture.store)
        fixture.now = Date(timeIntervalSince1970: 1)
        let original = try XCTUnwrap(addText(
            "same-text",
            source: "com.example.Allowed",
            sourceName: "Allowed",
            fixture: fixture,
            store: store
        ))
        var settings = store.settings
        settings.disabledBundleIdentifiers = ["com.example.Blocked"]
        try store.updateSettings(settings)
        let monitor = ClipboardMonitor(
            store: store,
            pasteboard: pasteboard,
            frontmostApplication: { nil }
        )
        monitor.start()

        fixture.now = Date(timeIntervalSince1970: 2)
        pasteboard.changeCount = 1
        pasteboard.setItem(
            types: [SystemClipboardPasteboard.textType],
            text: "same-text",
            source: "com.example.Blocked"
        )
        await monitor.pollNow()

        let record = try XCTUnwrap(store.index.records.first)
        XCTAssertEqual(record.id, original.id)
        XCTAssertEqual(record.copiedAt, original.copiedAt)
        XCTAssertEqual(record.sourceBundleIdentifier, "com.example.Allowed")
    }

    func testPanelKeyboardSelectionAndCopyUseVisibleSearchResults() throws {
        let fixture = try ClipboardFixture()
        defer { fixture.remove() }
        let store = try XCTUnwrap(fixture.store)
        fixture.now = Date(timeIntervalSince1970: 1)
        let older = try XCTUnwrap(store.add(ClipboardCapture(
            content: .text("older"),
            sourceBundleIdentifier: nil,
            sourceName: "Editor",
            contentHash: try XCTUnwrap(ClipboardContentIdentifier.text("older"))
        )))
        fixture.now = Date(timeIntervalSince1970: 2)
        let newer = try XCTUnwrap(store.add(ClipboardCapture(
            content: .text("newer"),
            sourceBundleIdentifier: nil,
            sourceName: "Browser",
            contentHash: try XCTUnwrap(ClipboardContentIdentifier.text("newer"))
        )))
        let pasteboard = FakeClipboardPasteboard()
        let model = ClipboardPanelModel(
            store: store,
            pasteboard: pasteboard,
            targetApplication: nil
        )
        var didClose = false
        model.onClose = { didClose = true }

        model.selectNext(1)
        XCTAssertEqual(model.selectedID, newer.id)
        model.selectNext(1)
        XCTAssertEqual(model.selectedID, older.id)
        model.selectedID = newer.id
        model.searchText = "Editor"
        model.copySelectedOrFirst()

        guard case .text(let copiedText) = try XCTUnwrap(pasteboard.written) else {
            return XCTFail("应复制文本记录")
        }
        XCTAssertEqual(copiedText, "older")
        XCTAssertTrue(didClose)
    }

    func testPanelCopyFailureKeepsPanelOpenAndShowsError() throws {
        let fixture = try ClipboardFixture()
        defer { fixture.remove() }
        let store = try XCTUnwrap(fixture.store)
        let record = try XCTUnwrap(addText("cannot-copy", fixture: fixture, store: store))
        let pasteboard = FakeClipboardPasteboard()
        pasteboard.writeError = ClipboardPasteboardError.writeFailed
        let model = ClipboardPanelModel(
            store: store,
            pasteboard: pasteboard,
            targetApplication: nil
        )
        var didClose = false
        model.onClose = { didClose = true }

        model.copy(record)

        XCTAssertFalse(didClose)
        XCTAssertEqual(model.errorMessage, ClipboardPasteboardError.writeFailed.localizedDescription)
    }

    func testPanelDirectPasteContinuesAfterPanelCloses() async throws {
        let fixture = try ClipboardFixture()
        defer { fixture.remove() }
        let store = try XCTUnwrap(fixture.store)
        let record = try XCTUnwrap(addText("direct", fixture: fixture, store: store))
        let pasteboard = FakeClipboardPasteboard()
        let target = FakeRunningClipboardTarget()
        let paster = DeferredClipboardPaster()
        let model = ClipboardPanelModel(
            store: store,
            pasteboard: pasteboard,
            targetApplication: target.application,
            directPaster: paster
        )
        var didClose = false
        var reportedError: Error?
        model.onClose = { didClose = true }
        model.onError = { reportedError = $0 }

        model.directPaste(record)
        XCTAssertTrue(didClose)
        await paster.waitUntilStarted()
        paster.finish(with: .failure(ClipboardDirectPasteError.targetChanged))
        await waitUntil { reportedError != nil }

        XCTAssertEqual(reportedError as? ClipboardDirectPasteError, .targetChanged)
    }

    func testImageSearchMatchesSourceButNotPreviewOrPixels() throws {
        let fixture = try ClipboardFixture()
        defer { fixture.remove() }
        let store = try XCTUnwrap(fixture.store)
        let image = try makeImage(red: 1, green: 0, blue: 0)
        _ = try store.add(ClipboardCapture(
            content: .image(image),
            sourceBundleIdentifier: "com.example.Photos",
            sourceName: "Photos",
            contentHash: try XCTUnwrap(ClipboardContentIdentifier.image(image))
        ))
        let model = ClipboardPanelModel(
            store: store,
            pasteboard: FakeClipboardPasteboard(),
            targetApplication: nil
        )

        model.searchText = "Photos"
        XCTAssertEqual(model.visibleRecords.count, 1)
        model.searchText = "red"
        XCTAssertTrue(model.visibleRecords.isEmpty)
        model.searchText = "4 × 4"
        XCTAssertTrue(model.visibleRecords.isEmpty)
    }

    private func addText(
        _ text: String,
        source: String? = nil,
        sourceName: String? = nil,
        fixture: ClipboardFixture,
        store: ClipboardHistoryStore
    ) throws -> ClipboardRecord? {
        try store.add(ClipboardCapture(
            content: .text(text),
            sourceBundleIdentifier: source,
            sourceName: sourceName,
            contentHash: try XCTUnwrap(ClipboardContentIdentifier.text(text))
        ))
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("等待状态变化超时", file: file, line: line)
    }

    private func makeImage(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor(red: red, green: green, blue: blue, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return try XCTUnwrap(context.makeImage())
    }
}

@MainActor
private final class ClipboardFixture {
    let root: URL
    let directory: URL
    let settingsURL: URL
    var now = Date(timeIntervalSince1970: 0)
    private(set) var store: ClipboardHistoryStore!

    init(writeInitialIndex: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "nylai-clipboard-\(UUID().uuidString)", directoryHint: .isDirectory)
        directory = root.appending(path: "clipboard", directoryHint: .isDirectory)
        settingsURL = root.appending(path: "settings.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if writeInitialIndex {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(ClipboardIndex.empty).write(to: directory.appending(path: "index.json"))
            store = try makeStore()
        }
    }

    func makeStore() throws -> ClipboardHistoryStore {
        try ClipboardHistoryStore(
            directoryURL: directory,
            settingsStore: ClipboardSettingsStore(fileURL: settingsURL),
            clock: { [weak self] in self?.now ?? Date() }
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class FakeClipboardPasteboard: ClipboardPasteboardAccessing {
    var accessState: ClipboardPasteboardAccessState = .allowed
    var changeCountAfterInspect: Int?
    var globalTypes: Set<String> = []
    var source: String?
    var itemTypes: [Set<String>] = []
    var dataByItem: [Int: [String: Data]] = [:]
    var stringByItem: [Int: [String: String]] = [:]
    var writeError: Error?
    private(set) var inspectCount = 0
    private(set) var changeCountReadCount = 0
    private(set) var written: ClipboardContent?

    var changeCount: Int {
        get {
            changeCountReadCount += 1
            return storedChangeCount
        }
        set {
            storedChangeCount = newValue
        }
    }
    private var storedChangeCount = 0

    func setItem(
        types: [String],
        text: String? = nil,
        source newSource: String? = nil
    ) {
        itemTypes = [Set(types)]
        dataByItem = [:]
        stringByItem = [:]
        source = newSource
        if let text, types.contains(SystemClipboardPasteboard.textType) {
            stringByItem[0] = [SystemClipboardPasteboard.textType: text]
            dataByItem[0] = [SystemClipboardPasteboard.textType: Data(text.utf8)]
        }
    }

    func inspect() throws -> ClipboardPasteboardInspection {
        inspectCount += 1
        let count = changeCount
        if let changeCountAfterInspect {
            changeCount = changeCountAfterInspect
            self.changeCountAfterInspect = nil
        }
        return ClipboardPasteboardInspection(
            changeCount: count,
            types: globalTypes,
            items: itemTypes.map(ClipboardPasteboardItemDescriptor.init(types:)),
            sourceBundleIdentifier: source
        )
    }

    func data(forItemAt index: Int, type: String) -> Data? {
        dataByItem[index]?[type]
    }

    func string(forItemAt index: Int, type: String) -> String? {
        stringByItem[index]?[type]
    }

    func write(_ content: ClipboardContent, sourceBundleIdentifier: String) throws {
        if let writeError {
            throw writeError
        }
        written = content
        changeCount += 1
    }
}

@MainActor
private final class FakeRunningClipboardTarget: ClipboardPasteTarget {
    let application: NSRunningApplication
    let bundleIdentifier: String? = "com.example.Target"
    var processIdentifier: pid_t { application.processIdentifier }
    var isTerminated: Bool { application.isTerminated }
    var isActive: Bool { application.isActive }

    init() {
        application = NSWorkspace.shared.frontmostApplication
            ?? NSRunningApplication.current
    }

    func activate(options: NSApplication.ActivationOptions) -> Bool {
        application.activate(options: options)
    }
}

@MainActor
private final class DeferredClipboardPaster: ClipboardDirectPasting {
    private var continuation: CheckedContinuation<Result<Void, Error>, Never>?
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func pasteAfterActivating(
        target: any ClipboardPasteTarget,
        expectedBundleIdentifier: String,
        expectedChangeCount: Int,
        pasteboard: any ClipboardPasteboardAccessing
    ) async -> Result<Void, Error> {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finish(with result: Result<Void, Error>) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private actor ClipboardDecodeGate {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
