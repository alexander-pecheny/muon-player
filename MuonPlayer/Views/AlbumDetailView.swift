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
    // This album's own artwork color, independent of what's playing — so a red
    // album never gets tinted by a green now-playing track (and vice versa).
    @State private var albumAccent: Color = .neutralAccent
    @Environment(\.navPath) private var navPath

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
                    ArtworkView(path: album.artworkPath, cornerRadius: 12)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 320)
                        .shadow(radius: 8, y: 4)
                        .padding(.top, 8)

                    VStack(spacing: 2) {
                        Text(album.title).font(.title3.bold()).multilineTextAlignment(.center)
                        Button { navPath?.wrappedValue.append(ArtistRef(name: album.artist)) } label: {
                            Text(album.artist).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .buttonStyle(.plain)
                        Text(trackCountLine)
                            .font(.caption).tertiaryForeground()
                        if let fmt = formatSummary {
                            Text(fmt).font(.caption.tabularDigits).tertiaryForeground()
                        }
                    }

                    HStack(spacing: 12) {
                        Button {
                            if let first = tracks.first { player.play(track: first, context: tracks) }
                        } label: {
                            Label("Play", systemImage: "play.fill")
                                .labelStyle(.titleAndIcon)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            for t in tracks { player.enqueue(t, context: tracks) }
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
                .flushListRow()
                .listRowBackground(Color.clear)
                // The Play/Queue buttons already divide header from tracklist.
                .listRowSeparator(.hidden)
            }

            Section {
                ForEach(tracks) { track in
                    TrackRow(track: track, isCurrent: player.currentTrack?.url == track.url,
                             hideArtist: artistMatchesAlbum(track), accent: albumAccent)
                        .id(track.url.path)
                        .tappableRow()
                        .onTapGesture { player.play(track: track, context: tracks) }
                        .swipeActions(edge: .trailing) {
                            Button {
                                player.enqueue(track, context: tracks)
                            } label: { Label("Enqueue", systemImage: "text.append") }
                            .tint(albumAccent)
                        }
                        .contextMenu { trackMenu(track) }
                        // No dangling rule above the first or below the last track.
                        .listRowSeparator(track.url == tracks.first?.url ? .hidden : .automatic, edges: .top)
                        .listRowSeparator(track.url == tracks.last?.url ? .hidden : .automatic, edges: .bottom)
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
        .sheet(isPresented: $editingAlbum) { TagEditView(scope: .album(album)) }
        .sheet(item: $editingTrack) { t in TagEditView(scope: .track(t)) }
        .overlay {
            if tracks.isEmpty {
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

        guard let focusPath, !didFocus, loaded.contains(where: { $0.url.path == focusPath }) else { return }
        didFocus = true
        // The rows this scrolls to are the ones `tracks` just produced; give the
        // List a beat to lay them out before asking it to find one.
        try? await Task.sleep(for: .milliseconds(80))
        withAnimation { proxy.scrollTo(focusPath, anchor: .center) }
    }

    // MARK: Menus

    @ViewBuilder private var albumMenu: some View {
        Button { navPath?.wrappedValue.append(ArtistRef(name: album.artist)) } label: {
            Label("Go to Artist", systemImage: "music.mic")
        }
        Button { for t in tracks { player.enqueue(t, context: tracks) } } label: {
            Label("Add Album to Queue", systemImage: "text.append")
        }
        Button { editingAlbum = true } label: {
            Label("Edit Tags", systemImage: "tag")
        }
    }

    @ViewBuilder private func trackMenu(_ track: Track) -> some View {
        Button { navPath?.wrappedValue.append(ArtistRef(name: album.artist)) } label: {
            Label("Go to Artist", systemImage: "music.mic")
        }
        Button { player.enqueue(track, context: tracks) } label: {
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

    private var trackCountLine: String {
        let count = "\(album.trackCount) track\(album.trackCount == 1 ? "" : "s")"
        guard let year = album.year else { return count }
        return "\(year) · \(count)"
    }

    /// Item #5: format + bitrate summary for the album.
    private var formatSummary: String? {
        guard !tracks.isEmpty else { return nil }
        let fmts = Set(tracks.map { $0.formatLabel })
        let fmt = fmts.count == 1 ? (fmts.first ?? "") : "Mixed"
        let brs = tracks.compactMap { $0.bitrateKbps }
        guard let lo = brs.min(), let hi = brs.max() else { return fmt }
        let br = lo == hi ? "\(lo) kbps" : "\(lo)–\(hi) kbps"
        return "\(fmt) · \(br)"
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
                    .font(.footnote.tabularDigits)
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
                Text(formatDuration(d)).font(.caption.tabularDigits).foregroundStyle(.secondary)
            }
        }
    }
}

