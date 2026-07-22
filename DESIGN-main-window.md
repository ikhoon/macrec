# macrec Main Window — Concrete AppKit Design

Grounded in the current code (`LibraryWindow` already ships the chrome recipe at :213-219; `LiveCaptionWindow` is a separate
`.utilityWindow` panel; the `Tint` enum with `.blue`/`.orange`/`.purple` lives at LibraryWindow.swift:16-32; three windows exist today —
`LibraryWindow`, `LiveCaptionWindow`, `TodayWindow`).

---

## 1. Overall structure — sidebar sections, three panes

**One window. Sidebar-as-router, NOT tabs.** (1Password Watchtower/All-Items peers; Claude sidebar; explicitly reject NSTabView per all four
references.)

Build it as an **`NSSplitViewController`** with three `NSSplitViewItem`s (Claude/Notes primitive, ref #5 takeaway 2):

- **Item 0 — sidebar** (`behavior = .sidebar`): gives you, free, the `.sidebar`-material vibrancy, the automatic top inset that tucks the
  source list under the floating traffic lights, and `minimumThickness`/`maximumThickness`. This replaces the raw `NSSplitView` +
  `NSSplitViewDelegate` that `LibraryWindow` drives today (:380). **Width min 240 / max 360pt** (Linear/Things source-list guidance, ref
  #4).
- **Item 1 — detail** (`behavior = .default`): the view swapped per selection.
- **Item 2 — inspector** (`behavior = .default`, `isCollapsed = true` by default): reserved, not built in v1. Both rails collapse for a
  focused center column (MacWhisper collapsible-rails model, ref #3).

**Sidebar contents, top→bottom** (the Claude/1Password shape):

1. **Three pinned nav rows at the very top** — `Live Captions`, `Library`, `Status` — each a monochrome SF Symbol + label. This is the mode
   switcher (ref #2 takeaway 7, ref #1 takeaway 1). Selecting one swaps Item 1's view controller. Order Live first (it's the "now" surface),
   Library, then Status.
   - `Live Captions` → `waveform` (or `dot.radio`)
   - `Library` → `rectangle.stack` / `text.bubble`
   - `Status` → `heart.text.square` (Watchtower analogy)
2. **A hairline separator** (barely-there, ref #4).
3. **Library's day tree** — the existing `NSOutlineView` with `selectionHighlightStyle = .sourceList`, `isGroupItem` day headers ("Today —
   date"/"Yesterday — date" from `libraryDayLabel`), recordings nested one level. **Cap nesting at 2 levels** (Things/Linear rule). Only
   shown/relevant when Library is the active section; simplest v1 is to keep the day tree always visible below the nav rows and have
   selecting a recording auto-activate the Library detail.

This is deliberately **two visible panes** (sidebar + detail) with a third inspector pane latent — matches 1Password/Bear/Claude, and
matches what `LibraryWindow` already is, so it's the minimum structural change.

**Retire `LiveCaptionWindow` as a primary surface** — fold its streaming view into the Library detail area as the "Live Captions" section
(ref #1 takeaway 1, ref #5 liveContent). **Keep the floating always-on-top `NSPanel` overlay** as a separate, optional "across-the-room
reader" (ref #5 explicitly: two presentations of the same data). Don't delete the panel; demote it from "the Live UI" to "the second
screen."

---

## 2. Window chrome — exact treatment

Reuse the recipe macrec already ships and **add two lines**:

```
styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
w.titlebarAppearsTransparent = true      // already at LibraryWindow.swift:215
w.titleVisibility = .hidden              // already :216
w.titlebarSeparatorStyle = .none         // ADD — kills the hairline under the titlebar (Claude/Notes seamless top, ref #5 takeaway 1)
```

- **No NSToolbar in v1.** Keep macrec's hand-rolled top `NSStackView` bar (the collapsing search lives there and NSToolbar constrains it —
  ref #5 search note, and the documented Sequoia `NSSearchToolbarItem` focus bug). This also sidesteps the `titleVisibility=.hidden` +
  NSToolbar `displayMode` restore gotcha (Apple forum 779805, ref #1).
- **Traffic lights: do NOT reposition them** in the main window. `LiveCaptionWindow` hand-grabs
  `standardWindowButton(.closeButton)?.superview` (:181) — that hack is fragile; don't carry it over (ref #5 takeaway 3). Instead **inset
  content**: the top bar already uses `edgeInsets left:78` (clears all three lights). **Raise `top` from 8 to ~28pt** so the native titlebar
  drag region survives.
- **Drag region:** leave the top ~28pt free of interactive controls rather than setting `isMovableByWindowBackground = true` (that steals
  drags from content — ref #5).
- **Draggable action anchors:** because the titlebar is invisible, keep the primary verbs in **fixed, predictable corners** (MacWhisper
  discipline, ref #3 takeaway 7) — a Record/Stop control anchored bottom-right of the Live pane.

---

## 3. Color — monochrome palette + selection/icons/links

**The hard constraint (ref #5, verified-correct):** `controlAccentColor` is **not** overridable per-app by any public API. "Going graphite"
therefore means *stop drawing accent yourself* + *override selection drawing*. Three concrete edits:

**(a) Kill accent selection — the single most important change.** Subclass `NSTableRowView` and override `isEmphasized` to always return
`false`. The row then paints `unemphasizedSelectedContentBackgroundColor` (a neutral, light/dark-correct gray) instead of blue, with zero
custom drawing (ref #5 takeaway 4). `selectionHighlightStyle = .sourceList` alone is **not enough** — it still tints with accent when the
window is key. Apply to both the sidebar outline and the Library list.

**(b) Detail `NSTextView` selection also follows accent** — set
`textView.selectedTextAttributes[.backgroundColor] = .unemphasizedSelectedContentBackgroundColor`
or the transcript/summary text selection stays blue (ref #5 takeaway 6).

**(c) Delete the `Tint` enum** (LibraryWindow.swift:16-32) and its switch (~:1065-1068). Every SF Symbol becomes a **template image tinted
`labelColor`** (primary glyphs) / **`secondaryLabelColor`** (trailing status glyphs — already used at :974/:1031/:1083). **Differentiate
recording kinds by GLYPH SHAPE, not hue** (ref #5 takeaway 5, 1Password monochrome-sidebar rule ref #1). So `newspaper` for digest,
`waveform` for audio, `text.bubble` for transcript — all mono.

**Palette (neutral, system-dynamic so light/dark invert for free):**

| Role | NSColor |
|---|---|
| Primary text / active glyph | `labelColor` |
| Secondary text / muted subtitle / status glyph | `secondaryLabelColor` |
| Empty-state glyph, disabled | `tertiaryLabelColor` |
| Selection fill | `unemphasizedSelectedContentBackgroundColor` |
| Hairlines / separators | `separatorColor` |
| Sidebar background | `NSVisualEffectView` material `.sidebar` |

Prefer system dynamic colors over hard-coded Claude hexes (`#faf9f5` etc., ref #2) **because macrec is native** — system colors already give
correct light/dark, vibrancy, and increase-contrast behavior that hard-coded warm-neutrals would fight. (If the maintainer later wants the
warm-cream identity specifically, layer it as dynamic `NSColor` asset catalog entries — but v1 should ship system-neutral, which is the safe
monochrome.)

**The ONE sanctioned accent = semantic status only, never chrome** (Linear "flashlight" rule ref #4; ref #5 takeaway 7):
- **Live/recording indicator:** a **monochrome** pulsing `labelColor` dot or `recording.circle` SF Symbol — **NOT `systemRed`** (ref #5
  liveContent).
- **Status health (the one real color):** `checkmark.circle.fill` `systemGreen` / `exclamationmark.triangle.fill` `systemYellow` /
  `xmark.octagon.fill` `systemRed` — this is *information*, and even Things/Fantastical keep status color. Filled symbols over bare dots.

**Links** in rendered markdown: avoid `systemBlue`. Use `labelColor` with underline, or the status-only exception — do not introduce a blue
link color into the monochrome detail.

**Dark/light gotcha to enforce (ref #5 takeaway 8):** `layer.backgroundColor = someDynamicColor.cgColor` **freezes** to set-time appearance.
Any layer-backed fill (e.g. the Status health dot) must re-assign its `cgColor` in `updateLayer()` / `viewDidChangeEffectiveAppearance`, or
wrap drawing in `effectiveAppearance.performAsCurrentDrawingAppearance {}`. `NSColor.setFill()` inside `drawRect` (LibraryWindow.swift:1297)
is already safe — it re-evaluates each draw.

---

## 4. Search — collapsible magnifier

**macrec already ships exactly the requested pattern — keep it** (LibraryWindow.swift:228-242, 422-442): a borderless `magnifyingglass`
`NSButton` (`isBordered=false`, `bezelStyle=.inline`) that on click unhides the `NSSearchField`, `makeFirstResponder`s it, and collapses
back to the icon on empty end-editing via `NSSearchFieldDelegate`. This is the right hand-rolled choice (ref #5 search; Things/Linear/Bear
all favor collapsed/summoned search over always-on, ref #4).

Three polish items:
- **Animate the reveal** — it currently toggles `isHidden` instantly. Animate the field's **width constraint** via `NSAnimationContext`
  (`animator().constant` 0→full over ~0.15-0.2s) (ref #2, ref #5).
- **Anchor it to the list column**, not the sidebar (1Password rule, ref #1 takeaway 6). In the unified window that means the top bar above
  the Library detail/list, after the `left:78` traffic-light inset.
- **Wire ⌘F (and optionally ⌘K)** to the same expansion so keyboard users never hit the collapsed icon as a dead end (Linear ⌘K palette /
  Things Quick Find, ref #4 takeaway 6).
- **Keep live-filter-on-keystroke** (`controlTextDidChange`, :441). **Do NOT copy 1Password 8's deferred-results search** — reviewers panned
  it as un-Mac-like (ref #1 AVOID).

---

## 5. Live Captions — where it lives, how it streams

**Lives as the top sidebar section, rendered in the same detail pane** as a recorded transcript, same typography, same monochrome chrome
(ref #1 liveContent, ref #3 takeaway 3 — "a mode, not a popover").

Reuse `LiveCaptionWindow`'s proven streaming model (ref #5 liveContent), re-hosted as a **docked auto-scrolling `NSTextView`**:
- **Incremental append + `scrollToEndOfDocument` on each new line** — never reflow the whole buffer (perf + no flicker).
- **Interim vs final by gray-level, not color** (Claude token-streaming, ref #2 liveContent): newest/interim text at `labelColor`; as lines
  finalize and age, ramp older lines to `secondaryLabelColor` → `tertiaryLabelColor` (the same alpha ramp as `captionLineAlpha`, in
  grayscale).
- **Translation** carried as the primary line with the original demoted to a muted secondary line above/beside it (`subtitleLine` model),
  hierarchy by gray-level not a bordered panel (ref #2, ref #4 liveContent).
- **Live indicator monochrome** — pulsing dot / `recording.circle`, never `systemRed`.
- **Record/Stop anchored bottom-right** of the pane (MacWhisper fixed-corner discipline, ref #3).
- **Click-to-seek parity** (MacWhisper, ref #3 takeaway 2): make live and library transcript rows share one row component so clicking any
  line seeks audio and the active segment highlights — live and finished transcripts feel identical.

Empty state when no session: centered `tertiaryLabelColor` SF Symbol + one muted line ("No live session — start recording to see captions"),
one action button (ref #5 listDetail upgrade).

---

## 6. Library day-view / calendar

Keep what exists, make it monochrome:
- **Day groups** stay as `NSOutlineView` group rows via `isGroupItem` (LibraryWindow.swift:954) with `libraryDayLabel` headers — small-caps
  `secondaryLabelColor` (ref #1, ref #2 date-band captions).
- **Rows two-line, breathable** (1Password/Claude density, ref #1/#2 listDetail): leading 16pt mono kind glyph + primary "HH:MM Title" +
  muted subtitle, trailing status glyphs (`sparkles` summarized, `waveform` audio) in `secondaryLabelColor`. Hairline separators only; lean
  on whitespace (Linear "removed unnecessary separators", ref #4).
- **The existing mini-month calendar** (`LibraryCalendarView`, lights recorded days, filters on day-click — Fantastical-like) **stays,
  recolored monochrome** (ref #5 listDetail): recorded-day dots `secondaryLabelColor`, selected-day ring
  `unemphasizedSelectedContentBackgroundColor`, **mark TODAY with bold/filled `labelColor`** — not the `systemRed` Calendar uses.
- **Detail = card stack** (1Password "sections of fields with air between", ref #1): summary/transcript markdown as one card, audio player
  as its own card, generous vertical whitespace; **constrain the markdown to a ~680-720pt readable measure**, not full-bleed (Claude, ref
  #2); **hide markdown syntax markers** in the rendered view (Bear hybrid editor, ref #4).

---

## 7. Ordered implementation plan — small shippable PRs

Each merges green (build + selftest + `qa.sh`), each is independently verifiable by snapshot. Start from today's `LibraryWindow` as the
shell.

**PR 1 — Monochrome pass (no structural change).** Delete `Tint` enum (:16-32) + switch (:1065-8); tint all glyphs
`labelColor`/`secondaryLabelColor`. Add the `isEmphasized=false` `NSTableRowView` subclass. Set `textView.selectedTextAttributes`
background. Add `titlebarSeparatorStyle = .none`. Recolor the calendar (today = bold `labelColor`, no red). **Selftest:** extend
`libraryRowSpec` cases to assert glyph-not-hue; add a decision test that selection color is the unemphasized token. Snapshot both
light/dark. *Lowest risk, biggest visible win, ships the maintainer's #1 ask ("no blue") immediately.*

**PR 2 — Search animation + keyboard.** Animate the width constraint; wire ⌘F/⌘K to expand+focus. Snapshot mid-animation isn't possible, so
verify by driving it. *Tiny, isolated.*

**PR 3 — Convert the shell to `NSSplitViewController` with a `.sidebar` item.** Move the existing day outline into a sidebar split item;
detail into the content item; latent collapsed inspector item. Behavior identical to today — this is a **refactor PR** whose only job is the
new container (vibrancy, free traffic-light inset, raise top inset to 28). **Selftest:** `paneLayoutIssues()` must still pass; add a
scenario asserting the sidebar collapses/expands without orphaning selection.

**PR 4 — Sidebar nav rows + section routing.** Add the three pinned rows (Live/Library/Status) above the day tree; selecting one swaps the
detail view controller. Library keeps today's behavior. Status shows a placeholder health card (wire real `TodayHealth` next). **Scenario
selftest:** each section selectable, detail swaps, state survives round-trips (ref: the recurring "dead affordance" bug — derive
enable+action from one function).

**PR 5 — Fold Live Captions into the main window.** Re-host `LiveCaptionWindow`'s streaming view as the Live section's docked `NSTextView`
(incremental append, gray-level interim/final, mono live dot, click-to-seek). Keep the floating overlay panel as the optional second screen.
**Scenario selftest:** replay a streamed session in-process (virtual clock + injected events per CLAUDE.md), assert append-not-reflow and
interim→final gray ramp. Exercise the *running* overlay too (iron rule).

**PR 6 — Fold Status/health in properly** (`TodayWindow` → Status section), with filled semantic SF Symbols, layer-color re-resolve on
appearance change. Retire `TodayWindow` as a standalone window.

**PR 7 — Row density + detail card stack + constrained markdown width** (two-line rows, card stack, ~700pt measure, hidden markdown syntax).
Snapshot-heavy; pure presentation.

After each PR: `swiftformat` → `./install.sh` → `selftest` (incl. SCENARIO) → `settings-snapshot`/look → `qa.sh` → run the 5-lens + Codex
review protocol.

---

## The 3 biggest risks

1. **Selection stays blue anyway.** `selectionHighlightStyle = .sourceList` is a well-known half-fix — it still emphasizes with the system
   accent when the window is key, and `controlAccentColor` can't be overridden per-app. If PR 1 relies on the style property alone, the
   maintainer will still see blue on focus. **Mitigation:** the `isEmphasized=false` `NSTableRowView` override is mandatory, and it must
   cover *both* tables *and* the `NSTextView` selection background — test with the window **key/focused**, not just unfocused (a harness
   that reads color while the window is inactive will pass a bug that ships).

2. **Traffic-light / drag-region breakage in the unified window.** `fullSizeContentView` + `titleVisibility=.hidden` + a full-height sidebar
   is exactly where the drag region disappears or the lights overlap the first row. The `LiveCaptionWindow` response was to hand-grab and
   reposition the buttons (:181) — fragile across OS versions and must **not** be copied. **Mitigation:** inset content (`left:78`,
   `top:28`), never reposition; the `.sidebar` split item's automatic top inset is doing real work — verify on the actual OS that the first
   sidebar row clears the lights and the top 28pt still drags.

3. **Live Captions regressions from re-hosting.** The floating panel has hard-won behavior — the `.hudWindow`-avoidance for true
   transparency, `becomesKeyOnlyIfNeeded` for text-selection focus, non-activating float. Moving the *rendering* into a docked pane while
   keeping the panel means two code paths for one stream; naive extraction can reflow the whole buffer (flicker/perf) or break click-to-
   seek/selection. **Mitigation:** PR 5 must share one row/segment component between live and library, keep append-incremental +
   `scrollToEndOfDocument`, and prove it with a replayed streaming *scenario* selftest (break its guard once to confirm the gate works) plus
   driving the real overlay — never sign off from the diff.

Files that change most: `Sources/Library/LibraryWindow.swift` (chrome, color, search, container), `Sources/Live/LiveCaptionWindow.swift`
(extract streaming view), `Sources/Today/TodayWindow.swift` (fold into Status), `Sources/Tray/WindowedApp.swift`/`AppController.swift`
(window wiring), plus `Sources/Selftest/{LibrarySelftests,ScenarioSelftests,TodaySelftests}.swift`.
