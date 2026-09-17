import SwiftUI

struct AlbumDetailView: View {
    /// Held as state, not a constant: an album's identity is its artist, title and
    /// year, so editing any of those makes the value we were pushed with name an
    /// album that no longer exists. `reload()` re-resolves it.
    @State private var album: Album
    private let focusPath: String?

    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player
    @State private var tracks: [Track] = []
    @State private var editingAlbum = false
    @State private var editingTrack: Track?
    @State private var didFocus = false
    @State private var loaded = false
    @State private var zoomingArtwork = false
    // This album's own artwork color, independent of what's playing — so a red
    // album never gets tinted by a green now-playing track (and vice versa).
    @State private var albumAccent: Color = .neutralAccent
    @Environment(\.navPath) private var navPath
    @State private var pendingDelete: PendingDelete?

    init(album: Album, focusPath: String? = nil) {
        _album = State(initialValue: album)
        self.focusPath = focusPath
    }

    var body: some View {
        ScrollViewReader { proxy in
            content(proxy)
        }
    }

    private func content(_ proxy: ScrollViewProxy) -> some View {
        List {
            Section {
                VStack(spacing: 12) {
                    ArtworkView(path: album.artworkPath, cornerRadius: 12, contentMode: .fit)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 320)
                        .shadow(radius: 8, y: 4)
                        .padding(.top, 8)
                        .onTapGesture { zoomingArtwork = album.artworkPath != nil }

                    VStack(spacing: 2) {
                        Text(album.title).font(.title3.bold()).multilineTextAlignment(.center)
                        Button { navPath?.wrappedValue.append(.artist(ArtistRef(name: album.artist))) } label: {
                            Text(album.artist).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .buttonStyle(.plain)
                        Text(trackCountLine)
                            .font(.caption).foregroundStyle(.tertiary)
                        // With several rips each section states its own format, and
                        // the album-wide one would only ever say "Mixed".
                        if folderGroups.count <= 1, let fmt = Self.formatSummary(tracks) {
                            Text(fmt).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        }
                    }

                    // When the album exists as several rips, "Play" means the first
                    // one — not all of them end to end.
                    let primary = folderGroups.first?.tracks ?? tracks

                    HStack(spacing: 12) {
                        Button {
                            if let first = primary.first { player.play(track: first, context: primary) }
                        } label: {
                            Label("Play", systemImage: "play.fill")
                                .labelStyle(.titleAndIcon)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            for t in primary { player.enqueue(t, context: primary) }
                        } label: {
                            Label("Enqueue", systemImage: "text.append")
                                .labelStyle(.titleAndIcon)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal)
                }
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                // The Play/Queue buttons already divide header from tracklist.
                .listRowSeparator(.hidden)
            }

            // With one folder the heading is noise; with several it's the point.
            if folderGroups.count <= 1 {
                Section { trackRows(tracks) }
            } else {
                ForEach(folderGroups, id: \.folder) { group in
                    Section { trackRows(group.tracks) } header: { folderHeader(group) }
                }
            }
        }
        .listStyle(.plain)
        // Tint the whole album view (Play button, current-track highlight, swipe
        // action) with the album's own color rather than the app-wide now-playing
        // accent. The mini player outside this view keeps the now-playing color.
        .tint(albumAccent)
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    albumMenu
                } label: { Image(systemName: "ellipsis.circle") }
                // The toolbar lives in the nav bar, outside the List's `.tint`, so
                // it otherwise inherits the app-wide now-playing accent. Pin it to
                // this album's own color to match the rest of the view.
                .tint(albumAccent)
            }
        }
        .deleteConfirmation($pendingDelete)
        .sheet(isPresented: $editingAlbum) { TagEditView(scope: .album(album)) }
        .fullScreenCover(isPresented: $zoomingArtwork) {
            if let path = album.artworkPath { ArtworkZoomView(path: path) }
        }
        .sheet(item: $editingTrack) { t in TagEditView(scope: .track(t)) }
        .overlay {
            if loaded && tracks.isEmpty {
                ContentUnavailableView("Album Is Gone", systemImage: "questionmark.folder",
                                       description: Text("Its files are no longer in the library."))
            }
        }
        .task(id: library.version) { await reload(scrollingWith: proxy) }
        .task(id: album.artworkPath) {
            guard let path = album.artworkPath,
                  let image = await library.artwork(forPath: path) else {
                albumAccent = .neutralAccent; return
            }
            albumAccent = DominantColor.from(image) ?? .neutralAccent
        }
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
        self.loaded = true

        guard let focusPath, !didFocus, loaded.contains(where: { $0.url.path == focusPath }) else { return }
        didFocus = true
        // The rows this scrolls to are the ones `tracks` just produced; give the
        // List a beat to lay them out before asking it to find one.
        try? await Task.sleep(for: .milliseconds(80))
        withAnimation { proxy.scrollTo(focusPath, anchor: .center) }
    }

    /// The same release often sits on disk twice (a FLAC rip and an MP3 rip) and
    /// both fold into one album. Give each rip its own section rather than letting
    /// them interleave.
    private var folderGroups: [(folder: String, tracks: [Track])] {
        LibraryStore.ripGroups(tracks) { library.relativeFolder(for: $0) }
    }

    /// Rows for one folder. Context is the folder, not the album: playing a track
    /// from the FLAC rip should continue through the FLAC rip.
    @ViewBuilder private func trackRows(_ group: [Track]) -> some View {
        ForEach(group) { track in
            TrackRow(track: track, isCurrent: player.currentTrack?.url == track.url,
                     hideArtist: artistMatchesAlbum(track), accent: albumAccent)
                .id(track.url.path)
                .contentShape(Rectangle())
                .onTapGesture { player.play(track: track, context: group) }
                .swipeActions(edge: .trailing) {
                    Button {
                        player.enqueue(track, context: group)
                    } label: { Label("Enqueue", systemImage: "text.append") }
                    .tint(albumAccent)
                }
                .contextMenu { trackMenu(track, context: group) }
                // No dangling rule above the first or below the last track.
                .listRowSeparator(track.url == group.first?.url ? .hidden : .automatic, edges: .top)
                .listRowSeparator(track.url == group.last?.url ? .hidden : .automatic, edges: .bottom)
        }
    }

    private func folderHeader(_ group: (folder: String, tracks: [Track])) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                // The leaf folder is what tells two rips apart, so keep its end
                // visible and drop the path in front of it.
                Text(group.folder).lineLimit(1).truncationMode(.head)
                Text(Self.summaryLine(group.tracks)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Button {
                guard let first = group.tracks.first else { return }
                player.play(track: first, context: group.tracks)
            } label: {
                Image(systemName: "play.fill").font(.caption)
            }
            .buttonStyle(.borderless)
            .tint(albumAccent)
        }
        .font(.caption)
        .textCase(nil)
    }

    // MARK: Menus

    @ViewBuilder private var albumMenu: some View {
        Button { navPath?.wrappedValue.append(.artist(ArtistRef(name: album.artist))) } label: {
            Label("Go to Artist", systemImage: "music.mic")
        }
        // The rip the header's buttons act on, so the menu never quietly queues
        // the album twice over.
        let primary = folderGroups.first?.tracks ?? tracks
        Button { for t in primary { player.enqueue(t, context: primary) } } label: {
            Label("Add Album to Queue", systemImage: "text.append")
        }
        Button { editingAlbum = true } label: {
            Label("Edit Tags", systemImage: "tag")
        }
        Button(role: .destructive) {
            pendingDelete = PendingDelete(
                title: "Delete “\(album.title)”?",
                message: "\(tracks.count) track\(tracks.count == 1 ? "" : "s") will be removed from this iPhone."
            ) { [tracks] in
                await library.delete(tracks: tracks)
                if let path = navPath, !path.wrappedValue.isEmpty { path.wrappedValue.removeLast() }
            }
        } label: {
            Label("Delete Album", systemImage: "trash")
        }
    }

    @ViewBuilder private func trackMenu(_ track: Track, context: [Track]) -> some View {
        Button { navPath?.wrappedValue.append(.artist(ArtistRef(name: album.artist))) } label: {
            Label("Go to Artist", systemImage: "music.mic")
        }
        Button { player.enqueue(track, context: context) } label: {
            Label("Add Track to Queue", systemImage: "text.append")
        }
        Button { editingTrack = track } label: {
            Label("Edit Tags", systemImage: "tag")
        }
    }

    // MARK: Helpers

    /// Item #4: in the album view, don't repeat the artist name on each track when
    /// it's the same as the album artist.
    private func artistMatchesAlbum(_ track: Track) -> Bool {
        guard let a = track.artist else { return true }
        return a.caseInsensitiveCompare(album.artist) == .orderedSame
    }

    /// "2005 · 12 tracks · 43:12". The count and the running time both come from
    /// the rows on screen, so an album held twice reads as the two rips it is.
    private var trackCountLine: String {
        var parts: [String] = []
        if let year = album.year { parts.append(String(year)) }
        let count = tracks.isEmpty ? album.trackCount : tracks.count
        parts.append("\(count) track\(count == 1 ? "" : "s")")
        let total = tracks.compactMap(\.duration).reduce(0, +)
        if total > 0 { parts.append(formatDuration(total)) }
        return parts.joined(separator: " · ")
    }

    /// Item #5: format + bitrate summary for a set of tracks.
    private static func formatSummary(_ tracks: [Track]) -> String? {
        guard !tracks.isEmpty else { return nil }
        let fmts = Set(tracks.map { $0.formatLabel })
        let fmt = fmts.count == 1 ? (fmts.first ?? "") : "Mixed"
        let brs = tracks.compactMap { $0.bitrateKbps }
        guard let lo = brs.min(), let hi = brs.max() else { return fmt }
        let br = lo == hi ? "\(lo) kbps" : "\(lo)–\(hi) kbps"
        return "\(fmt) · \(br)"
    }

    /// A folder section's format, bitrate and running time.
    private static func summaryLine(_ tracks: [Track]) -> String {
        let total = tracks.compactMap(\.duration).reduce(0, +)
        return [formatSummary(tracks), total > 0 ? formatDuration(total) : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

struct TrackRow: View {
    let track: Track
    var isCurrent: Bool = false
    /// When true, the artist subtitle is suppressed (album view, same artist).
    var hideArtist: Bool = false
    /// Accent for the current-track highlight — the album's artwork color.
    var accent: Color = .neutralAccent

    var body: some View {
        HStack(spacing: 12) {
            if let n = track.trackNo {
                Text("\(n)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: 24, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .foregroundStyle(isCurrent ? accent : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if !hideArtist, let artist = track.artist {
                    Text(artist).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(accent)
            }
            if let d = track.duration {
                Text(formatDuration(d)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

