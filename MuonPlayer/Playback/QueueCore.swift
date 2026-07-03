import Foundation

/// Thread-safe playback queue implementing foobar2000 semantics.
///
/// There are two things: the *context* (the album/playlist you're playing, with
/// a cursor) and the *explicit queue* (tracks you asked to play next). When an
/// explicitly-queued track plays, the context switches to *that track's* album at
/// *that track's* position — so after the queued track finishes, playback
/// continues from the following track in its album, not the original context.
///
/// Example: playing ALBUM1/TRACK1 with ALBUM2/TRACK5 queued →
/// TRACK1, then ALBUM2/TRACK5 (from queue), then ALBUM2/TRACK6 (context moved).
final class QueueCore: @unchecked Sendable {
    struct QueuedItem: Identifiable {
        let id = UUID()
        let track: Track
        let context: [Track]
        let index: Int
    }

    private let lock = NSLock()
    private var context: [Track] = []
    private var index: Int = -1
    private var queue: [QueuedItem] = []

    // MARK: Setup

    /// Replace the context and point at `startIndex`. Returns the track to play.
    func setContext(_ tracks: [Track], startIndex: Int) -> Track? {
        lock.lock(); defer { lock.unlock() }
        context = tracks
        index = startIndex
        guard tracks.indices.contains(startIndex) else { return nil }
        return tracks[startIndex]
    }

    // MARK: Advancing

    /// The next track to play, honoring the explicit queue first (foobar rule).
    func advance() -> Track? {
        lock.lock(); defer { lock.unlock() }
        if !queue.isEmpty {
            let item = queue.removeFirst()
            context = item.context
            index = item.index
            return item.track
        }
        let next = index + 1
        guard context.indices.contains(next) else { return nil }
        index = next
        return context[next]
    }

    /// Peek what `advance()` would return, without mutating state.
    func peekNext() -> Track? {
        lock.lock(); defer { lock.unlock() }
        if let first = queue.first { return first.track }
        let next = index + 1
        return context.indices.contains(next) ? context[next] : nil
    }

    /// Previous track within the current context (ignores the queue).
    func previous() -> Track? {
        lock.lock(); defer { lock.unlock() }
        let prev = index - 1
        guard context.indices.contains(prev) else { return nil }
        index = prev
        return context[prev]
    }

    // MARK: Queue editing

    func enqueue(_ track: Track, context: [Track], index: Int) {
        lock.lock(); defer { lock.unlock() }
        queue.append(QueuedItem(track: track, context: context, index: index))
    }

    func removeQueued(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        queue.removeAll { $0.id == id }
    }

    func clearQueue() {
        lock.lock(); defer { lock.unlock() }
        queue.removeAll()
    }

    // MARK: Snapshots (for UI)

    func queuedItems() -> [QueuedItem] {
        lock.lock(); defer { lock.unlock() }
        return queue
    }

    var upNextCount: Int {
        lock.lock(); defer { lock.unlock() }
        return queue.count
    }
}
