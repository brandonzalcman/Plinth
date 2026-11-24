import Foundation
import Testing
import PlinthModel
@testable import PlinthShell

@Suite struct DownloadListTests {
    @Test func aDownloadRunsThenFinishes() {
        var list = DownloadList()
        list.apply(DownloadUpdate(id: 7, url: "https://example.com/a.zip", filename: "a.zip"))
        #expect(list.items.count == 1)
        #expect(list.items[0].state == .running)
        #expect(list.items[0].progress == nil)          // size unknown yet
        #expect(list.barState?.runningCount == 1)

        list.apply(DownloadUpdate(id: 7, filename: "a.zip", path: "/tmp/a (2).zip", receivedBytes: 50, totalBytes: 200,
                                  bytesPerSecond: 10))
        #expect(list.items[0].progress == 0.25)
        #expect(list.items[0].filename == "a (2).zip")  // the name Chromium actually wrote
        #expect(list.items[0].bytesPerSecond == 10)
        #expect(list.barState?.progress == 0.25)

        list.apply(DownloadUpdate(id: 7, filename: "a.zip", path: "/tmp/a (2).zip", receivedBytes: 200, totalBytes: 200,
                                  isInProgress: false, isComplete: true))
        #expect(list.items[0].state == .finished)
        #expect(list.items[0].progress == 1)
        #expect(list.items[0].bytesPerSecond == nil)
        #expect(list.barState?.runningCount == 0)
        #expect(list.items.count == 1)
    }

    @Test func newestFirstAndClearKeepsRunning() {
        var list = DownloadList()
        list.apply(DownloadUpdate(id: 1, filename: "one"))
        list.apply(DownloadUpdate(id: 2, filename: "two"))
        list.apply(DownloadUpdate(id: 1, filename: "one", isInProgress: false, isCanceled: true))
        #expect(list.items.map(\.filename) == ["two", "one"])
        #expect(list.items[1].state == .cancelled)
        list.clearFinished()
        #expect(list.items.map(\.filename) == ["two"])
        list.remove(list.items[0].id)
        #expect(list.items.isEmpty)
        #expect(list.barState == nil)
    }

    @Test func interruptedDownloadsFail() {
        var list = DownloadList()
        list.apply(DownloadUpdate(id: 3, filename: "x", isInProgress: false, isInterrupted: true))
        guard case .failed = list.items[0].state else { Issue.record("expected failed"); return }
    }
}
