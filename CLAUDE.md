# macrec — dev rules for Claude

macOS menu-bar meeting recorder. `macrec.swift` holds the app's entry logic (`public enum App`) and
the low-level primitives; `Sources/` holds the rest as **per-module directories**, one concern per
file — `Audio/`, `Live/`, `Pipeline/`, `Settings/`, `Tray/`, `Selftest/`, `Eval/`. **Standard SwiftPM
layout** (chosen to leverage the OSS ecosystem — packages, `swift test`, indexing, tooling): a library
target **MacRecKit** (`macrec.swift` + `Sources/`, no `@main`) + a thin executable **macrec**
(`Cli/Entry.swift`, holds `@main`, calls `App.main()`) + XCTest **Tests/MacRecKitTests** + a C module
**CSpeexDSP** for the SpeexDSP AEC. So `swift build` / `swift test` / editor indexing all work.
**Hybrid build (deliberate):** the signed `.app` is still produced by the single-module swiftc line in
`install.sh` / `package.sh` — `swiftc macrec.swift Cli/Entry.swift $(find Sources -name '*.swift')`
(recursive; `version.sh` searches the same way) — so the cert-based DR + TCC grants are untouched.
`Cli/Entry.swift` serves both build systems via `#if SWIFT_PACKAGE` (the import of MacRecKit / CSpeexDSP
is present only under `swift build`; the swiftc build is one module with a bridging header). `App.main()`
is `@MainActor` — the `await App.main()` hop would otherwise build the tray NSWindow off the main
thread. Menu-bar (tray) app today, architected to grow into a full windowed **desktop app**; recording
is table stakes — the value is the pipeline above it (transcript → summary → daily digest → knowledge).
See `PIPELINE.md`.

**Read `AGENTS.md` too** — the operating rules distilled from maintainer feedback (the quality
bar, non-negotiable habits, the CS-fundamentals self-check, and the post-implementation
multi-agent review protocol). It is self-maintained: keep it current as feedback and best
practices surface, without being asked.

## The iron rule: after you build it, LOOK at it and TEST it

Never declare a change done from the code alone. Every change goes through, in order:

1. **Format**: `swiftformat .` — CI hard-fails on `swiftformat --lint` drift, so format before you commit.
   The config (`.swiftformat`) is a hygiene guardrail (whitespace/redundancy), not a restyle.
2. **Build**: `./install.sh` — must be 0 errors.
3. **Selftest**: `./macrec-stage.app/Contents/MacOS/macrec selftest` — must end `selftest: ALL PASS`.
   Every new pure function / decision gets a selftest case, reproducing the real failure it fixes
   (the exact numbers/strings from the incident). One mistake is forgivable; shipping it twice is not.
4. **For ANY UI change — actually SEE it**: `./macrec-stage.app/Contents/MacOS/macrec settings-snapshot /tmp/shots`
   then open the PNGs and look. A "structurally valid" pane (grids present, selftest green) shipped
   visually destroyed twice because it was never rendered. The `settings: no pane control is
   collapsed or overlapping` selftest now fails the build on that class of breakage — but still LOOK.
5. **Install + restart**: the app auto-reinstalls to `/Applications` via `install.sh`; then
   `launchctl kickstart -k gui/$(id -u)/com.ikhoon.macrec`.

## UI test kit

- `macrec settings-snapshot <dir>` renders each Settings pane to a faithful PNG (real appearance +
  window background) — the human-eyeball check. Read the PNGs.
- `macrec selftest` runs `paneLayoutIssues()` headlessly: lays out every pane and asserts no control
  is collapsed (~0 size) or overlapping. This is the automated, CI-run regression guard.
- `macrec caption-snapshot <dir>` renders the overlay onto a checkerboard, in both presentations (log
  and subtitle) at three opacities including fully transparent — six PNGs, no permission needed. Look
  at them. It once had to shell out to `screencapture`, because a `.behindWindow` material inside a
  `.hudWindow` is composited by the window server and an offscreen render came back blank. Neither is
  in the panel any more. `snapshotIsBlank` still guards that failure: if the render comes back empty it
  refuses to write a reassuring PNG.
- **Test subcommands must not change the app.** `selftest` and the three snapshots run with
  `Keychain.disabled` and a throwaway defaults suite — driving the real UI persists as it goes, and
  `caption-snapshot` once left the user in subtitle mode at zero opacity.
- Live-caption / translation changes: also exercise the running overlay.

## Process

- Small, focused PRs; each merges green (CI + selftest). Never mega-PRs.
- Never put org/employer identifiers (real project/team/person names, internal hostnames) in code,
  fixtures, placeholders, or PR text. `git diff | grep` before `git add`.
- `push.default = simple` (a branch must push to its own name) — never fast-forward a feature commit
  straight onto `main`.
- Signing: stable self-signed cert keeps TCC grants across rebuilds; `install.sh` swaps the bundle
  atomically. Don't break the designated requirement.
- Never `launchctl submit` a one-shot — it relaunches on failure (a debug capture loop once crackled
  system audio until removed).

## Development direction — raising the bar

The recurring failure mode here is *declaring a feature done from the code*, not from using it.
Every rough edge the maintainer has had to catch — a "Choose…" button whose panel never surfaces,
a Resume that does nothing after the schedule paused us, a "Check for Updates" with no feedback, a
Grant-permissions item shown when permission is already granted, a half-built Summaries tab, a
menu-bar glyph with no identity — traces to the same roots: not driving the actual behavior, and
weak state-machine / feedback discipline. Software is hard to build and easy to break, so:

- **Fundamentals first.** Complete state machines (handle every state, incl. schedule-paused), no
  silent failures, UI bound to real state, a regression test per fix. `AGENTS.md §3` is the checklist.
- **Drive it, don't just build it.** The iron rule above is binding: snapshot AND exercise every
  control; reach every state. If only the maintainer is finding the bugs, QA didn't happen.
- **Review before done.** After implementing, run the multi-agent review protocol (`AGENTS.md §4`)
  — **5 perspectives, whatever the change size** (tokens are the budget) — then fix what it finds.
- **Quality over cadence.** Ship only what holds up to the above. Releases are earned, not scheduled.
