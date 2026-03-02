import Foundation

enum AudioFormat: String, Sendable {
    case mp3
    case m4a
    case aac
    case aif
    case aiff
    case wav
    case caf
    case unknown

    static let supportedExtensions: Set<String> = ["mp3", "m4a", "aac", "aif", "aiff", "wav", "caf"]

    init(fileExtension: String) {
        self = AudioFormat(rawValue: fileExtension.lowercased()) ?? .unknown
    }
}

struct Track: Identifiable, Sendable {
    let id: UUID
    let url: URL
    let title: String
    let artist: String?
    let duration: TimeInterval?
    let format: AudioFormat

    init(id: UUID = UUID(), url: URL, title: String? = nil, artist: String? = nil, duration: TimeInterval? = nil) {
        self.id = id
        self.url = url
        self.title = title ?? Track.displayName(from: url)
        self.artist = artist
        self.duration = duration
        self.format = AudioFormat(fileExtension: url.pathExtension)
    }

    static func displayName(from url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}
