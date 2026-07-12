# AGENTS.md — operating rules for AI agents on macrec

This file is the maintainer's memory, written down so the same feedback isn't given twice.
Read it (and `CLAUDE.md`) before you touch anything. `CLAUDE.md` holds the build/verify iron
rule and the development direction; **this file holds the operating rules distilled from
maintainer feedback, plus the post-implementation review protocol.**

The cross-project method (the quality bar, the multi-agent review protocol, self-maintenance) is
recorded in the global `~/.claude/CLAUDE.md` so every project shares it. **This file is macrec's
instance of that method** — each rule below is tied to the real bug that motivated it.

## 0. Keep this file current (self-maintenance) — standing rule

You are expected to keep this file current **without being asked**. Whenever a session surfaces
new feedback, a recurring mistake, a decision, or a gap in these rules, append or revise the
relevant section **in the same session**, and say that you did it. Treat "the maintainer had to
say it twice" as a bug in this file, and fix the file. This self-maintenance rule is itself part
of the rules — do not wait for permission to improve the rules.

You may also record **well-known, established engineering best practices** proactively — you don't
need the maintainer to state them first — when they'd prevent a class of bug seen here. Keep them
concise and specific to macrec; don't pad the file with generic advice.

## 1. The bar

- **Quality over shipping.** A rough release is worse than no release ("구린데 릴리즈 해서 뭐하게?").
  Do not steer toward PRs/releases while rough edges remain. Earn the release with QA.
- **Independently QA.** Don't wait to be told what's broken — drive the app yourself and find it.
  If the maintainer is the one finding the bugs, you failed the QA step.
- **Never declare done from the code alone.** The `CLAUDE.md` iron rule is binding, and it has
  been violated: features shipped "structurally valid" (grids present, selftest green) yet
  visually or functionally broken. Snapshot AND drive it.
- **Software is hard to build and easy to break.** Assume any change can break something that
  worked. Prefer minimal, surgical edits; guard every change with a regression test and the
  review protocol below; never regress a working path to add a new one.

## 2. Non-negotiable habits (each maps to a real bug we shipped)

1. **Exercise every interactive control, not just its layout.** Click "Choose…", switch the
   Mode tab, reach schedule-pause, press Resume. A control wired to nothing (or a modal that
   never surfaces) looks perfect in a snapshot. *(Storage "Choose…" no-op; half-built Summaries tab.)*
2. **No silent actions.** Any user-initiated action gives visible **in-app** feedback — not only
   a suppressible notification. "Check for Updates" must show "Checking… / up to date / failed"
   in the UI. *(Check-for-Updates gave no reaction.)*
3. **Model the whole state machine.** Enumerate every state and transition and handle them all.
   A third state left unconsidered is a latent bug. *(schedulePaused made Resume a no-op because
   only paused/recording were handled in the toggle + enable logic.)*
4. **Drive UI from real state.** Menu items and glyphs reflect the actual system state, re-checked
   when shown. Never add an item unconditionally. *(Grant-permissions shown when already granted.)*
5. **Give the app an identity.** The user must be able to tell which app this is — menu-bar glyph,
   settings branding, vendor logos. Generic SF Symbols aren't enough.
6. **Every fix ships a regression test.** Add a `selftest` case that reproduces the real failure
   with the exact values from the incident (`CLAUDE.md`). Interactive controls also get a headless
   assertion (the `paneLayoutIssues()` pattern — e.g. "every Choose… button resolves its action").
   The maintainer will ask for the regression test — get there first.
7. **Code comments are written in English.** Always — including the "why" notes that quote a
   maintainer report. Paraphrase the report in English rather than pasting the Korean. Korean text in
   the source is reserved for *data*: UI titles, localized transcript strings, boilerplate filters,
   test fixtures.
8. **Never offer what can't work.** A control for an engine with no credential, a picker whose panel
   never opens, a slider whose range makes the feature unusable — all are the same bug: UI that
   promises capability the app doesn't have in that state. Gate the affordance on the state.
9. **Assert the observable effect, not the knob you turned.** `backdrop.alphaValue == 0.3` passed while
   the overlay rendered as an empty see-through window — the view's alpha was ignored by the compositor.
   A test that checks the value you assigned proves only that assignment works. Check the thing the user
   would see: that the fill exists, that the control resolves its action, that the file lands on disk.
   When a regression slips past a green suite, the suite is the bug: strengthen it in the same session.
10. **A default is a suggestion, never a decision.** Anything macrec picks on the user's behalf — a
   folder, a file name, a prompt, a schedule — must be overridable in Settings. Design the UX so the
   default is visible (as a placeholder / prefilled value) and the override is one control away.
   macrec's job is to create the month folder, not to choose where it lives or what the file is called.

## 3. CS fundamentals we hold ourselves to

The bugs here have been fundamentals, not exotica: unhandled states, controls bound to nothing,
silent failures, UI not reflecting state, no tests for interactive behavior. Before calling a
change done, self-check:

- **Correctness** — does it do the thing for *every* input, including empty / nil / error?
- **State** — are all states and transitions handled? Any dead, unreachable, or unhandled state?
- **Concurrency & lifecycle** — UI on the main thread; no races between start/stop/pause; no
  leaked tasks, observers, timers, or audio taps.
- **Feedback & errors** — every failure path is visible to the user and logged; nothing fails silent.
- **Resources** — files/observers/timers/taps cleaned up; atomic writes (`PIPELINE.md`).
- **Tests** — a selftest reproduces the fix; the build stays green.

## 4. Post-implementation review protocol (multi-agent)

After implementing a change — **before** declaring it done — run a concurrent, multi-perspective
review. Spawn review agents **in parallel**, each auditing the **same single change** from **one**
lens.

- **Sizing: 5 agents.** That is the standing budget — tokens are the constraint, so do NOT scale to 10
  for a large change. Spend the budget on the lenses the change actually touches, and always include
  the three mandatory ones below (observe · surface · completeness). Go above 5 only when the
  maintainer asks for it explicitly.
- Each agent returns a prioritized defect list (**P0** broken / **P1** rough / **P2** polish) with
  `macrec.swift:line` and a concrete fix. Agents **review only** — they do not edit.
- Then **synthesize:** dedupe, discard false positives (verify each against the code), fix the
  real ones, re-run build + selftest, and re-review if the fix was substantial.

**Why the review kept missing things** (maintainer, after a sweep of defects the review had passed:
"왜 리뷰에서는 잡히지가 않지?"). Every reviewer read *code*, and every reviewer was scoped to *the
diff*. So nothing in the protocol could ever see: a color that only goes wrong when focus moves; a
path field with no picker; an engine offered without its API key; an opacity slider that fades the
caption text; copy that reads verbose. Three rules close that gap — they are mandatory, not optional
lenses:

- **At least one reviewer OBSERVES, never reads.** It renders `settings-snapshot`, opens the PNGs,
  and drives the real control. Its findings must come from what it saw. Code-only reviewers state
  which findings they *inferred* rather than observed, so the synthesizer knows what to verify.
- **Review the SURFACE, not the diff.** A change to a pane puts the whole pane in scope — including
  defects that were already there. "Pre-existing" is not a defense; the maintainer will find it next.
- **One reviewer owns feature completeness.** Walk the user's journey end to end (open Settings → set
  a prompt file → save → configure the next pane; enable an engine → start the overlay → read a
  caption). Ask what a real user cannot do, not whether the code is right.

**Review lenses** (pick ~5 for small, up to 10 for large — choose the ones the change touches):

1. Correctness / logic
2. State-machine completeness (all states & transitions)
3. UI/UX & visual fidelity (snapshot the panes; match macOS System Settings idioms)
4. Edge cases & error handling (nil / empty / failure, first-run, migration)
5. Concurrency & lifecycle (main thread, races, task/observer/tap cleanup)
6. Regression risk (what existing behavior could this break?)
7. Codebase conventions & consistency (naming, comment density, idioms)
8. Security / privacy (TCC, Keychain, **no org/employer identifiers** anywhere — `CLAUDE.md`)
9. Performance & resource use
10. Test coverage (is there a selftest reproducing the fix?)

## 4a. Commit as you go — and split by dependency, never by keyword

Commit each fix the moment it is green (build + selftest). Letting a branch accumulate turns splitting
into archaeology.

When you do have to split an accumulated diff: group by **symbol dependency**, not by topic keywords.
A slice is a definition plus every call site plus the `selftest` checks that use it, and slices are
ordered so a symbol is defined before it is used. Classifying hunks by keyword scatters a definition
and its uses across commits and nothing compiles — that is a bug in the split, not evidence that the
file is unsplittable. Compile-check each slice with `swiftc` (never run an unsigned binary, see §4b).

## 4b. Never run macrec from an unsigned binary

A bare `swiftc … -o /tmp/x` binary has no code signature, so every Keychain read it makes raises an
authorization prompt — and `selftest` / the snapshot commands build the real Settings pane and the real
overlay, which ask each engine whether it is ready. Compile-check with `swiftc` if you must, but **run**
only `./macrec-stage.app/Contents/MacOS/macrec` (signed by `install.sh`). The test subcommands also set
`Keychain.disabled`, so they never read the maintainer's real credentials at all.

## 5. Decisions & preferences the maintainer has stated once — don't ask again

- **Queue my tangential opinions; don't detour.** When I spot something worth doing that isn't the
  current task — a refactor, a build-tool idea, a follow-up — I add it to `BACKLOG.md` and keep going on
  what was asked. I don't stop to present options or ask "which first?" for my *own* suggestions; I surface
  a queued idea only when the maintainer asks or it genuinely blocks the task. (Their explicit mid-work
  requests are different — those get captured AND acted on per §0.) *macrec-scoped for now, not a global rule.*
- **`BACKLOG.md` is the transparent todo list.** Manage work there, in-repo and diffable — not in GitHub
  Issues (overkill) and not only in an invisible internal task list. Keep it current as work lands.
- **Code changes update the docs they touch.** If a change makes `README` / `PIPELINE.md` /
  `ARCHITECTURE.md` / `VISION.md` / `AGENTS.md` / `CLAUDE.md` stale — a moved file, a changed build
  command, a renamed layout — update the doc in the same PR (or a tracked follow-up if the layout is
  still moving, then update once it settles). Stale docs are a bug.
- **Engage every code-review comment before merge.** CodeRabbit (or a human) review is not a formality:
  read each comment, and either *accept* it (fix + say so) or *defend* it (a reasoned wontfix) — never
  merge past an unaddressed comment. (The global rule "fixed and wontfix are different outcomes" applies;
  this is macrec's reminder to actually run it against CodeRabbit before merging.)
- **Split, one concern per file.** `macrec.swift` was one 8888-line file until the day it made a
  change set impossible to divide into compiling commits. It is now the CLI entry point plus the
  low-level primitives, and `Sources/` holds the rest as **per-module directories**: `Audio/`,
  `Live/`, `Pipeline/`, `Settings/`, `Tray/`, `Selftest/`, `Eval/`, each a concern per file. Still
  no SwiftPM — the build is `swiftc macrec.swift $(find Sources -name '*.swift')` (recursive, so
  subdir files compile automatically; `version.sh` searches the same way, and `let macrecVersion`
  can live in any of them). `Sources/` is what `swift package init` creates, so a later move to
  SwiftPM needs no rename.
- **Moving code is not changing code.** A refactor commit must prove it: capture `selftest` output
  before, and diff it after. Identical or it isn't pure motion. Never mix a fix into a move.
- **No org/employer identifiers** in code, fixtures, placeholders, or PR text (`CLAUDE.md`).
  `git diff | grep` before `git add`.
- **Deliberate prior picks** — the always-visible (non-overlay) scrollbar, non-shouty
  sentence-case headers, the lighter-orange voice tint, the modest pane title size — are
  intentional and annotated in code comments. Read the comment before "fixing" them.
- **Formatter is SwiftFormat; the linter (SwiftLint) is deferred.** Formatting is `swiftformat` with an
  **allowlist** config (`.swiftformat`) — whitespace/redundancy the code already follows, no restyle — so
  the dense hand-tuned style (semicolons, long lines, aligned comments) survives; CI lints it pinned.
  SwiftLint is the intended linter but its sourcekit **won't load on a CommandLineTools-only machine**
  (it crashes), so it lands only once full Xcode is installed — a linter you can run locally beats a
  CI-only one. Apple's `swift-format` was rejected as the formatter: on macrec's style it wanted to
  rewrite ~18k lines. Don't re-litigate; extend it (add SwiftLint) when Xcode is available.
- **No idle — keep improving.** When the maintainer hands you no immediate task (or you're waiting on
  CI / a review to finish), don't stop: strengthen tests, improve code quality, and pull the next item
  from `BACKLOG.md`. Momentum with the quality bar intact — never busywork, and never a risky change you
  can't verify. *(macrec-scoped for now.)*
