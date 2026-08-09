import SwiftUI

// What the screens need that SkipSwiftUI does not have. Each of these is a real
// hole in the Android SwiftUI rather than a difference of taste, so the seam is
// kept here and the views go on reading the same on every platform.

extension View {
    /// `.foregroundStyle(.tertiary)`. SkipSwiftUI ships `secondary` but marks
    /// `tertiary` and `quaternary` unavailable, so Android stops one step short.
    func tertiaryForeground() -> some View {
        #if os(Android)
        return foregroundStyle(.secondary)
        #else
        return foregroundStyle(.tertiary)
        #endif
    }
}

extension View {
    /// `.contentShape(Rectangle())` — makes a whole row tappable rather than just
    /// the pixels its content covers. SkipSwiftUI has no contentShape at all, and
    /// its absence breaks the rest of the modifier chain along with it; a Compose
    /// row already takes a tap across its full width, so Android wants nothing.
    func tappableRow() -> some View {
        #if os(Android)
        return self
        #else
        return contentShape(Rectangle())
        #endif
    }

    /// `.textSelection(.enabled)`, so a diagnostic dump can be copied out.
    /// SkipSwiftUI marks it unavailable; Android text is read-only there.
    func selectableText() -> some View {
        #if os(Android)
        return self
        #else
        return textSelection(.enabled)
        #endif
    }

    /// `.listRowInsets(EdgeInsets())`, which lets a row's content run edge to edge.
    /// Unavailable on Android, where the row keeps the platform's own padding.
    func flushListRow() -> some View {
        #if os(Android)
        return self
        #else
        return listRowInsets(EdgeInsets())
        #endif
    }

    /// `.searchable` with the field permanently on show. The drawer placement is
    /// iOS-only — SkipSwiftUI has no such case and macOS rejects it outright — so
    /// everywhere else takes the default placement.
    func filterSearchable(text: Binding<String>, prompt: String) -> some View {
        #if os(iOS)
        return searchable(text: text,
                          placement: .navigationBarDrawer(displayMode: .always),
                          prompt: prompt)
        #else
        return searchable(text: text, prompt: prompt)
        #endif
    }
}

/// "3m", "2h", "5d" — how long ago `unix` was.
///
/// Apple has RelativeDateTimeFormatter; Android's corelibs Foundation does not
/// carry it, so the same few units are spelled out by hand there.
func relativeTimeString(sinceUnix unix: Int, now: Date = Date()) -> String {
    #if os(Android)
    let delta = max(0, Int(now.timeIntervalSince1970) - unix)
    switch delta {
    case ..<60: return "\(delta)s ago"
    case ..<3600: return "\(delta / 60)m ago"
    case ..<86_400: return "\(delta / 3600)h ago"
    case ..<604_800: return "\(delta / 86_400)d ago"
    default: return "\(delta / 604_800)w ago"
    }
    #else
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: Date(timeIntervalSince1970: TimeInterval(unix)),
                                     relativeTo: now)
    #endif
}

extension Font {
    /// Tabular figures, so a counter does not change width as it counts. Android
    /// has no `monospacedDigit`, and takes the jitter.
    var tabularDigits: Font {
        #if os(Android)
        return self
        #else
        return monospacedDigit()
        #endif
    }
}

#if os(Android)
/// The empty-state placeholder. SkipSwiftUI has no ContentUnavailableView at all,
/// so this is the same arrangement drawn by hand: symbol, title, description.
struct ContentUnavailableView<Label: View, Description: View, Actions: View>: View {
    private let label: Label
    private let description: Description
    private let actions: Actions

    init(@ViewBuilder label: () -> Label,
         @ViewBuilder description: () -> Description = { EmptyView() },
         @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.label = label()
        self.description = description()
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 8) {
            label.font(.title3)
            description.font(.footnote).foregroundStyle(.secondary)
            actions.padding(.top, 8)
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension ContentUnavailableView
where Label == SwiftUI.Label<Text, Image>, Description == Text, Actions == EmptyView {
    init(_ title: String, systemImage: String, description: Text) {
        self.init(label: { SwiftUI.Label(title, systemImage: systemImage) },
                  description: { description })
    }
}

extension ContentUnavailableView
where Label == SwiftUI.Label<Text, Image>, Description == EmptyView, Actions == EmptyView {
    init(_ title: String, systemImage: String) {
        self.init(label: { SwiftUI.Label(title, systemImage: systemImage) })
    }
}
#endif
