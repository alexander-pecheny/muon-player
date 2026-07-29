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
//   (cd Android && gradle assembleDebug)                      # → apk
//
// FFmpeg and SQLite are vendored per platform. Apple gets xcframeworks and the
// system SQLite3 module; Android gets the static .a slices built by
// `scripts/build-ffmpeg.sh android` plus the SQLite amalgamation, because the NDK
// exposes neither.
import PackageDescription
import Foundation

let ffmpegLibs = ["avcodec", "avformat", "avutil", "swresample"]

let ffmpegLibDir = Context.packageDirectory + "/Vendor/FFmpeg/android/arm64-v8a"

// Everything under MuonPlayer/ that belongs to the Apple apps only. Listing it
// keeps SwiftPM from warning about files it can see but never builds.
let appleOnly = ["Info.plist", "PrivacyInfo.xcprivacy", "Secrets.swift",
                 "Assets.xcassets", "Resources", "Shared", "Views", "App", "SelfTests"]

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
    targets: [
        // A C target rather than a systemLibrary: only the former propagates its
        // public header path to modules that import it, and avcodec.h pulls in
        // <libavutil/samplefmt.h> by path.
        .target(name: "CFFmpeg", path: "Vendor/FFmpeg/android",
                exclude: ["arm64-v8a"],
                sources: ["shim.c"], publicHeadersPath: "include"),
        .target(name: "CSQLite", path: "Vendor/SQLite",
                sources: ["sqlite3.c"], publicHeadersPath: "include"),
        .target(
            name: "MuonCore",
            dependencies: [
                "CFFmpeg", "CSQLite",
                .product(name: "Crypto", package: "swift-crypto",
                         condition: .when(platforms: [.android])),
            ],
            path: "MuonPlayer",
            // Player.swift is AVAudioEngine end to end and is being replaced by an
            // AudioTrack sink; everything else here is meant to compile as-is.
            exclude: ["Audio/Player.swift"] + appleOnly,
            sources: ["Audio", "Library", "Models", "Playback", "Scanner", "Scrobble", "Compat"],
            // The Xcode targets build these same files as Swift 5 (project.yml's
            // SWIFT_VERSION), so the package matches. Migrating the library to
            // strict concurrency is its own change, not part of the port.
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags(["-L\(ffmpegLibDir)"], .when(platforms: [.android])),
            ] + ffmpegLibs.map { .linkedLibrary($0, .when(platforms: [.android])) }
        ),
        .target(
            name: "MuonSkip",
            dependencies: [
                .product(name: "SkipFuseUI", package: "skip-fuse-ui"),
                "MuonCore",
            ],
            resources: [.process("Resources")],
            plugins: [.plugin(name: "skipstone", package: "skip")]
        ),
    ]
)
