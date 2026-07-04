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

    // Order behaviour set by Player from the current PlaybackMode. Defaults keep
    // the plain linear "walk the context and stop at the end" contract.
    private var _loops = false      // wrap past the ends of the context
    private var _repeatOne = false  // stay on the current track

    var loops: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _loops }
        set { lock.lock(); _loops = newValue; lock.unlock() }
    }
    var repeatOne: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _repeatOne }
        set { lock.lock(); _repeatOne = newValue; lock.unlock() }
    }

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

    /// The next track to play, honoring the explicit queue first (foobar rule),
    /// then the current mode (repeat-one / loop).
    func advance() -> Track? {
        lock.lock(); defer { lock.unlock() }
        if !queue.isEmpty {
            let item = queue.removeFirst()
            context = item.context
            index = item.index
            return item.track
        }
        if _repeatOne, context.indices.contains(index) {
            return context[index]
        }
        let next = index + 1
        if context.indices.contains(next) {
            index = next
            return context[next]
        }
        if _loops, !context.isEmpty {
            index = 0
            return context[0]
        }
        return nil
    }

    /// Peek what `advance()` would return, without mutating state.
    func peekNext() -> Track? {
        lock.lock(); defer { lock.unlock() }
        if let first = queue.first { return first.track }
        if _repeatOne, context.indices.contains(index) { return context[index] }
        let next = index + 1
        if context.indices.contains(next) { return context[next] }
        if _loops, !context.isEmpty { return context[0] }
        return nil
    }

    /// Previous track within the current context (ignores the queue).
    func previous() -> Track? {
        lock.lock(); defer { lock.unlock() }
        let prev = index - 1
        if context.indices.contains(prev) {
            index = prev
            return context[prev]
        }
        if _loops, !context.isEmpty {
            index = context.count - 1
            return context[index]
        }
        return nil
    }

    /// Current context + cursor snapshot (for rebuilding the timeline in place).
    func currentContext() -> (tracks: [Track], index: Int) {
        lock.lock(); defer { lock.unlock() }
        return (context, index)
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
