# macrec — dev rules for Claude

Single-file macOS menu-bar meeting recorder (`macrec.swift`). Menu-bar (tray) app today,
architected to grow into a full windowed app; recording is table stakes — the value is the
pipeline above it (transcript → summary → daily digest → knowledge). See `PIPELINE.md`.

**Read `AGENTS.md` too** — the operating rules distilled from maintainer feedback (the quality
bar, non-negotiable habits, the CS-fundamentals self-check, and the post-implementation
multi-agent review protocol). It is self-maintained: keep it current as feedback and best
practices surface, without being asked.

## The iron rule: after you build it, LOOK at it and TEST it

Never declare a change done from the code alone. Every change goes through, in order:

1. **Build**: `./install.sh` — must be 0 errors.
2. **Selftest**: `./macrec-stage.app/Contents/MacOS/macrec selftest` — must end `selftest: ALL PASS`.
   Every new pure function / decision gets a selftest case, reproducing the real failure it fixes
   (the exact numbers/strings from the incident). One mistake is forgivable; shipping it twice is not.
3. **For ANY UI change — actually SEE it**: `./macrec-stage.app/Contents/MacOS/macrec settings-snapshot /tmp/shots`
   then open the PNGs and look. A "structurally valid" pane (grids present, selftest green) shipped
   visually destroyed twice because it was never rendered. The `settings: no pane control is
   collapsed or overlapping` selftest now fails the build on that class of breakage — but still LOOK.
4. **Install + restart**: the app auto-reinstalls to `/Applications` via `install.sh`; then
   `launchctl kickstart -k gui/$(id -u)/com.ikhoon.macrec`.

## UI test kit

- `macrec settings-snapshot <dir>` renders each Settings pane to a faithful PNG (real appearance +
  window background) — the human-eyeball check. Read the PNGs.
- `macrec selftest` runs `paneLayoutIssues()` headlessly: lays out every pane and asserts no control
  is collapsed (~0 size) or overlapping. This is the automated, CI-run regression guard.
- `macrec caption-snapshot <dir>` captures the live overlay on screen at three opacities. It is a REAL
  screen capture (`screencapture -l<window>`): a translucent window's material is composited by the
  window server, so an offscreen render shows a blank slab and would "pass" no matter what. It needs
  Screen Recording permission for the terminal that runs it — if it fails, it says so rather than
  writing a misleading PNG.
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
