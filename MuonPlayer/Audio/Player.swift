import AVFoundation
import MediaPlayer
import Observation

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

    /// Fired when a track begins playing (for "now playing" scrobble update).
    var onTrackStarted: ((Track) -> Void)?
    /// Fired when a track stops being the current track, with how long it played.
    var onTrackFinished: ((Track, TimeInterval) -> Void)?

    let queue = QueueCore()

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let feedQueue = DispatchQueue(label: "com.muonplayer.feed")

    // Feeder state — only touched on feedQueue.
    private var currentDecoder: FFmpegDecoder?
    private var cumulativeScheduledFrames: AVAudioFramePosition = 0
    private var pendingFrames: Int = 0
    private var generation: Int = 0          // bumped on every discontinuity
    private var noMoreAudio = false

    private let segments = SegmentTable()
    private let targetBufferedFrames = Int(CanonicalAudio.sampleRate * 3) // ~3s ahead

    private var ticker: Timer?
    private var lastReportedTrackID: UUID?
    private var reportedTrackStartFrame: AVAudioFramePosition = 0

    init() {
        setupEngine()
        setupRemoteCommands()
    }

    private func setupEngine() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: CanonicalAudio.format)
        engine.prepare()
    }

    // MARK: - Public controls

    /// Play `track` within `context` (its album/playlist). Does not clear the queue.
    func play(track: Track, context: [Track]) {
        let index = context.firstIndex(of: track) ?? 0
        _ = queue.setContext(context, startIndex: index)
        beginPlayback(track, offset: 0)
        refreshUpNext()
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
        let index = context.firstIndex(of: track) ?? 0
        queue.enqueue(track, context: context, index: index)
        refreshUpNext()
    }

    func removeFromQueue(id: UUID) { queue.removeQueued(id: id); refreshUpNext() }
    func clearQueue() { queue.clearQueue(); refreshUpNext() }
    private func refreshUpNext() { upNext = queue.queuedItems() }

    // MARK: - Playback core

    /// Reset everything and start feeding from `track` at `offset` seconds.
    private func beginPlayback(_ track: Track, offset: TimeInterval) {
        reachedEnd = false
        currentTrack = track
        duration = track.duration ?? 0
        currentTime = offset
        lastReportedTrackID = nil

        node.stop()
        segments.reset()

        let gen = generation &+ 1
        generation = gen

        do {
            if !engine.isRunning { try engine.start() }
        } catch { print("engine start failed: \(error)") }

        feedQueue.async { [weak self] in
            guard let self else { return }
            self.currentDecoder = nil
            self.cumulativeScheduledFrames = 0
            self.pendingFrames = 0
            self.noMoreAudio = false
            self.openDecoder(for: track, offset: offset, generation: gen)
            self.feedIfNeeded(generation: gen)
        }

        node.play()
        isPlaying = true
        startTicker()
        onTrackStarted?(track)
        updateNowPlayingInfo()
        loadArtwork(for: track)
    }

    private func endPlayback() {
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
        guard gen == generation else { return }
        while pendingFrames < targetBufferedFrames {
            guard let buffer = nextChunk(generation: gen) else {
                noMoreAudio = true
                DispatchQueue.main.async { [weak self] in self?.markPossibleEnd() }
                return
            }
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
            currentTrack = seg.track
            duration = seg.duration
            onTrackStarted?(seg.track)
            loadArtwork(for: seg.track)
        }

        currentTime = seg.startOffset + Double(frame - seg.startFrame) / CanonicalAudio.sampleRate
        updateNowPlayingInfo()
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
        isPlaying = false
        reachedEnd = true
        stopTicker()
        updateNowPlayingInfo()
    }

    // MARK: - Artwork / Now Playing

    private(set) var currentArtwork: PlatformImage?

    private func loadArtwork(for track: Track) {
        currentArtwork = nil
        guard track.hasArtwork else { return }
        let url = track.url
        Task.detached(priority: .utility) {
            let meta = FFmpegMetadata.read(url: url, includeArtwork: true)
            guard let data = meta.artwork, let image = PlatformImage(data: data) else { return }
            await MainActor.run { [weak self] in
                guard let self, self.currentTrack?.url == url else { return }
                self.currentArtwork = image
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

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif
