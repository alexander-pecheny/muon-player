import SwiftUI
import Observation

/// The set of top-level tabs. Their order is user-configurable (Settings →
/// Tab Order); iOS shows the first few at the bottom and folds the rest into
/// the automatic "More" tab.
enum AppTab: String, CaseIterable, Identifiable, Sendable, Codable {
    case albums, artists, songs, folders
    case home = "search"   // formerly "Search"; rawValue kept so saved tab orders migrate
    case history, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .songs: return "Songs"
        case .folders: return "Folders"
        case .home: return "Home"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .albums: return "square.stack"
        case .artists: return "music.mic"
        case .songs: return "music.note.list"
        case .folders: return "folder"
        case .home: return "house"
        case .history: return "clock"
        case .settings: return "gearshape"
        }
    }
}

/// Persisted tab ordering, shared between ContentView and the reorder editor.
@MainActor
@Observable
final class TabSettings {
    private let key = "tabOrder"
    var order: [AppTab] { didSet { persist() } }

    init() {
        if let raw = UserDefaults.standard.string(forKey: key) {
            let parsed = raw.split(separator: ",").compactMap { AppTab(rawValue: String($0)) }
            // Append any tabs added in a later app version so nothing is lost.
            let missing = AppTab.allCases.filter { !parsed.contains($0) }
            order = parsed + missing
        } else {
            order = AppTab.allCases
        }
    }

    /// iOS shows at most 5 items on the iPhone tab bar. With more than that we
    /// reserve the last slot for our own More tab and fold the rest into it —
    /// rather than letting iOS build its automatic More tab, whose extra
    /// navigation controller doubled the bar/back button on folded-in screens.
    var visibleTabs: [AppTab] { Array(order.prefix(order.count > 5 ? 4 : order.count)) }
    var overflowTabs: [AppTab] { Array(order.dropFirst(visibleTabs.count)) }

    /// The slot `slot` will actually be reachable in, folding a tab that has been
    /// pushed into the overflow onto the More tab.
    func reachable(_ slot: TabSelection) -> TabSelection {
        guard case .tab(let t) = slot else { return slot }
        return visibleTabs.contains(t) ? slot : .more
    }

    private func persist() {
        UserDefaults.standard.set(order.map(\.rawValue).joined(separator: ","), forKey: key)
    }
}

/// Settings editor for reordering tabs. On iPhone the first four rows appear on
/// the bottom bar; the rest are reached via the "More" tab.
struct TabsReorderView: View {
    @Environment(TabSettings.self) private var tabs

    // Number of tabs iOS shows before collapsing the rest into "More".
    private let visibleCount = 4

    var body: some View {
        @Bindable var tabs = tabs
        List {
            Section {
                ForEach(Array(tabs.order.enumerated()), id: \.element.id) { index, tab in
                    HStack {
                        Label(tab.title, systemImage: tab.systemImage)
                        Spacer()
                        if index >= visibleCount {
                            Text("More").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                .onMove { from, to in tabs.order.move(fromOffsets: from, toOffset: to) }
            } footer: {
                Text("Drag to reorder. The first \(visibleCount) tabs appear on the bottom bar; the rest are grouped under “More”.")
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Tab Order")
        .navigationBarTitleDisplayMode(.inline)
    }
}
