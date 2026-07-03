import Foundation

/// Finds audio files under a root directory (the app's Documents folder, which
/// surfaces as "On My iPhone → MuonPlayer" in the Files app).
final class FileScanner: Sendable {
    let rootURL: URL

    init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    /// Audio file URLs found under the root, sorted by path.
    func findAudioFiles() -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            if AudioFormat.supportedExtensions.contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Convenience used by tests: audio files as bare Tracks (no metadata).
    func scan() async -> [Track] {
        findAudioFiles().map { Track(url: $0) }
    }
}
