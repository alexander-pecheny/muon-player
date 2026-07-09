import Foundation

/// Finds audio files under the library's root folders. On iOS that is the single
/// Documents folder (which surfaces as "On My iPhone → MuonPlayer" in the Files
/// app); on macOS it is however many folders the user added.
final class FileScanner: Sendable {
    let roots: [URL]

    init(roots: [URL]) {
        self.roots = roots
    }

    /// Convenience for tests and the single-root iOS app.
    convenience init(rootURL: URL? = nil) {
        self.init(roots: [rootURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!])
    }

    var rootURL: URL { roots[0] }

    /// Audio file URLs found under the roots, deduplicated and sorted by path.
    /// Nested roots (a folder and its parent both added) would otherwise yield
    /// the same file twice and make the scan do double work.
    func findAudioFiles() -> [URL] {
        var seen = Set<String>()
        var files: [URL] = []
        for root in roots {
            for url in Self.audioFiles(under: root) where seen.insert(url.path).inserted {
                files.append(url)
            }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func audioFiles(under root: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            if AudioFormat.supportedExtensions.contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }
        return files
    }

    /// Convenience used by tests: audio files as bare Tracks (no metadata).
    func scan() async -> [Track] {
        findAudioFiles().map { Track(url: $0) }
    }
}
