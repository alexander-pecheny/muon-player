import Foundation
import Testing
import CoreGraphics
@testable import MuonPlayer

/// The accent has to survive being drawn on the app's background and under a
/// white button label, which is a luminance question, not a brightness one — a
/// fully-lit saturated blue looks bright in HSB and vanishes on black.
@Suite("Artwork accent color")
struct DominantColorTests {
    typealias RGB = DominantColor.RGB

    static let blue = RGB(r: 0.23, g: 0.18, b: 0.82)      // the cover that failed
    static let pink = RGB(r: 0.87, g: 0.42, b: 0.78)
    static let paleYellow = RGB(r: 0.98, g: 0.96, b: 0.60)

    @Test("A legible candidate is taken as it is")
    func passesThroughLegible() {
        let picked = DominantColor.accent(from: [Self.pink], in: .dark)
        #expect(picked == Self.pink)
    }

    @Test("A later candidate wins when the most prominent one is too dark")
    func skipsIllegibleCandidate() {
        let picked = DominantColor.accent(from: [Self.blue, Self.pink], in: .dark)
        #expect(picked == Self.pink)
    }

    @Test("With no legible candidate, the closest one is corrected into range")
    func clampsWhenNothingFits() throws {
        let picked = try #require(DominantColor.accent(from: [Self.blue], in: .dark))
        #expect(DominantColor.SafeRange.dark.contains(DominantColor.relativeLuminance(picked)))
        // Blue cannot reach the floor at any brightness, so it is lightened
        // towards white rather than merely brightened — but it stays blue.
        #expect(picked.b > picked.r && picked.b > picked.g)
    }

    @Test("The candidate needing the least correction is the one that is corrected")
    func clampsTheNearestCandidate() throws {
        // Both are out of the light range (too bright); the pink is nearer to it.
        let picked = try #require(DominantColor.accent(from: [Self.paleYellow, Self.pink], in: .light))
        let (h, _, _) = DominantColor.hsb(picked)
        let (pinkHue, _, _) = DominantColor.hsb(Self.pink)
        #expect(abs(h - pinkHue) < 0.02)
    }

    @Test("Every clamp lands inside its range", arguments: [
        RGB(r: 0.23, g: 0.18, b: 0.82),   // deep blue — must lighten
        RGB(r: 0.05, g: 0.05, b: 0.10),   // near black
        RGB(r: 0.99, g: 0.98, b: 0.95),   // near white
        RGB(r: 0.87, g: 0.42, b: 0.78),   // pink
        RGB(r: 0.10, g: 0.60, b: 0.20),   // green
    ])
    func clampAlwaysLands(_ c: RGB) {
        for range in [DominantColor.SafeRange.dark, .light] {
            let l = DominantColor.relativeLuminance(DominantColor.clamped(c, into: range))
            #expect(l >= range.minLuminance - 0.005)
            #expect(l <= range.maxLuminance + 0.005)
        }
    }

    @Test("Grayscale artwork yields no accent")
    func grayscaleYieldsNothing() throws {
        let image = try #require(solid(RGB(r: 0.5, g: 0.5, b: 0.5)))
        #expect(DominantColor.from(image) == nil)
    }

    @Test("A cover's hues come out ordered by how much of it they cover")
    func candidatesAreRanked() throws {
        // Two thirds deep blue, one third pink — the same shape as the cover that
        // picked an illegible blue.
        let image = try #require(bands([Self.blue, Self.blue, Self.pink]))
        let candidates = DominantColor.candidates(from: image)
        #expect(candidates.count == 2)
        #expect(DominantColor.hsb(candidates[0]).h > 0.6)   // blue first
        #expect(DominantColor.hsb(candidates[1]).h > 0.8)   // then pink/magenta
        // …and the accent skips past the blue to the pink.
        let picked = try #require(DominantColor.accent(from: candidates, in: .dark))
        #expect(picked.r > picked.b)
    }

    // MARK: - Fixtures

    private func solid(_ c: RGB) -> PlatformImage? { bands([c]) }

    /// An image of horizontal bands, one per color, all the same height.
    private func bands(_ colors: [RGB]) -> PlatformImage? {
        let side = 96
        let height = side / colors.count
        guard let ctx = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        for (i, c) in colors.enumerated() {
            ctx.setFillColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
            ctx.fill(CGRect(x: 0, y: i * height, width: side, height: height))
        }
        guard let cg = ctx.makeImage() else { return nil }
        #if canImport(UIKit)
        return PlatformImage(cgImage: cg)
        #else
        return PlatformImage(cgImage: cg, size: CGSize(width: side, height: side))
        #endif
    }
}
