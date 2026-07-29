#if os(Android)
import Foundation
import CFFmpeg
import CSQLite

/// What the Android UI can ask of the core today. Kept deliberately small: it
/// exists to prove the Swift core, FFmpeg and SQLite all link into the APK and
/// run on a device, and it grows into the real library API from here.
public enum MuonCore {
    public static var ffmpegVersion: String {
        let v = avcodec_version()
        return "\(v >> 16).\((v >> 8) & 0xff).\(v & 0xff)"
    }

    public static var sqliteVersion: String {
        String(cString: sqlite3_libversion())
    }

    public static var supportedExtensions: [String] {
        AudioFormat.supportedExtensions.sorted()
    }

    /// Scan a directory and report what the shared FileScanner made of it, so the
    /// first thing exercised on Android is real library code and not a stub.
    public static func scan(path: String) -> [String] {
        FileScanner(roots: [URL(fileURLWithPath: path)])
            .findAudioFiles()
            .map { $0.lastPathComponent }
    }

    /// Every audio file under `path`, described by its tags rather than its name.
    public static func scanWithTags(path: String) -> [String] {
        FileScanner(roots: [URL(fileURLWithPath: path)])
            .findAudioFiles()
            .map { metadataSummary(path: $0.path) }
    }

    /// Read a file's tags through the shared FFmpeg metadata reader.
    public static func metadataSummary(path: String) -> String {
        let meta = FFmpegMetadata.read(url: URL(fileURLWithPath: path), includeArtwork: false)
        let title = meta.title ?? URL(fileURLWithPath: path).lastPathComponent
        let artist = meta.artist ?? "Unknown artist"
        let seconds = meta.duration.map { String(format: "%.1fs", $0) } ?? "?"
        return "\(artist) — \(title) (\(seconds))"
    }
}
#endif
