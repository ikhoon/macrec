// The app's @main lives here, in a tiny executable target, so MacRecKit stays a library with no @main
// (a library with @main fails `swift test` with a duplicate `_main`). It just calls App.main().
//
// The import is guarded: SWIFT_PACKAGE is defined only by `swift build`/`swift test` (multi-target),
// where App lives in the separate MacRecKit module. The release .app is still built by the single-module
// swiftc line in install.sh/package.sh, which compiles this file alongside MacRecKit's sources — there
// App is in the same module, so the import must be absent. One entry file, both build systems.
#if SWIFT_PACKAGE
    import MacRecKit
#endif

@main
struct Main {
    static func main() async { await App.main() }
}
