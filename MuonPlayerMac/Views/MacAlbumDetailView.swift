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
    @Environment(SendToPhone.self) private var sendToPhone
    @State private var tracks: [Track] = []
    @State private var editing = false
    @State private var size: CGSize = .zero
    @Environment(\.openWindow) private var openWindow
    @State private var didFocus = false
    // This album's own artwork color, independent of what's playing — so a red
    // album never gets tinted by a green now-playing track (and vice versa).
    @State private var albumAccent: Color = .neutralAccent

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
        GeometryReader { geo in
            ScrollViewReader { proxy in
                List {
                    Section { header.listRowSeparator(.hidden) }
                    // With one folder the heading is noise; with several it's the point.
                    if folderGroups.count <= 1 {
                        Section { trackRows(tracks) }
                    } else {
                        ForEach(folderGroups, id: \.folder) { group in
                            // Context is the folder, not the album: playing a track
                            // from the FLAC rip should continue through the FLAC rip.
                            Section { trackRows(group.tracks) } header: { folderHeader(group) }
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
                .onChange(of: geo.size, initial: true) { size = geo.size }
                .task(id: library.version) { await reload(scrollingWith: proxy) }
            }
        }
        // The album page wears its own color (Play button, current-track row); the
        // player bar and sidebar outside it keep the now-playing one.
        .artworkAccent(albumAccent)
        .task(id: album.artworkPath) {
            guard let path = album.artworkPath,
                  let image = await library.artwork(forPath: path) else {
                albumAccent = .neutralAccent; return
            }
            albumAccent = DominantColor.from(image) ?? .neutralAccent
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

    /// A track row is nowhere near a window wide, so a wide window can hold two of
    /// them. They fill top to bottom, left column first: a numbered list is read
    /// down a column, not across the page.
    ///
    /// Second column only when the first one overflows — an album that already
    /// fits reads better whole than cut in half above a field of empty space. Row
    /// height is estimated, so the split is off by a row or two on albums with
    /// long, wrapping titles.
    /// Capped even when a single column has the whole window to itself: stretch a
    /// row across a wide display and the eye loses the line between the title and
    /// the format and duration at its far end.
    private let columnWidth: CGFloat = 560
    private let columnGap: CGFloat = 20

    private var contentWidth: CGFloat {
        columnWidth * CGFloat(columns) + columnGap * CGFloat(columns - 1)
    }

    private var columns: Int {
        guard size.width >= 900 else { return 1 }
        let rowsInView = (size.height - 400) / 26
        return CGFloat(tracks.count) > rowsInView ? 2 : 1
    }

    private func rows(_ tracks: [Track]) -> [[Track]] {
        guard columns > 1, tracks.count > 3 else { return tracks.map { [$0] } }
        let half = (tracks.count + 1) / 2
        return (0..<half).map { i in
            i + half < tracks.count ? [tracks[i], tracks[i + half]] : [tracks[i]]
        }
    }

    @ViewBuilder private func trackRows(_ group: [Track]) -> some View {
        ForEach(Array(rows(group).enumerated()), id: \.offset) { _, row in
            HStack(alignment: .top, spacing: columnGap) {
                ForEach(row) { track in
                    MacTrackRow(track: track, context: group, showNumber: true, showFolder: false)
                        .frame(maxWidth: columnWidth, alignment: .leading)
                }
                if row.count < columns {
                    Color.clear.frame(maxWidth: columnWidth, maxHeight: 1)
                }
                Spacer(minLength: 0)
            }
            .id(row[0].url.path)
            // A List draws its separator the full width of the row, which is the
            // window — the very line the narrow column exists to avoid.
            .alignmentGuide(.listRowSeparatorTrailing) { _ in contentWidth }
        }
    }

    /// Rows are what the List can scroll to, so a track in the right column is
    /// reached through the one beside it.
    private func rowAnchor(_ path: String) -> String {
        let groups = folderGroups.count <= 1 ? [tracks] : folderGroups.map(\.tracks)
        for group in groups {
            for row in rows(group) where row.contains(where: { $0.url.path == path }) {
                return row[0].url.path
            }
        }
        return path
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
        withAnimation { proxy.scrollTo(rowAnchor(focusPath), anchor: .center) }
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
            ArtworkView(path: album.artworkPath, cornerRadius: 8, maxPixel: 900)
                .frame(width: 336, height: 336)
                .shadow(radius: 6, y: 3)
                .onTapGesture {
                    guard let path = album.artworkPath else { return }
                    openWindow(id: MacArtworkZoomView.windowID, value: path)
                }
                .help(album.artworkPath == nil ? "" : "Click to view full size")

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
            Divider()
            Button("Send to iPhone") { Task { await sendToPhone.sendAlbum(album, library: library) } }
                .disabled(sendToPhone.isBusy)
            Button("Send to iPhone (Opus)") {
                Task { await sendToPhone.sendAlbum(album, library: library, opus: true) }
            }
            .disabled(sendToPhone.isBusy)
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
