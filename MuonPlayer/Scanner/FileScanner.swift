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
    ///
    /// `onProgress` is called with the running count as directories are walked —
    /// on a large library this pass takes long enough that the UI needs to say
    /// something other than "working".
    func findAudioFiles(onProgress: (@Sendable (Int) -> Void)? = nil) -> [URL] {
        let fm = FileManager.default
        var seen = Set<String>()
        var files: [URL] = []

        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator {
                guard AudioFormat.supportedExtensions.contains(url.pathExtension.lowercased()),
                      seen.insert(url.path).inserted else { continue }
                files.append(url)
                if files.count % 200 == 0 { onProgress?(files.count) }
            }
        }

        onProgress?(files.count)
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Convenience used by tests: audio files as bare Tracks (no metadata).
    func scan() async -> [Track] {
        findAudioFiles().map { Track(url: $0) }
    }
}
