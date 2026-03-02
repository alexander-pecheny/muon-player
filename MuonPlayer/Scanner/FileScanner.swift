import Foundation
import AVFoundation

final class FileScanner: Sendable {
    private let rootURL: URL

    init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    func scan() async -> [Track] {
        let fileURLs = findAudioFiles(in: rootURL)
        var tracks: [Track] = []

        for url in fileURLs {
            let track = await loadTrack(from: url)
            tracks.append(track)
        }

        return tracks
    }

    private func findAudioFiles(in directory: URL) -> [URL] {
        var audioFiles: [URL] = []
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            if AudioFormat.supportedExtensions.contains(ext) {
                audioFiles.append(fileURL)
            }
        }

        return audioFiles.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func loadTrack(from url: URL) async -> Track {
        let asset = AVURLAsset(url: url)

        var title: String?
        var artist: String?
        var duration: TimeInterval?

        do {
            let durationValue = try await asset.load(.duration)
            duration = durationValue.seconds.isFinite ? durationValue.seconds : nil

            let metadata = try await asset.load(.commonMetadata)
            for item in metadata {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle:
                    title = try await item.load(.stringValue)
                case .commonKeyArtist:
                    artist = try await item.load(.stringValue)
                default:
                    break
                }
            }
        } catch {
            // Metadata loading failed — use filename as fallback
        }

        return Track(url: url, title: title, artist: artist, duration: duration)
    }
}
