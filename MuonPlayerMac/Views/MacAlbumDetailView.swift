import SwiftUI

struct MacAlbumDetailView: View {
    let album: Album

    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player
    @Environment(MacRouter.self) private var router
    @State private var tracks: [Track] = []
    @State private var editing = false

    private var totalDuration: TimeInterval {
        tracks.compactMap(\.duration).reduce(0, +)
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
        List {
            Section { header.listRowSeparator(.hidden) }
            // With one folder the heading is noise; with several it's the point.
            if folderGroups.count <= 1 {
                Section {
                    ForEach(tracks) { track in
                        MacTrackRow(track: track, context: tracks, showNumber: true, showFolder: false)
                    }
                }
            } else {
                ForEach(folderGroups, id: \.folder) { group in
                    Section {
                        // Context is the folder, not the album: playing a track
                        // from the FLAC rip should continue through the FLAC rip.
                        ForEach(group.tracks) { track in
                            MacTrackRow(track: track, context: group.tracks, showNumber: true, showFolder: false)
                        }
                    } header: {
                        folderHeader(group)
                    }
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle(album.title)
        .toolbar {
            ToolbarItem {
                Button { editing = true } label: { Label("Edit Tags", systemImage: "tag") }
            }
        }
        .sheet(isPresented: $editing) { MacTagEditView(scope: .album(album)) }
        .task(id: album.id) { tracks = await library.tracks(in: album) }
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
    }

    private var subtitle: String {
        var parts: [String] = []
        if let year = album.year { parts.append(String(year)) }
        parts.append("\(tracks.count) track\(tracks.count == 1 ? "" : "s")")
        if totalDuration > 0 { parts.append(formatDuration(totalDuration)) }
        return parts.joined(separator: " · ")
    }
}
