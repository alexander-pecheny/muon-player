// swift-tools-version: 6.1
// Builds the platform-independent half of MuonPlayer for Android.
//
// The Apple apps are still built from MuonPlayer.xcodeproj (see project.yml); this
// manifest compiles the *same* source directories with the Swift Android SDK, so
// there is one copy of the library, scanner, tag writer and decoder:
//
//   swift build --swift-sdk aarch64-unknown-linux-android28
//
// FFmpeg and SQLite are vendored per platform. Apple gets xcframeworks and the
// system SQLite3 module; Android gets the static .a slices built by
// `scripts/build-ffmpeg.sh android` plus the SQLite amalgamation, because the NDK
// exposes neither.
import PackageDescription
import Foundation

let ffmpegLibs = ["avcodec", "avformat", "avutil", "swresample"]

// avcodec.h includes <libavutil/samplefmt.h>, so clang needs the include root
// itself on the search path, not just the directory holding the module map.
let ffmpegInclude = Context.packageDirectory + "/Vendor/FFmpeg/android/include"
let ffmpegLibDir = Context.packageDirectory + "/Vendor/FFmpeg/android/arm64-v8a"

let package = Package(
    name: "MuonCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MuonCore", targets: ["MuonCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .systemLibrary(name: "CFFmpeg", path: "Vendor/FFmpeg/android/include"),
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
            exclude: ["Audio/Player.swift"],
            sources: ["Audio", "Library", "Models", "Playback", "Scanner", "Scrobble", "Compat"],
            // The Xcode targets build these same files as Swift 5 (project.yml's
            // SWIFT_VERSION), so the package matches. Migrating the library to
            // strict concurrency is its own change, not part of the port.
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-Xcc", "-I\(ffmpegInclude)"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(ffmpegLibDir)"], .when(platforms: [.android])),
            ] + ffmpegLibs.map { .linkedLibrary($0, .when(platforms: [.android])) }
        ),
    ]
)
