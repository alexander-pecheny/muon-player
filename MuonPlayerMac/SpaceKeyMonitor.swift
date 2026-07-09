import AppKit
import SwiftUI

/// Space toggles play/pause, the way every music player behaves.
///
/// It cannot be a `.keyboardShortcut(.space)`: AppKit dispatches bare key
/// equivalents before the focused text field sees them, so the search and filter
/// fields would never receive a space character. Instead we watch key-down events
/// and skip the ones aimed at a text field (whose first responder is the window's
/// shared field editor, an NSText subclass).
struct SpaceTogglesPlayback: ViewModifier {
    let player: Player

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard shouldHandle(event) else { return event }
                    player.togglePlayPause()
                    return nil          // swallow it, so nothing beeps
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }

    private func shouldHandle(_ event: NSEvent) -> Bool {
        guard player.currentTrack != nil else { return false }
        guard event.charactersIgnoringModifiers == " " else { return false }
        // Any modifier means it's some other shortcut (⌘Space, ⌥Space…).
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return false }
        guard let responder = event.window?.firstResponder else { return true }
        return !(responder is NSText)
    }
}

extension View {
    func spaceTogglesPlayback(_ player: Player) -> some View {
        modifier(SpaceTogglesPlayback(player: player))
    }
}
