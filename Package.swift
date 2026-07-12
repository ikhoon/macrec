// swift-tools-version:6.2
import Foundation
import PackageDescription

// macrec ships via install.sh / package.sh: an unchanged `swiftc` line still produces the signed .app,
// its cert-based Designated Requirement, and the TCC grants that depend on it. This manifest is
// deliberately ADDITIVE — it exists only so `swift build` and editor indexing (SourceKit-LSP) work on
// the exact same single module. It does NOT feed the release build; the scripts are untouched.

// SpeexDSP (the static AEC library) lives at a Homebrew prefix. Overridable for a non-standard install;
// the default is the Apple-silicon Homebrew path install.sh falls back to.
let speexPrefix = ProcessInfo.processInfo.environment["SPEEX_PREFIX"] ?? "/opt/homebrew/opt/speexdsp"

// The bridging header path must be ABSOLUTE: `swift build` compiles from a different working directory
// than the swiftc line, so a relative "speex-bridge.h" (which install.sh can use) would not resolve.
let headerPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("speex-bridge.h").path

let package = Package(
    name: "macrec",
    platforms: [.macOS("26.0")],
    targets: [
        // One executable target spanning the same files as the swiftc line: root macrec.swift (holds
        // @main) + every file under Sources/. Explicit `sources:` keeps the set self-limiting, so no
        // hand-maintained exclude list can drift out of date.
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
