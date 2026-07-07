# macrec — dev rules for Claude

Single-file macOS menu-bar meeting recorder (`macrec.swift`). Menu-bar (tray) app today,
architected to grow into a full windowed app; recording is table stakes — the value is the
pipeline above it (transcript → summary → daily digest → knowledge). See `PIPELINE.md`.

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
- Live-caption / translation overlay changes: exercise the running overlay (they have no snapshot yet
  — add one if you touch that surface).

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
