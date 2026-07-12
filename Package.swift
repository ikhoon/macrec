// swift-tools-version:6.2
import Foundation
import PackageDescription

// The signed .app is still built by the single-module swiftc line in install.sh / package.sh (it
// compiles macrec.swift + Sources + Cli/Entry.swift into one binary, with speex-bridge.h as its
// bridging header). This manifest additionally lets `swift build`, SourceKit indexing, and `swift test`
// work by splitting the same files into a library (MacRecKit, no @main) + a thin executable (@main) +
// an XCTest target, with speex reached through a proper C module (CSpeexDSP) rather than a bridging
// header — a bridging header can't live on a library others import. See Cli/Entry.swift + the
// `#if SWIFT_PACKAGE import CSpeexDSP` guards for how one set of files serves both build systems.

// SpeexDSP's Homebrew prefix. For a non-default install (e.g. Intel brew at /usr/local), build with
// `SPEEX_PREFIX=$(brew --prefix speexdsp) swift build`.
let speexPrefix = ProcessInfo.processInfo.environment["SPEEX_PREFIX"] ?? "/opt/homebrew/opt/speexdsp"

let package = Package(
    name: "macrec",
    platforms: [.macOS("26.0")],
    targets: [
        // speex's C headers as a module for the swift-build path (the .a is linked by MacRecKit below).
        .systemLibrary(name: "CSpeexDSP", path: "CSpeexDSP"),
        // The whole app as a library — NO @main — so the XCTest target can @testable import it without
        // a duplicate-_main clash. `exclude` hands the sibling target dirs to their own targets.
        .target(
            name: "MacRecKit",
            dependencies: ["CSpeexDSP"],
            path: ".",
            exclude: ["Cli", "Tests", "CSpeexDSP"],
            sources: ["macrec.swift", "Sources"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // clang needs speex's include dir to resolve <speex/…> from CSpeexDSP's shim header.
                .unsafeFlags(["-Xcc", "-I\(speexPrefix)/include"]),
            ],
            linkerSettings: [
                .unsafeFlags(["\(speexPrefix)/lib/libspeexdsp.a"]),
            ]
        ),
        // Thin executable: @main → App.main(). This is the same Cli/Entry.swift the swiftc line compiles.
        .executableTarget(
            name: "macrec",
            dependencies: ["MacRecKit"],
            path: "Cli",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // XCTest over the SAME check-closure functions the `macrec selftest` subcommand runs.
        .testTarget(
            name: "MacRecKitTests",
            dependencies: ["MacRecKit"],
            path: "Tests/MacRecKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
