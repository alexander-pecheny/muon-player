import AVFoundation
import MediaPlayer
import Observation
import SwiftUI

/// Gapless audio player built on AVAudioEngine + a single AVAudioPlayerNode.
///
/// All tracks are decoded (via FFmpeg) to one canonical PCM format and their
/// buffers are scheduled onto the same player node back-to-back. Because the
/// node never reconfigures between tracks, consecutive tracks play with zero
/// gap. UI state (current track / time) is derived by mapping the node's sample
/// position onto the table of scheduled segments.
@MainActor
@Observable
final class Player {
    // Observable UI state
    private(set) var currentTrack: Track?
    private(set) var isPlaying: Bool = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var upNext: [QueueCore.QueuedItem] = []
    private(set) var reachedEnd: Bool = false
    /// What plays next: the head of the explicit queue, else the playhead's next.
    private(set) var nextUpTrack: Track?

    /// Playback order / repeat scope (see PlaybackMode). Persisted across launches
    /// so a chosen mode (e.g. Repeat Artist) survives an app restart.
    var mode: PlaybackMode = .normal {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            Task { await applyMode() }
        }
    }
    private static let modeKey = "playbackMode"

    /// Output gain, 0…1. iOS defers to the system volume; macOS has no hardware
    /// volume affordance inside the app, so the mixer carries it. Persisted.
    var volume: Float = 1 {
        didSet {
            engine.mainMixerNode.outputVolume = volume
            UserDefaults.standard.set(volume, forKey: Self.volumeKey)
        }
    }
    private static let volumeKey = "outputVolume"

    /// Fired when a track begins playing (for "now playing" scrobble update).
    var onTrackStarted: ((Track) -> Void)?
    /// Fired when a track stops being the current track, with how long it played.
    var onTrackFinished: ((Track, TimeInterval) -> Void)?
    /// Fired once, mid-playback, the moment the current track first crosses
    /// Last.fm's scrobble-eligibility threshold (>30s track, past its halfway
    /// point or 4 min). Lets the scrobble be submitted immediately rather than
    /// waiting for the track to change.
    var onScrobbleEligible: ((Track) -> Void)?
    // Guards `onScrobbleEligible` to one emission per play; re-armed on each
    // new (or restarted) track.
    private var eligibleReported = false
    // Actual seconds of forward playback for the current track (pauses don't
    // advance it, seeks don't inflate it). Drives eligibility so "listened
    // enough" reflects real listening, not just playhead position.
    private var playedAccumulator: TimeInterval = 0

    /// Set by the app so the playhead can fetch an artist's folder tracks.
    weak var library: LibraryStore?

    let queue = QueueCore()

    // The album the user started from (used for repeat-album and as a fallback
    // when a track isn't inside an artist folder).
    private var albumContext: [Track] = []
    // The scope key the current timeline was built for (folder path / album-artist
    // / album, depending on mode). `timelineBuilt` disambiguates unset.
    private var timelineScope: String?
    private var timelineBuilt = false

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let feedQueue = DispatchQueue(label: "com.muonplayer.feed")

    // Feeder state — only touched on feedQueue.
    private var currentDecoder: FFmpegDecoder?
    private var cumulativeScheduledFrames: AVAudioFramePosition = 0
    private var pendingFrames: Int = 0
    private var generation: Int = 0          // bumped on every discontinuity
    private var noMoreAudio = false
    // Ramp the first few ms after a user-initiated start/seek up from silence, so
    // any engine/decoder startup transient (the occasional "white noise" blip)
    // is inaudible. Never set on gapless album transitions, so those stay seamless.
    private var fadeInRemaining: Int = 0
    private static let fadeInFrames = Int(CanonicalAudio.sampleRate * 0.012) // 12ms

    private let segments = SegmentTable()
    private let targetBufferedFrames = Int(CanonicalAudio.sampleRate * 3) // ~3s ahead

    private var ticker: Timer?
    private var lastReportedTrackID: UUID?
    private var reportedTrackStartFrame: AVAudioFramePosition = 0

    init() {
        // Restore the persisted playback mode. Assigning a stored property inside
        // the defining class's own initializer does not fire `didSet`, so this
        // just seeds the initial value (loop flags are applied when playback
        // starts) without kicking off an applyMode() before the graph is ready.
        if let raw = UserDefaults.standard.string(forKey: Self.modeKey),
           let saved = PlaybackMode(rawValue: raw) {
            mode = saved
        }
        setupEngine()
        setupRemoteCommands()
    }

    private func setupEngine() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: CanonicalAudio.format)
        if let saved = UserDefaults.standard.object(forKey: Self.volumeKey) as? Float {
            volume = saved
        }
        engine.mainMixerNode.outputVolume = volume
        engine.prepare()
    }

    // MARK: - Public controls

    /// Play `track` within `context` (its album/playlist). Does not clear the queue.
    func play(track: Track, context: [Track]) {
        albumContext = context
        // Start immediately on the album context so playback (and gapless) works
        // without waiting on the async artist-folder fetch.
        let index = context.firstIndex(where: { $0.url == track.url }) ?? 0
        _ = queue.setContext(context, startIndex: index)
        applyLoopFlags()
        timelineBuilt = false
        beginPlayback(track, offset: 0)
        refreshUpNext()
        // Upgrade the timeline to the full mode order (artist folder / shuffle).
        Task { await rebuildTimeline(anchor: track) }
    }

    // MARK: - Playback mode / playhead

    private func applyLoopFlags() {
        queue.repeatOne = mode.repeatsOne
        queue.loops = mode.loops
    }

    /// The scope identity the timeline should follow in the current mode. When the
    /// currently-playing track no longer matches it (e.g. a queued cross-album
    /// track played), the timeline is re-anchored around the new track.
    private func scopeKey(for track: Track) -> String {
        switch mode {
        case .repeatTopFolder, .shuffle:
            return "folder:" + (library?.topFolder(for: track) ?? track.url.deletingLastPathComponent().path)
        case .repeatArtist:
            return "artist:" + track.effectiveAlbumArtist
        case .normal, .repeatAlbum, .repeatTrack:
            return "album:" + track.effectiveAlbumArtist + "\u{1}" + track.displayAlbum
        }
    }

    /// Rebuild the automatic play order around `anchor` for the current mode,
    /// without interrupting what's currently playing.
    private func rebuildTimeline(anchor: Track) async {
        var timeline: [Track]
        switch mode {
        case .normal, .repeatAlbum, .repeatTrack:
            timeline = albumContext.isEmpty ? [anchor] : albumContext
        case .repeatTopFolder:
            let folder = await library?.artistFolderTracks(for: anchor) ?? []
            timeline = folder.isEmpty ? (albumContext.isEmpty ? [anchor] : albumContext) : folder
        case .repeatArtist:
            let byArtist = await library?.albumArtistTracks(for: anchor) ?? []
            timeline = byArtist.isEmpty ? (albumContext.isEmpty ? [anchor] : albumContext) : byArtist
        case .shuffle:
            let folder = await library?.artistFolderTracks(for: anchor) ?? []
            let base = folder.isEmpty ? (albumContext.isEmpty ? [anchor] : albumContext) : folder
            timeline = shuffled(base, anchor: anchor)
        }
        // Match by url, not value equality: the timeline is a fresh DB fetch, so
        // its Track instances carry different (random) ids than `anchor` and
        // `firstIndex(of:)` would never match — the playhead would snap to index 0
        // and queue up the scope's second track instead of the anchor's real
        // successor.
        let idx = timeline.firstIndex(where: { $0.url == anchor.url }) ?? 0
        _ = queue.setContext(timeline, startIndex: idx)
        applyLoopFlags()
        timelineScope = scopeKey(for: anchor)
        timelineBuilt = true
        refreshUpNext()
    }

    /// Shuffle `tracks`, keeping `anchor` first so playback continues from the
    /// currently-playing track.
    private func shuffled(_ tracks: [Track], anchor: Track) -> [Track] {
        var s = tracks.shuffled()
        if let i = s.firstIndex(where: { $0.url == anchor.url }) {
            s.remove(at: i)
            s.insert(anchor, at: 0)
        }
        return s
    }

    private func applyMode() async {
        applyLoopFlags()
        if let current = currentTrack {
            await rebuildTimeline(anchor: current)
        }
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func pause() {
        node.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }

    func resume() {
        guard currentTrack != nil else { return }
        do {
            if !engine.isRunning { try engine.start() }
            node.play()
            isPlaying = true
            updateNowPlayingInfo()
        } catch {
            print("resume failed: \(error)")
        }
    }

    func next() {
        guard let track = queue.advance() else { endPlayback(); return }
        beginPlayback(track, offset: 0)
        refreshUpNext()
    }

    func previous() {
        if currentTime > 3, let current = currentTrack {
            beginPlayback(current, offset: 0)
            return
        }
        guard let track = queue.previous() else {
            if let current = currentTrack { beginPlayback(current, offset: 0) }
            return
        }
        beginPlayback(track, offset: 0)
        refreshUpNext()
    }

    func seek(to time: TimeInterval) {
        guard let current = currentTrack else { return }
        beginPlayback(current, offset: max(0, time))
    }

    func stop() {
        endPlayback()
        currentTrack = nil
        duration = 0
        currentTime = 0
        clearNowPlayingInfo()
    }

    // MARK: - Queue editing (UI)

    func enqueue(_ track: Track, context: [Track]) {
        let index = context.firstIndex(where: { $0.url == track.url }) ?? 0
        queue.enqueue(track, context: context, index: index)
        refreshUpNext()
    }

    func removeFromQueue(id: UUID) { queue.removeQueued(id: id); refreshUpNext() }
    func clearQueue() { queue.clearQueue(); refreshUpNext() }
    private func refreshUpNext() {
        upNext = queue.queuedItems()
        nextUpTrack = queue.peekNext()
    }

    // MARK: - Playback core

    /// Reset everything and start feeding from `track` at `offset` seconds.
    private func beginPlayback(_ track: Track, offset: TimeInterval) {
        // A user action (Next / Previous / picking another track) is abandoning
        // the current track. Report how much of it played *before* we tear the
        // node down, so an eligible partial listen still scrobbles — the gapless
        // and end-of-queue paths only cover tracks that finish on their own. A
        // seek or replay of the same track is ignored (see reportOutgoingFinished).
        reportOutgoingFinished(replacedBy: track.id)

        reachedEnd = false
        currentTrack = track
        duration = track.duration ?? 0
        currentTime = offset
        lastReportedTrackID = nil
        eligibleReported = false
        playedAccumulator = 0

        // Bump the generation *before* stopping the node. The feeder checks the
        // generation on every scheduling iteration (see feedIfNeeded), so any
        // in-flight feed for the outgoing track stops at once instead of dumping
        // its remaining buffers onto the restarted node — that stray, full-volume
        // chunk was the "blip" heard at every manual track switch.
        let gen = generation &+ 1
        generation = gen

        node.stop()
        segments.reset()

        do {
            if !engine.isRunning { try engine.start() }
        } catch { print("engine start failed: \(error)") }

        feedQueue.async { [weak self] in
            guard let self, gen == self.generation else { return }
            self.currentDecoder = nil
            self.cumulativeScheduledFrames = 0
            self.pendingFrames = 0
            self.noMoreAudio = false
            self.fadeInRemaining = Player.fadeInFrames
            self.openDecoder(for: track, offset: offset, generation: gen)
            self.feedIfNeeded(generation: gen)
            // Start the node only after its first buffers are queued, so it never
            // renders an empty queue (which underran into a silence gap at the
            // switch point). The incoming track's fade-in then covers the start.
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
                if !self.engine.isRunning { try? self.engine.start() }
                self.node.play()
            }
        }

        isPlaying = true
        startTicker()
        onTrackStarted?(track)
        updateNowPlayingInfo()
        loadArtwork(for: track)
    }

    private func endPlayback() {
        // Reaching the end of the queue by pressing Next past the last track (or
        // Stop) still abandons the outgoing track — report it before stopping.
        reportOutgoingFinished(replacedBy: nil)
        generation &+= 1
        node.stop()
        isPlaying = false
        reachedEnd = true
        stopTicker()
        feedQueue.async { [weak self] in
            self?.currentDecoder = nil
            self?.noMoreAudio = true
        }
    }

    // MARK: - Feeder (feedQueue)

    private func openDecoder(for track: Track, offset: TimeInterval, generation gen: Int) {
        do {
            let decoder = try FFmpegDecoder(url: track.url)
            if offset > 0 { decoder.seek(to: offset) }
            currentDecoder = decoder
            let dur = decoder.duration > 0 ? decoder.duration : (track.duration ?? 0)
            segments.append(Segment(track: track,
                                    startFrame: cumulativeScheduledFrames,
                                    startOffset: offset,
                                    length: nil,
                                    duration: dur))
        } catch {
            print("decode open failed for \(track.url.lastPathComponent): \(error)")
            currentDecoder = nil
        }
    }

    /// Pull the next buffer, transparently crossing into the next track (gapless).
    private func nextChunk(generation gen: Int) -> AVAudioPCMBuffer? {
        guard let decoder = currentDecoder else { return nil }
        if let buffer = decoder.nextBuffer() { return buffer }

        // Current track exhausted — close its segment, then advance the queue.
        segments.finalizeLast(endFrame: cumulativeScheduledFrames)
        guard let nextTrack = queue.advance() else {
            currentDecoder = nil
            return nil
        }
        DispatchQueue.main.async { [weak self] in self?.refreshUpNext() }
        openDecoder(for: nextTrack, offset: 0, generation: gen)
        return currentDecoder?.nextBuffer()
    }

    private func feedIfNeeded(generation gen: Int) {
        while pendingFrames < targetBufferedFrames {
            // Re-check on every iteration: a track switch (which bumps the
            // generation) must stop this feed immediately, or its remaining
            // buffers would be scheduled onto the node that now belongs to the
            // new track.
            guard gen == generation else { return }
            guard let buffer = nextChunk(generation: gen) else {
                noMoreAudio = true
                DispatchQueue.main.async { [weak self] in self?.markPossibleEnd() }
                return
            }
            if fadeInRemaining > 0 { applyFadeIn(to: buffer) }
            let frames = Int(buffer.frameLength)
            pendingFrames += frames
            cumulativeScheduledFrames += AVAudioFramePosition(frames)
            node.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
                guard let self else { return }
                self.feedQueue.async {
                    guard gen == self.generation else { return }
                    self.pendingFrames -= frames
                    self.feedIfNeeded(generation: gen)
                }
            }
        }
    }

    /// Linearly ramp gain 0→1 across the first `fadeInFrames` of output following
    /// a start/seek. Consumes `fadeInRemaining` as it goes.
    private func applyFadeIn(to buffer: AVAudioPCMBuffer) {
        guard let planes = buffer.floatChannelData else { return }
        let channels = Int(buffer.format.channelCount)
        let n = Int(buffer.frameLength)
        let total = Player.fadeInFrames
        for i in 0..<n {
            guard fadeInRemaining > 0 else { break }
            let done = total - fadeInRemaining
            let gain = Float(done) / Float(total)
            for ch in 0..<channels { planes[ch][i] *= gain }
            fadeInRemaining -= 1
        }
    }

    // MARK: - Ticker: map sample position → current track / time

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTicker() { ticker?.invalidate(); ticker = nil }

    private var currentSampleTime: AVAudioFramePosition {
        guard let render = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: render) else { return 0 }
        return playerTime.sampleTime
    }

    /// Emit `onTrackFinished` for the track currently being counted, using its
    /// real elapsed play time, and stop counting it. Called on any manual
    /// teardown (skip / stop). `replacedBy` is the track taking over, or nil if
    /// none; a seek or replay of the *same* track passes its own id and is
    /// ignored so a single listen is never scrobbled twice. Must run before the
    /// node is stopped, while `currentSampleTime` still reflects the outgoing
    /// track's position.
    private func reportOutgoingFinished(replacedBy newTrackID: UUID?) {
        guard let prevID = lastReportedTrackID, prevID != newTrackID,
              let prev = segments.segment(withID: prevID) else { return }
        let played = max(0, Double(currentSampleTime - reportedTrackStartFrame) / CanonicalAudio.sampleRate)
        lastReportedTrackID = nil
        onTrackFinished?(prev.track, played)
    }

    private func tick() {
        guard isPlaying else { return }
        let frame = currentSampleTime
        guard let seg = segments.segment(atFrame: frame) else {
            if noMoreAudioSnapshot() && frame >= segments.lastEndFrame() { finishAtEnd() }
            return
        }

        // Track changed → previous finished, new one started.
        if seg.track.id != lastReportedTrackID {
            if let prevID = lastReportedTrackID,
               let prev = segments.segment(withID: prevID) {
                let played = Double(seg.startFrame - reportedTrackStartFrame) / CanonicalAudio.sampleRate
                onTrackFinished?(prev.track, played)
            }
            lastReportedTrackID = seg.track.id
            reportedTrackStartFrame = seg.startFrame
            eligibleReported = false
            playedAccumulator = 0
            currentTrack = seg.track
            duration = seg.duration
            onTrackStarted?(seg.track)
            loadArtwork(for: seg.track)

            // Crossed out of the timeline's scope (e.g. a queued cross-album
            // track played) — re-anchor so the repeat scope follows the new track.
            let key = scopeKey(for: seg.track)
            if !timelineBuilt || key != timelineScope {
                let anchor = seg.track
                Task { await rebuildTimeline(anchor: anchor) }
            }
            refreshUpNext()
        }

        let newTime = seg.startOffset + Double(frame - seg.startFrame) / CanonicalAudio.sampleRate
        // Count only smooth forward progress toward "listened" — a large jump is
        // a seek (don't credit skipped audio) and a negative delta is a rewind.
        let delta = newTime - currentTime
        if delta > 0, delta < 2 { playedAccumulator += delta }
        currentTime = newTime
        maybeReportEligible()
        updateNowPlayingInfo()
    }

    /// Emit `onScrobbleEligible` the first time the current track has been played
    /// enough to meet Last.fm's rule (>30s long, at least half its length or 4
    /// min of actual playback).
    private func maybeReportEligible() {
        guard !eligibleReported, let track = currentTrack, duration > 30,
              playedAccumulator >= min(duration / 2, 240) else { return }
        eligibleReported = true
        onScrobbleEligible?(track)
    }

    private func noMoreAudioSnapshot() -> Bool {
        feedQueue.sync { noMoreAudio }
    }

    private func markPossibleEnd() { /* handled in tick via lastEndFrame */ }

    private func finishAtEnd() {
        if let current = currentTrack {
            let played = current.duration ?? currentTime
            onTrackFinished?(current, played)
        }
        // Stop counting this track so a following stop()/endPlayback() can't
        // report the same natural finish a second time.
        lastReportedTrackID = nil
        isPlaying = false
        reachedEnd = true
        stopTicker()
        updateNowPlayingInfo()
    }

    // MARK: - Artwork / Now Playing

    private(set) var currentArtwork: PlatformImage?

    /// A vivid accent derived from the current track's artwork (Spotify-style),
    /// used app-wide as the tint. Falls back to the system accent when there's no
    /// artwork or it's grayscale.
    private(set) var accentColor: Color = .neutralAccent

    private func loadArtwork(for track: Track) {
        currentArtwork = nil
        accentColor = .neutralAccent
        guard track.hasArtwork else { return }
        let url = track.url
        Task.detached(priority: .utility) {
            let meta = FFmpegMetadata.read(url: url, includeArtwork: true)
            guard let data = meta.artwork, let image = PlatformImage(data: data) else { return }
            let accent = DominantColor.from(image)
            await MainActor.run { [weak self] in
                guard let self, self.currentTrack?.url == url else { return }
                self.currentArtwork = image
                if let accent { self.accentColor = accent }
                self.updateNowPlayingInfo()
            }
        }
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: e.positionTime) }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let track = currentTrack else { clearNowPlayingInfo(); return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let artist = track.artist { info[MPMediaItemPropertyArtist] = artist }
        if let album = track.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let art = currentArtwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: art.size) { _ in art }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Debug capture (records real mixer output for gapless verification)

    private var captureFile: AVAudioFile?

    func startCapture(to url: URL) {
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        do {
            captureFile = try AVAudioFile(forWriting: url, settings: format.settings)
        } catch {
            print("capture open failed: \(error)"); return
        }
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            try? self.captureFile?.write(from: buffer)
        }
    }

    func stopCapture() {
        engine.mainMixerNode.removeTap(onBus: 0)
        captureFile = nil
    }
}
