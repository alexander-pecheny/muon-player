#if os(Android)
import Foundation

// On Apple, LibraryStore hands back a decoded UIImage/NSImage because ImageIO can
// downsample straight out of the encoded bytes. Android has no ImageIO, and its
// own BitmapFactory does that job better than anything reachable from Swift, so
// here PlatformImage carries the bytes and the size that was asked for, and the
// Kotlin layer decodes with inSampleSize. The shared call site is unchanged.

public struct PlatformImage: Sendable, Equatable {
    public let data: Data
    public let maxPixel: Int

    public static func thumbnail(from data: Data, maxPixel: Int) -> PlatformImage? {
        guard !data.isEmpty else { return nil }
        return PlatformImage(data: data, maxPixel: maxPixel)
    }
}
#endif
