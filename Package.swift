// swift-tools-version: 6.1
// The Android app. This is a Skip (https://skip.dev) package.
//
// MuonCore compiles the *same* source directories the Apple apps build from
// (MuonPlayer.xcodeproj, generated from project.yml), so there is one copy of the
// library, scanner, tag writer and decoder. MuonSkip is the SwiftUI layer that
// Skip renders as Jetpack Compose on Android.
//
//   swift build --swift-sdk aarch64-unknown-linux-android28   # core only
//   skip android build                                        # core + UI → .so
//   (cd Android && gradle assembleDebug)                       # → apk
//
// FFmpeg and SQLite are vendored per platform. Apple gets the xcframeworks (also
// used by the Xcode targets) and the system SQLite3 module; Android gets the
// static .a slices built by `scripts/build-ffmpeg.sh android` plus the SQLite
// amalgamation, because the NDK exposes neither.
//
// Everything below is written as separate statements with explicit types on
// purpose: Skip pre-builds this package with Xcode's Swift, whose type checker
// times out on the array-concatenation chains this would otherwise be.
import PackageDescription
import Foundation

let ffmpegLibs = ["avcodec", "avformat", "avutil", "swresample"]
let ffmpegLibDir = Context.packageDirectory + "/Vendor/FFmpeg/android/arm64-v8a"

// Everything under MuonPlayer/ that belongs to the Apple apps only. Listing it
// keeps SwiftPM from warning about files it can see but never builds.
let appleOnly = ["Info.plist", "PrivacyInfo.xcprivacy", "Secrets.swift",
                 "Assets.xcassets", "Resources", "Shared", "Views", "App", "SelfTests"]

let apple: [Platform] = [.iOS, .macOS]

// Skip pre-builds the package for iOS to generate its Kotlin bridge, and that step
// links, so the Apple slices have to be reachable from here too — the -L below
// only points at the Android ones.
var ffmpegBinaryTargets: [Target] = []
var ffmpegAppleDeps: [Target.Dependency] = []
for lib in ffmpegLibs {
    ffmpegBinaryTargets.append(
        .binaryTarget(name: "lib" + lib, path: "Vendor/FFmpeg/lib" + lib + ".xcframework"))
    ffmpegAppleDeps.append(.target(name: "lib" + lib, condition: .when(platforms: apple)))
}

var coreDeps: [Target.Dependency] = ["CFFmpeg", "CSQLite"]
coreDeps.append(.target(name: "CAAudio", condition: .when(platforms: [.android])))
coreDeps.append(.product(name: "Crypto", package: "swift-crypto",
                         condition: .when(platforms: [.android])))
coreDeps += ffmpegAppleDeps

var coreLinks: [LinkerSetting] = [
    .unsafeFlags(["-L" + ffmpegLibDir], .when(platforms: [.android])),
]
for lib in ffmpegLibs + ["aaudio"] {
    coreLinks.append(.linkedLibrary(lib, .when(platforms: [.android])))
}
// What project.yml links as SDK libs; FFmpeg's matroska and id3 paths need them.
for lib in ["z", "bz2", "iconv"] {
    coreLinks.append(.linkedLibrary(lib, .when(platforms: apple)))
}

// Matching project.yml's SWIFT_VERSION is not enough on its own: Xcode also builds
// these files with minimal concurrency checking, and Player.swift's feeder hops to
// a GCD queue from a @MainActor class, which complete checking rejects outright.
let coreSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .unsafeFlags(["-strict-concurrency=minimal"]),
]

var targets: [Target] = [
    // A C target rather than a systemLibrary: only the former propagates its public
    // header path to modules that import it, and avcodec.h pulls in
    // <libavutil/samplefmt.h> by path.
    .target(name: "CFFmpeg", path: "Vendor/FFmpeg/android",
            exclude: ["arm64-v8a"],
            sources: ["shim.c"], publicHeadersPath: "include"),
    // sqlite3-muon.c is the only translation unit: it sets SQLITE_ENABLE_FTS5 and
    // then includes the amalgamation. See the comment there for why the define
    // lives in the source rather than here.
    .target(name: "CSQLite", path: "Vendor/SQLite",
            exclude: ["sqlite3.c"],
            sources: ["sqlite3-muon.c"], publicHeadersPath: "include"),
    .target(name: "CAAudio", path: "Vendor/AAudio",
            sources: ["shim.c"], publicHeadersPath: "include"),
]
targets += ffmpegBinaryTargets
targets.append(
    .target(
        name: "MuonCore",
        dependencies: coreDeps,
        path: "MuonPlayer",
        exclude: appleOnly,
        sources: ["Audio", "Library", "Models", "Playback", "Scanner", "Scrobble", "Compat"],
        swiftSettings: coreSwiftSettings,
        linkerSettings: coreLinks
    ))
targets.append(
    .target(
        name: "MuonSkip",
        dependencies: [
            .product(name: "SkipFuseUI", package: "skip-fuse-ui"),
            "MuonCore",
        ],
        resources: [.process("Resources")],
        plugins: [.plugin(name: "skipstone", package: "skip")]
    ))

let package = Package(
    name: "muon-player",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MuonSkip", type: .dynamic, targets: ["MuonSkip"]),
        .library(name: "MuonCore", targets: ["MuonCore", "CFFmpeg", "CSQLite"]),
    ],
    dependencies: [
        .package(url: "https://source.skip.tools/skip.git", from: "1.9.5"),
        .package(url: "https://source.skip.tools/skip-fuse-ui.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: targets
)
