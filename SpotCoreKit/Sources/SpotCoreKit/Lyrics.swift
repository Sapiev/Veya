public extension Lyrics {
    /// The line sung at `positionMs`: the last one started by then. Nil for unsynced lyrics and before the first line.
    func activeLine(at positionMs: UInt32) -> Int? {
        guard synced else { return nil }
        return lines.lastIndex { $0.startMs <= positionMs }
    }
}
