import SwiftUI

/// In-memory cache of decoded album art, keyed by the source file path.
///
/// Scrolling a large grid revisits the same covers constantly, and each miss
/// costs an FFmpeg open plus an image decode. Loads are therefore shared: cells
/// that ask for the same path while one is in flight await that same task rather
/// than starting their own.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()

    private let cache = NSCache<NSString, PlatformImage>()
    private var misses = Set<String>()
    private var inFlight: [String: Task<PlatformImage?, Never>] = [:]

    init() {
        cache.countLimit = 500
    }

    /// A thumbnail and a full-size decode of the same cover are different images,
    /// so the size is part of the identity.
    private func key(_ path: String, _ maxPixel: Int) -> String { "\(maxPixel)|\(path)" }

    func image(for path: String, maxPixel: Int = 400) -> PlatformImage? {
        cache.object(forKey: key(path, maxPixel) as NSString)
    }
    func isKnownMiss(_ path: String, maxPixel: Int = 400) -> Bool { misses.contains(key(path, maxPixel)) }

    /// The cached image, loading it (once) if needed.
    func load(path: String, maxPixel: Int = 400, from library: LibraryStore) async -> PlatformImage? {
        let key = key(path, maxPixel)
        if let cached = image(for: path, maxPixel: maxPixel) { return cached }
        if isKnownMiss(path, maxPixel: maxPixel) { return nil }
        if let running = inFlight[key] { return await running.value }

        let task = Task<PlatformImage?, Never> { await library.artwork(forPath: path, maxPixel: maxPixel) }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil

        if let image { cache.setObject(image, forKey: key as NSString) } else { misses.insert(key) }
        return image
    }
}

/// Async-loading artwork thumbnail. Falls back to a music-note placeholder.
struct ArtworkView: View {
    let path: String?
    var cornerRadius: CGFloat = 6
    /// Cap on the decoded size. Raise it for art shown larger than a thumbnail.
    var maxPixel: Int = 400

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
        // Synchronous cache hit: assigning before any await keeps an already-decoded
        // cover from flashing its placeholder for a frame while scrolling.
        if let cached = ArtworkCache.shared.image(for: path, maxPixel: maxPixel) { image = cached; return }
        image = nil

        let loaded = await ArtworkCache.shared.load(path: path, maxPixel: maxPixel, from: library)
        // The cell may have been recycled onto another album mid-load.
        guard !Task.isCancelled, self.path == path else { return }
        image = loaded
    }
}
