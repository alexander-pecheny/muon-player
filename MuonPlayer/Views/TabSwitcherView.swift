import SwiftUI

/// The open tabs, as cards. There is no strip on the phone — a fourth horizontal
/// band under the navigation bar, the tab bar and the mini player is more than
/// the screen has — so this is the only place tabs are seen, and it is reached
/// from the count button that appears once a second tab exists.
struct TabSwitcherView: View {
    @Environment(TabRouter.self) private var router
    @Environment(TabSettings.self) private var settings
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(router.contexts) { context in
                        card(context)
                    }
                }
                .padding()
            }
            .navigationTitle("Tabs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { router.newTab(settings); dismiss() } label: {
                        Label("New Tab", systemImage: "plus")
                    }
                }
            }
        }
    }

    private func card(_ context: TabRouter.Context) -> some View {
        let active = context.id == router.activeID
        return Button {
            router.activate(context.id)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: context.slot.systemImage)
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 110)
                    if router.contexts.count > 1 {
                        Button { router.closeTab(context.id) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .symbolRenderingMode(.hierarchical)
                        }
                        .buttonStyle(.plain)
                        .padding(6)
                    }
                }
                .background(.fill.quaternary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(context.title).font(.subheadline).lineLimit(1)
                    // The slot is worth saying only when the page has its own
                    // name, or the card would read "Albums" twice.
                    if context.title != context.slot.defaultTitle {
                        Text(context.slot.defaultTitle)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(active ? player.accentColor : .clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
    }
}

/// New Tab, and — once there is more than one — the count that opens the
/// switcher. A new tab starts on Home, or on the More tab if Home has been
/// reordered into the overflow.
struct TabToolbar: ToolbarContent {
    @Environment(TabRouter.self) private var router
    @Environment(TabSettings.self) private var settings

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if router.contexts.count > 1 {
                Button { router.showSwitcher = true } label: {
                    Label("\(router.contexts.count) tabs", systemImage: "square.on.square")
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { router.newTab(settings) } label: {
                Label("New Tab", systemImage: "plus")
            }
        }
    }
}

extension View {
    func tabCountToolbar() -> some View {
        toolbar { TabToolbar() }
    }
}
