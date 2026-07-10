# The macrec pipeline

Recording is table stakes — the value ladder is what happens *after* the audio lands.
Every stage below is a **file-based, idempotent derivation**: it reads its inputs from disk by
naming convention, writes its output atomically (`.partial` → promote), and can be re-run at any
time without damage. No stage knows about the tray UI — a future full windowed app browses and
re-runs the same files through the same pure functions.

```
L0  audio            Audio/YYYY-MM/<start>.wav            capture (mic + system), AEC
 │                                    └─ archived to .m4a by the retention sweep
 ▼
L1  transcript       Transcripts/YYYY-MM/<start>[-title].md    whisper.cpp batch, speaker-labeled,
 │                                                             anti-hallucination scrub
 ▼
L2  meeting summary  Summaries/YYYY-MM/<same name>.md      per-transcript, summary runner CLI
 │                                                         (claude / codex / gemini), event-driven
 ▼
L3  daily digest     <chosen>/YYYY-MM/YYYY-MM-DD.md        once a day at a configured time,
 │                                                         aggregates the day's L2 (falls back to
 │                                                         L1 when a summary is missing)
 ▼
L4  knowledge        (future) refinement into the user's notes DB — weekly rollups, topic pages,
                     action-item tracking across days
```

## Contracts

- **Naming is the join key.** `<start>` = `yyyy-MM-dd-HHmm` (+ optional calendar slug). L2 keeps
  L1's exact basename; L3 keys on the date prefix. Renaming a file breaks its lineage — don't.
- **Monthly folders everywhere** (`YYYY-MM/`), created on demand.
- **Atomic writes.** Every generated file goes through `<name>.partial` and is promoted only on
  success — a killed run never leaves a half-written output masquerading as done.
- **Idempotent + re-runnable.** A stage may be re-invoked for the same input; it overwrites its
  own output and nothing else.
- **Triggers.** L1/L2 are event-driven (segment completed). L3 is clock-driven: a daily deadline
  checked by the periodic tick, with a last-run marker so a sleeping Mac catches up on wake
  instead of skipping the day.

## Where code lives

Pure, testable functions build every path and shell invocation (`summaryOutputPath`,
`dailyDigestOutputPath`, `postProcessInvocation`, `dailyDigestInvocation`, `dailyDigestDue`) —
selftest covers them. The tray app only *schedules* these; it owns none of the logic.
