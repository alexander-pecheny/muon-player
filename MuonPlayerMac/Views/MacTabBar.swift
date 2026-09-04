import SwiftUI

/// The tab strip above the content. A tab is a whole browsing context, so the
/// sidebar changes the active tab's section rather than the window's.
struct MacTabBar: View {
    @Environment(MacRouter.self) private var router

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollView(.horizontal) {
                    HStack(spacing: 1) {
                        ForEach(router.tabs) { TabChip(tab: $0) }
                    }
                }
                .scrollIndicators(.hidden)

                Button { router.newTab() } label: {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New Tab (⌘T)")
                .padding(.trailing, 6)
            }
            .frame(height: 30)
            Divider()
        }
        // The horizontal ScrollView inside reports a flexible height, which the
        // enclosing VStack answers by stretching the strip and centring it in the
        // column. Pin it to what it actually needs.
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TabChip: View {
    let tab: BrowseTab
    @Environment(MacRouter.self) private var router
    @Environment(Player.self) private var player
    @State private var hovering = false

    private var active: Bool { router.activeID == tab.id }
    private var closable: Bool { router.tabs.count > 1 && (hovering || active) }

    var body: some View {
        HStack(spacing: 5) {
            Text(tab.title).font(.callout).lineLimit(1)
            // The slot is held open whether or not the button is in it, so a tab
            // does not resize under the pointer.
            Group {
                if closable {
                    Button { router.closeTab(tab.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 10, height: 10)
        }
        .padding(.horizontal, 10)
        .frame(height: 29)
        .frame(minWidth: 95, maxWidth: 220)
        .background(active ? player.accentColor.opacity(0.25) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { router.activateTab(tab.id) }
        .onHover { hovering = $0 }
        .help(tab.title)
    }
}

extension View {
    /// ⌘-click opens the link's destination in a background tab. `NavigationLink`
    /// pushes onto the path itself, never reaching the router, so the click has to
    /// be taken off it before it navigates.
    func commandClickOpens(_ open: @escaping () -> Void) -> some View {
        highPriorityGesture(TapGesture().modifiers(.command).onEnded(open))
    }
}
