// @main lives here so MacRecKit stays a library with no @main (which would fail `swift test` with a
// duplicate _main). Guarded: raw swiftc compiles everything as one module, so App is local, not imported.
#if SWIFT_PACKAGE
    import MacRecKit
#endif

@main
struct Main {
    static func main() async { await App.main() }
}
