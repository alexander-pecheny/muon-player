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
            // Above the split view, spanning the window, because it cannot live
            // inside the detail column: anything wrapping or sitting beside that
            // NavigationStack — a sibling in a VStack, a safeAreaInset — is
            // dropped the moment the stack pushes, so the strip vanished the
            // first time you opened an album.
            if !library.roots.isEmpty { MacTabBar() }

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
                        .navigationDestination(for: Album.self) {
                            MacAlbumDetailView(album: $0).tabTitle($0.title, artwork: $0.artworkPath)
                        }
                        .navigationDestination(for: AlbumRef.self) {
                            MacAlbumDetailView(album: $0.album, focusPath: $0.focusPath)
                                .tabTitle($0.album.title, artwork: $0.album.artworkPath)
                        }
                        .navigationDestination(for: ArtistRef.self) {
                            MacArtistView(artist: $0.name).tabTitle($0.name)
                        }
                        .navigationDestination(for: FolderRef.self) {
                            MacFoldersView(directory: $0.url).tabTitle($0.url.lastPathComponent)
                        }
                    }
                    // A tab is its own browsing context, so switching to one
                    // rebuilds the stack rather than animating the old one.
                    .id(router.activeID)
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
        .commandWClosesTab(router)
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

    private var scanning: Bool { library.scanPhase != .idle }

    var body: some View {
        // Nothing to rescan and nothing to report until a folder is added.
        if !folders.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Divider()
                // The button keeps its shape while a scan runs — every activation
                // starts one, and a footer that rearranges itself each time you
                // ⌘-Tab back is the thing you end up watching.
                Button { Task { await library.rescanUntilSettled() } } label: {
                    HStack(spacing: 6) {
                        icon
                        Text(scanning ? "Scanning…" : "Rescan Library")
                    }
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(scanning)
                .padding(.top, 3)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder private var icon: some View {
        if scanning {
            // Walking the folders has no total, so it spins rather than fills.
            Group {
                if let fraction = library.scanPhase.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
            }
            .progressViewStyle(.circular)
            .controlSize(.small)
        } else {
            Image(systemName: "arrow.clockwise")
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
