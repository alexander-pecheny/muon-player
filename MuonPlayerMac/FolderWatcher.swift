import CoreServices
import Foundation

extension Notification.Name {
    static let libraryFoldersChangedOnDisk = Notification.Name("MuonLibraryFoldersChangedOnDisk")
}

/// Posts when anything changes under the library roots, so music added while the
/// app is behind something else appears without waiting for an activation.
///
/// A poke, not a source of truth: the event says nothing the scan needs, because a
/// pass is now a stat per folder. So dropped events, wrapped ids and
/// `MustScanSubDirs` all reduce to what every event means anyway — run the cheap
/// pass. Activation keeps its own rescan for network volumes, where FSEvents
/// cannot see a remote writer.
@MainActor
final class FolderWatcher {
    private nonisolated(unsafe) var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "me.pecheny.muonplayer.fsevents")

    func watch(_ paths: [String]) {
        stop()
        guard !paths.isEmpty else { return }
        let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagNoDefer
        guard let stream = FSEventStreamCreate(
            nil,
            { _, _, _, _, _, _ in
                NotificationCenter.default.post(name: .libraryFoldersChangedOnDisk, object: nil)
            },
            nil, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
            FSEventStreamCreateFlags(flags)) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        if let stream { Self.tearDown(stream) }
        stream = nil
    }

    deinit { if let stream { Self.tearDown(stream) } }

    private nonisolated static func tearDown(_ stream: FSEventStreamRef) {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
