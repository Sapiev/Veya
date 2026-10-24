import SpotCoreKit
import Testing

struct LyricsTests {
    private let synced = Lyrics(synced: true, lines: [
        LyricsLine(startMs: 1000, words: "One"),
        LyricsLine(startMs: 3000, words: "Two"),
    ])

    @Test func noLineIsActiveBeforeTheFirstStarts() {
        #expect(synced.activeLine(at: 999) == nil)
    }

    @Test func aLineStaysActiveUntilTheNextStarts() {
        #expect(synced.activeLine(at: 1000) == 0)
        #expect(synced.activeLine(at: 2999) == 0)
        #expect(synced.activeLine(at: 3000) == 1)
        #expect(synced.activeLine(at: 90000) == 1)
    }

    @Test func unsyncedLyricsHaveNoActiveLine() {
        let unsynced = Lyrics(synced: false, lines: [LyricsLine(startMs: 0, words: "Static")])
        #expect(unsynced.activeLine(at: 5000) == nil)
    }
}
