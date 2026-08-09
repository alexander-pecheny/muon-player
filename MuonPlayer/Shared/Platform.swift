import SwiftUI

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#else
// Android has no UIKit, but skip-fuse-ui's SwiftUI re-exports its own UIImage —
// so the call sites below stay the one shape on all three platforms.
typealias PlatformImage = UIImage
#endif

#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ImageIO)
import ImageIO
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(AppKit) && !canImport(UIKit)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

extension PlatformImage {
    /// Decode `data` straight to a thumbnail no larger than `maxPixel` on its long
    /// edge. Album art is routinely 1500² or larger; decoding it at full size for
    /// a 160-point grid cell is what makes a big library scroll badly.
    static func thumbnail(from data: Data, maxPixel: Int) -> PlatformImage? {
        #if !canImport(ImageIO)
        // Android: BitmapFactory does the subsampled decode, behind UIImage(data:).
        guard let image = PlatformImage(data: data) else { return nil }
        let side = CGFloat(maxPixel)
        let longEdge = max(image.size.width, image.size.height)
        guard longEdge > side else { return image }
        let scale = side / longEdge
        return image.preparingThumbnail(
            of: CGSize(width: image.size.width * scale, height: image.size.height * scale)) ?? image
        #else
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        #if canImport(UIKit)
        return UIImage(cgImage: cg)
        #else
        return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
        #endif
        #endif
    }
}

func formatDuration(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let mins = Int(seconds) / 60
    let secs = Int(seconds) % 60
    return String(format: "%d:%02d", mins, secs)
}
