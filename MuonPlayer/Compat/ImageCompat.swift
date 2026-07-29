#if !MUON_APPLE_UI
import Foundation

// MuonPlayer/Shared defines PlatformImage as UIImage/NSImage, and the Apple apps
// compile it; the Android package does not, and neither does the iOS scaffolding
// build Skip runs first, so both need this.
//
// It carries encoded bytes rather than a decoded image on purpose. Downsampling
// out of the encoded data is what ImageIO does for the Apple apps, and on Android
// BitmapFactory's inSampleSize does it better than anything reachable from Swift,
// so the decode belongs up in the view. The shared call site is unchanged.

public struct PlatformImage: Sendable, Equatable {
    public let data: Data
    public let maxPixel: Int

    public static func thumbnail(from data: Data, maxPixel: Int) -> PlatformImage? {
        guard !data.isEmpty else { return nil }
        return PlatformImage(data: data, maxPixel: maxPixel)
    }
}
#endif
