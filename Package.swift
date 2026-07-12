// swift-tools-version:6.2
import Foundation
import PackageDescription

// Additive: powers `swift build` + SourceKit indexing only. The signed .app (cert-DR, TCC) is still
// built by the unchanged swiftc line in install.sh / package.sh — this manifest never feeds a release.

let speexPrefix = ProcessInfo.processInfo.environment["SPEEX_PREFIX"] ?? "/opt/homebrew/opt/speexdsp"

// Absolute: `swift build`'s working dir differs from swiftc's, so a relative header path won't resolve.
let headerPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("speex-bridge.h").path

let package = Package(
    name: "macrec",
    platforms: [.macOS("26.0")],
    targets: [
        // Same files as the swiftc line; explicit `sources:` stays self-limiting (no exclude list to drift).
        .executableTarget(
            name: "macrec",
            path: ".",
            sources: ["macrec.swift", "Sources"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags([
                    "-import-objc-header", headerPath,
                    "-Xcc", "-I\(speexPrefix)/include",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags(["\(speexPrefix)/lib/libspeexdsp.a"]),
            ]
        ),
    ]
)
