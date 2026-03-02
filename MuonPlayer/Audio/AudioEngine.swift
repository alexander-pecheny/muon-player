import AVFoundation
import MediaPlayer

@Observable
@MainActor
final class AudioEngine {
    private(set) var currentTrack: Track?
    private(set) var isPlaying: Bool = false
    private(set) var duration: TimeInterval = 0

    var currentTime: TimeInterval {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return 0
        }
        return Double(playerTime.sampleTime) / playerTime.sampleRate + seekOffset
    }

    private(set) var playlist: [Track] = []
    private(set) var currentIndex: Int = 0

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var seekOffset: TimeInterval = 0
    private var isEngineSetup = false

    init() {
        setupEngine()
        setupRemoteCommands()
    }

    // MARK: - Engine Setup

    private func setupEngine() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
        isEngineSetup = true
    }

    // MARK: - Playback Controls

    func loadPlaylist(_ tracks: [Track], startingAt index: Int = 0) {
        playlist = tracks
        currentIndex = min(index, max(tracks.count - 1, 0))
    }

    func play(track: Track, playlist: [Track]? = nil) {
        if let playlist {
            self.playlist = playlist
            if let index = playlist.firstIndex(where: { $0.id == track.id }) {
                currentIndex = index
            }
        }

        stopCurrentPlayback()
        loadAndPlay(track: track)
    }

    func pause() {
        playerNode.pause()
        engine.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }

    func resume() {
        do {
            try engine.start()
            playerNode.play()
            isPlaying = true
            updateNowPlayingInfo()
        } catch {
            print("Failed to resume engine: \(error)")
        }
    }

    func stop() {
        stopCurrentPlayback()
        currentTrack = nil
        isPlaying = false
        duration = 0
        seekOffset = 0
        clearNowPlayingInfo()
    }

    func next() {
        guard !playlist.isEmpty else { return }
        let nextIndex = currentIndex + 1
        if nextIndex < playlist.count {
            currentIndex = nextIndex
            stopCurrentPlayback()
            loadAndPlay(track: playlist[nextIndex])
        } else {
            stop()
        }
    }

    func previous() {
        guard !playlist.isEmpty else { return }
        // If more than 3 seconds in, restart current track
        if currentTime > 3 {
            stopCurrentPlayback()
            loadAndPlay(track: playlist[currentIndex])
            return
        }

        let prevIndex = currentIndex - 1
        if prevIndex >= 0 {
            currentIndex = prevIndex
            stopCurrentPlayback()
            loadAndPlay(track: playlist[prevIndex])
        } else {
            // At first track — restart it
            stopCurrentPlayback()
            loadAndPlay(track: playlist[currentIndex])
        }
    }

    func seek(to time: TimeInterval) {
        guard let track = currentTrack else { return }

        playerNode.stop()

        guard let audioFile = try? AVAudioFile(forReading: track.url) else { return }

        let sampleRate = audioFile.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(time * sampleRate)
        let totalFrames = audioFile.length
        let remainingFrames = AVAudioFrameCount(totalFrames - startFrame)

        guard remainingFrames > 0 else { return }

        seekOffset = time

        playerNode.scheduleSegment(
            audioFile,
            startingFrame: startFrame,
            frameCount: remainingFrames,
            at: nil
        ) { [weak self] in
            Task { @MainActor in
                self?.onTrackFinished()
            }
        }

        playerNode.play()
        isPlaying = true
        updateNowPlayingInfo()
    }

    // MARK: - Private

    private func loadAndPlay(track: Track) {
        guard let audioFile = try? AVAudioFile(forReading: track.url) else {
            print("Failed to open audio file: \(track.url)")
            return
        }

        let format = audioFile.processingFormat

        // Reconnect with the correct format
        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)

        seekOffset = 0
        currentTrack = track
        duration = Double(audioFile.length) / format.sampleRate

        playerNode.scheduleFile(audioFile, at: nil) { [weak self] in
            Task { @MainActor in
                self?.onTrackFinished()
            }
        }

        do {
            try engine.start()
            playerNode.play()
            isPlaying = true
            updateNowPlayingInfo()
        } catch {
            print("Failed to start engine: \(error)")
        }
    }

    private func stopCurrentPlayback() {
        playerNode.stop()
        engine.stop()
        seekOffset = 0
    }

    private func onTrackFinished() {
        guard isPlaying else { return }
        next()
    }

    // MARK: - Now Playing Info

    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }

        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        var info: [String: Any] = [:]
        if let track = currentTrack {
            info[MPMediaItemPropertyTitle] = track.title
            if let artist = track.artist {
                info[MPMediaItemPropertyArtist] = artist
            }
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
            info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
