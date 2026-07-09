import SwiftUI

struct MacRootView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player
    @Environment(LibraryFolders.self) private var folders
    @Environment(MacRouter.self) private var router

    var body: some View {
        @Bindable var router = router

        NavigationSplitView {
            sidebar
        } detail: {
            if library.roots.isEmpty {
                WelcomeView()
            } else {
                NavigationStack(path: router.path) {
                    section(router.section)
                        .navigationDestination(for: Album.self) { MacAlbumDetailView(album: $0) }
                        .navigationDestination(for: ArtistRef.self) { MacArtistView(artist: $0.name) }
                        .navigationDestination(for: FolderRef.self) { MacFoldersView(directory: $0.url) }
                }
            }
        }
        .tint(player.accentColor)
        .safeAreaInset(edge: .bottom, spacing: 0) { MacPlayerBar() }
        .inspector(isPresented: $router.showNowPlaying) {
            MacNowPlayingView()
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .sheet(isPresented: $router.showQueue) { MacQueueView() }
    }

    // List's single-selection binding is optional; the router's isn't (there is
    // always a selected section), so a nil write from a deselect is dropped.
    private var selection: Binding<MacRouter.Section?> {
        Binding(get: { router.section }, set: { if let s = $0 { router.section = s } })
    }

    private var sidebar: some View {
        List(selection: selection) {
            Section("Library") {
                ForEach(MacRouter.Section.allCases) { s in
                    Label(s.title, systemImage: s.systemImage).tag(s)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 260)
        .safeAreaInset(edge: .bottom) { scanStatus }
    }

    @ViewBuilder private var scanStatus: some View {
        if let progress = library.scanProgress {
            VStack(alignment: .leading, spacing: 4) {
                Text("Scanning \(progress.done) / \(progress.total)")
                    .font(.caption).foregroundStyle(.secondary)
                ProgressView(value: Double(progress.done), total: Double(max(1, progress.total)))
            }
            .padding(10)
        }
    }

    @ViewBuilder private func section(_ s: MacRouter.Section) -> some View {
        switch s {
        case .home: MacHomeView()
        case .albums: MacAlbumsView()
        case .artists: MacArtistsView()
        case .songs: MacSongsView()
        case .folders: MacFoldersView()
        case .history: MacHistoryView()
        }
    }
}

/// Shown until the user adds a folder — nothing else in the app works without one.
private struct WelcomeView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(LibraryFolders.self) private var folders

    var body: some View {
        ContentUnavailableView {
            Label("No Music Folders", systemImage: "folder.badge.plus")
        } description: {
            Text("Add one or more folders to index. MuonPlayer reads them in place and never moves or modifies your files unless you edit tags.")
        } actions: {
            Button("Choose Folders…") {
                if folders.promptToAdd() {
                    Task { await library.setRoots(folders.roots) }
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
