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

    /// Cover images sitting beside the music. Used when a track carries no embedded
    /// artwork of its own, which is the normal state of a folder full of Opus or of a
    /// rip whose tagger never bothered.
    enum FolderArt {
        static let extensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif"]

        /// Lower is better. A file called `cover` is what the folder means by its
        /// cover; anything else is a guess, and a picture of the back of the sleeve
        /// beats no picture at all.
        static func rank(_ name: String) -> Int? {
            let url = URL(fileURLWithPath: name)
            guard extensions.contains(url.pathExtension.lowercased()) else { return nil }
            switch url.deletingPathExtension().lastPathComponent.lowercased() {
            case "cover": return 0
            case "folder": return 1
            case "front": return 2
            case "album", "albumart", "albumartsmall": return 3
            default: return 4
            }
        }
    }

    /// Audio file URLs found under the roots, deduplicated and sorted by path.
    /// Nested roots (a folder and its parent both added) would otherwise yield
    /// the same file twice and make the scan do double work.
    ///
    /// `onProgress` is called with the running count as directories are walked —
    /// on a large library this pass takes long enough that the UI needs to say
    /// something other than "working".
    func findAudioFiles(onProgress: (@Sendable (Int) -> Void)? = nil) -> [URL] {
        findAudioFilesAndArt(onProgress: onProgress).files
    }

    /// The same walk, also noting the best cover image in every folder it passes.
    /// The images cost nothing extra: the enumerator yields them either way.
    func findAudioFilesAndArt(
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) -> (files: [URL], art: [String: String]) {
        let fm = FileManager.default
        var seen = Set<String>()
        var files: [URL] = []
        var art: [String: (rank: Int, path: String)] = [:]

        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator {
                if AudioFormat.supportedExtensions.contains(url.pathExtension.lowercased()) {
                    guard seen.insert(url.path).inserted else { continue }
                    files.append(url)
                    if files.count % 200 == 0 { onProgress?(files.count) }
                } else if let rank = FolderArt.rank(url.lastPathComponent) {
                    let folder = url.deletingLastPathComponent().path
                    if art[folder] == nil || rank < art[folder]!.rank {
                        art[folder] = (rank, url.path)
                    }
                }
            }
        }

        onProgress?(files.count)
        return (files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
                art.mapValues(\.path))
    }

    /// Convenience used by tests: audio files as bare Tracks (no metadata).
    func scan() async -> [Track] {
        findAudioFiles().map { Track(url: $0) }
    }
}
