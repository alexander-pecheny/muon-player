import AppKit
import SwiftUI

/// ⌘W closes the tab, and the window only once the last tab is gone.
///
/// It cannot be a `.keyboardShortcut("w")`: File → Close already owns ⌘W, AppKit
/// resolves that before any SwiftUI command with the same equivalent, and adding
/// a second ⌘W item merely puts two of them in the File menu. A local event
/// monitor sees the key first, so it can take it when there is a tab to close and
/// hand it back when there is not.
struct CloseTabOnCommandW: ViewModifier {
    let router: MacRouter

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.charactersIgnoringModifiers?.lowercased() == "w",
                          event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                          router.closeActiveTab()
                    else { return event }
                    return nil
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

extension View {
    func commandWClosesTab(_ router: MacRouter) -> some View {
        modifier(CloseTabOnCommandW(router: router))
    }
}
