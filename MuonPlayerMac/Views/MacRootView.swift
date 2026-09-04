import SwiftUI

struct MacRootView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player
    @Environment(LibraryFolders.self) private var folders
    @Environment(MacRouter.self) private var router
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var router = router

        // The player bar is a sibling of the split view, not a safe-area inset on
        // it: an inset there is not propagated into the detail column's scroll
        // view, so the last rows of a long list stayed hidden behind the bar.
        VStack(spacing: 0) {
            NavigationSplitView {
                sidebar
            } detail: {
                if library.roots.isEmpty {
                    WelcomeView()
                } else {
                    NavigationStack(path: router.path) {
                        Group {
                            if router.searchQuery.isEmpty {
                                section(router.section)
                            } else {
                                MacSearchResultsView(query: router.searchQuery)
                            }
                        }
                        .navigationDestination(for: Album.self) { MacAlbumDetailView(album: $0) }
                        .navigationDestination(for: AlbumRef.self) {
                            MacAlbumDetailView(album: $0.album, focusPath: $0.focusPath)
                        }
                        .navigationDestination(for: ArtistRef.self) { MacArtistView(artist: $0.name) }
                        .navigationDestination(for: FolderRef.self) { MacFoldersView(directory: $0.url) }
                    }
                }
            }
            // On the split view, not a detail view: there the field persists across
            // pushed pages (album, artist) instead of vanishing the moment you drill
            // in, and still renders — a `.searchable` on the inner NavigationStack
            // never reaches the toolbar at all.
            .searchable(text: $router.searchQuery, placement: .toolbar,
                        prompt: "Search artists, albums and songs")
            .searchFocus($searchFocused)
            .inspector(isPresented: $router.showNowPlaying) {
                MacNowPlayingView()
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
            }

            MacPlayerBar()
        }
        .artworkAccent(player.accentColor)
        // A query typed while drilled into an album would otherwise stay hidden
        // behind it — the results only replace the section root.
        .onChange(of: router.searchQuery) { _, new in
            if !new.isEmpty { router.popToRoot() }
        }
        .onChange(of: router.searchFocusToken) { searchFocused = true }
        .spaceTogglesPlayback(player)
        .sheet(isPresented: $router.showQueue) { MacQueueView() }
    }

    // A `safeAreaInset` whose content starts out empty never lays the inset in
    // once it appears, so the scan status simply never showed. A plain VStack
    // under the List does.
    //
    // The rows carry their own selection fill rather than using `List(selection:)`.
    // AppKit paints a sidebar's selection with `NSColor.controlAccentColor` — the
    // system-wide setting — and neither `.tint` nor `.accentColor` reaches it, so
    // the selected row stayed blue while everything else followed the artwork.
    private var sidebar: some View {
        VStack(spacing: 0) {
            List {
                Section("Library") {
                    ForEach(MacRouter.Section.allCases) { s in
                        sidebarRow(s)
                    }
                }
            }
            .listStyle(.sidebar)
            ScanFooterView()
        }
        .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 260)
    }

    private func sidebarRow(_ s: MacRouter.Section) -> some View {
        let selected = router.section == s
        return Button { router.section = s } label: {
            Label(s.title, systemImage: s.systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.white : .primary)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? player.accentColor : .clear)
        )
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

private extension View {
    /// `.searchFocused` is macOS 15+; the deployment floor is 14, where ⌘F simply
    /// does nothing rather than failing to build.
    @ViewBuilder
    func searchFocus(_ binding: FocusState<Bool>.Binding) -> some View {
        if #available(macOS 15.0, *) {
            searchFocused(binding)
        } else {
            self
        }
    }
}

/// Scan progress, in its own view so that reading `scanPhase` invalidates only
/// this strip.
///
/// Reading it directly in `MacRootView.body` made every progress tick rebuild the
/// whole body — the split view and its thousand-cell album grid. The scan loop
/// awaits the database actor once per file, which hands the main actor back to
/// SwiftUI each time, so that rebuild ran once per file and a full re-index of a
/// 14k-track library took minutes instead of seconds.
private struct ScanFooterView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(LibraryFolders.self) private var folders

    var body: some View {
        // Nothing to rescan and nothing to report until a folder is added.
        if !folders.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Divider()
                if library.scanPhase != .idle {
                    Text(library.scanPhase.label)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).monospacedDigit()
                        .padding(.top, 3)
                    // Walking the folders has no total, so it gets an indeterminate bar.
                    if let fraction = library.scanPhase.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                } else {
                    Button { Task { await library.rescanUntilSettled() } } label: {
                        Label("Rescan Library", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .padding(.top, 3)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
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
