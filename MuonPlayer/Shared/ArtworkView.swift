import SwiftUI

/// In-memory cache of decoded album art, keyed by the source file path.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSString, PlatformImage>()
    private var misses = Set<String>()

    func image(for path: String) -> PlatformImage? { cache.object(forKey: path as NSString) }
    func isKnownMiss(_ path: String) -> Bool { misses.contains(path) }
    func store(_ image: PlatformImage?, for path: String) {
        if let image { cache.setObject(image, forKey: path as NSString) }
        else { misses.insert(path) }
    }
}

/// Async-loading artwork thumbnail. Falls back to a music-note placeholder.
struct ArtworkView: View {
    let path: String?
    var cornerRadius: CGFloat = 6

    @Environment(LibraryStore.self) private var library
    @State private var image: PlatformImage?

    var body: some View {
        // The clear Rectangle takes whatever size the parent proposes (it does
        // not propagate the image's own aspect ratio), so a caller's
        // `.aspectRatio(1, .fit)` yields a true square and the filled artwork is
        // center-cropped to it — no letterboxing for non-square covers.
        Rectangle()
            .fill(Color.clear)
            .overlay {
                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .contentShape(Rectangle())
            .task(id: path) { await load() }
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: "music.note")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
        }
    }

    private func load() async {
        guard let path else { image = nil; return }
        if let cached = ArtworkCache.shared.image(for: path) { image = cached; return }
        if ArtworkCache.shared.isKnownMiss(path) { image = nil; return }
        let loaded = await library.artwork(forPath: path)
        ArtworkCache.shared.store(loaded, for: path)
        if self.path == path { image = loaded }
    }
}
