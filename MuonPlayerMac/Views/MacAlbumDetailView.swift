import SwiftUI

struct MacAlbumDetailView: View {
    /// Held as state, not a constant: an album's identity is its artist, title and
    /// year, so editing any of those makes the value we were pushed with name an
    /// album that no longer exists. `reload()` re-resolves it.
    @State private var album: Album
    private let focusPath: String?

    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player
    @Environment(MacRouter.self) private var router
    @State private var tracks: [Track] = []
    @State private var editing = false
    @State private var didFocus = false

    init(album: Album, focusPath: String? = nil) {
        _album = State(initialValue: album)
        self.focusPath = focusPath
    }

    private var totalDuration: TimeInterval {
        tracks.compactMap(\.duration).reduce(0, +)
    }

    /// Every folder this album's files live in — the scope of the Refresh button.
    private var folders: [URL] {
        Array(Set(tracks.map { $0.url.deletingLastPathComponent() }))
    }

    /// The same release often sits on disk twice (a FLAC rip and an MP3 rip) and
    /// both fold into one album. Give each folder its own section rather than
    /// letting the rips interleave. `tracks` already arrives folder-ordered, so a
    /// single pass preserves that order without sorting again.
    private var folderGroups: [(folder: String, tracks: [Track])] {
        var groups: [(String, [Track])] = []
        for track in tracks {
            let folder = library.relativeFolder(for: track)
            if groups.last?.0 == folder {
                groups[groups.count - 1].1.append(track)
            } else {
                groups.append((folder, [track]))
            }
        }
        return groups.map { (folder: $0.0, tracks: $0.1) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section { header.listRowSeparator(.hidden) }
                // With one folder the heading is noise; with several it's the point.
                if folderGroups.count <= 1 {
                    Section {
                        ForEach(tracks) { track in
                            MacTrackRow(track: track, context: tracks, showNumber: true, showFolder: false)
                                .id(track.url.path)
                        }
                    }
                } else {
                    ForEach(folderGroups, id: \.folder) { group in
                        Section {
                            // Context is the folder, not the album: playing a track
                            // from the FLAC rip should continue through the FLAC rip.
                            ForEach(group.tracks) { track in
                                MacTrackRow(track: track, context: group.tracks, showNumber: true, showFolder: false)
                                    .id(track.url.path)
                            }
                        } header: {
                            folderHeader(group)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .overlay {
                if tracks.isEmpty {
                    ContentUnavailableView("Album Is Gone", systemImage: "questionmark.folder",
                                           description: Text("Its files are no longer in the library."))
                }
            }
            .task(id: library.version) { await reload(scrollingWith: proxy) }
        }
        .navigationTitle(album.title)
        .toolbar {
            ToolbarItem {
                Button { Task { await library.refresh(folders: folders) } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Re-read this album's files from disk")
                .disabled(library.isScanning || tracks.isEmpty)
            }
            ToolbarItem {
                Button { editing = true } label: { Label("Edit Tags", systemImage: "tag") }
                    .disabled(tracks.isEmpty)
            }
        }
        .sheet(isPresented: $editing) { MacTagEditView(scope: .album(album)) }
    }

    /// Reload the track list, following the album if a tag edit renamed it. The
    /// files themselves never move, so any one of their paths identifies the album
    /// afterwards.
    private func reload(scrollingWith proxy: ScrollViewProxy) async {
        var target = album
        var loaded = await library.tracks(in: target)
        if loaded.isEmpty, let anchor = tracks.first?.url.path ?? focusPath,
           let moved = await library.album(containingPath: anchor) {
            target = moved
            loaded = await library.tracks(in: moved)
        }
        album = target
        tracks = loaded

        guard let focusPath, !didFocus, loaded.contains(where: { $0.url.path == focusPath }) else { return }
        didFocus = true
        // The rows this scrolls to are the ones `tracks` just produced; give the
        // List a beat to lay them out before asking it to find one.
        try? await Task.sleep(for: .milliseconds(80))
        withAnimation { proxy.scrollTo(focusPath, anchor: .center) }
    }

    private func folderHeader(_ group: (folder: String, tracks: [Track])) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(group.folder)
                .lineLimit(1)
                .truncationMode(.head)
                .help(group.folder)
            Text(formatSummary(group.tracks))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            Button {
                guard let first = group.tracks.first else { return }
                player.play(track: first, context: group.tracks)
            } label: {
                Image(systemName: "play.fill").font(.caption2)
            }
            .buttonStyle(.borderless)
            .help("Play this folder")
        }
        .textCase(nil)
        .contextMenu {
            RevealInFinderButton(url: group.tracks.first?.url.deletingLastPathComponent())
        }
    }

    /// "FLAC · 1006 kbps", or just the codecs when the rips differ in bitrate.
    private func formatSummary(_ tracks: [Track]) -> String {
        let codecs = Set(tracks.map(\.formatLabel)).sorted()
        let rates = Set(tracks.compactMap(\.bitrateKbps))
        let codec = codecs.joined(separator: "/")
        guard rates.count == 1, let kbps = rates.first else { return codec }
        return "\(codec) · \(kbps) kbps"
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            ArtworkView(path: album.artworkPath, cornerRadius: 8)
                .frame(width: 168, height: 168)
                .shadow(radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 6) {
                Text(album.title).font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)

                Button { router.openArtist(album.artist) } label: {
                    Text(album.artist).font(.title3).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Text(subtitle).font(.caption).foregroundStyle(.tertiary)

                // When the album exists as several rips, "Play" means the first
                // one — not all of them end to end.
                let primary = folderGroups.first?.tracks ?? tracks

                HStack(spacing: 8) {
                    Button {
                        guard let first = primary.first else { return }
                        player.play(track: first, context: primary)
                    } label: { Label("Play", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)

                    Button {
                        for track in primary { player.enqueue(track, context: primary) }
                    } label: { Label("Add to Queue", systemImage: "text.append") }
                }
                .disabled(tracks.isEmpty)
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .contextMenu {
            Button("Edit Tags…") { editing = true }
            RevealInFinderButton(url: tracks.first?.url)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let year = album.year { parts.append(String(year)) }
        parts.append("\(tracks.count) track\(tracks.count == 1 ? "" : "s")")
        if totalDuration > 0 { parts.append(formatDuration(totalDuration)) }
        return parts.joined(separator: " · ")
    }
}
