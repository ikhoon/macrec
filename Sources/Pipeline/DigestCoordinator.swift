import Foundation

/// The daily-digest tick — L3 of the pipeline (PIPELINE.md). Once the configured time passes, digest
/// the day's meeting summaries into Daily/YYYY-MM/YYYY-MM-DD.md. Driven by the tray's 30 s timer; the
/// last-run marker (not a timer) makes a slept-through deadline catch up on wake.
///
/// Extracted from the tray controller so the WIRING is scenario-testable: the retry-storm incident
/// (453 claude spawns + 453 notifications in one afternoon) lived in exactly this loop while every
/// pure function it calls was already correct and already tested. `now` and `run` are injectable, so
/// a QA scenario replays a whole evening of 30 s ticks in milliseconds and counts spawns.
final class DigestCoordinator {
    /// Virtual clock — scenarios advance this; production leaves the default.
    var now: () -> Date = { Date() }
    /// The runner — production spawns the real login-shell command; scenarios substitute an
    /// instant fake. The completion must be called exactly once with the exit status.
    var run: (String, @escaping (Int32) -> Void) -> Void = { cmd, done in
        runPostProcessCommand(cmd) { status in DispatchQueue.main.async { done(status) } }
    }

    private(set) var inFlight = false
    private(set) var failures = 0                    // consecutive failures → backoff + one notification
    private(set) var nextAttempt = Date.distantPast  // a failed run retries after digestRetryDelay, not 30 s
    private(set) var spawnCount = 0                  // QA observation: how many runner processes launched

    /// One 30 s tick. Decides due-ness, backoff, and in-flight; launches at most one runner.
    func tick() {
        guard Pref.bool(Pref.dailyDigest, "MR_DAILY_DIGEST", false) else { return }
        let now = now()
        let time = Pref.str(Pref.dailyDigestTime, "MR_DAILY_DIGEST_TIME", "20:00")
        guard dailyDigestDue(now: now, time: time, lastRun: Pref.explicit(Pref.dailyDigestLastRun, "")) else { return }
        guard now >= nextAttempt else { return }   // backing off after a failure — not every 30 s tick
        let dayF = DateFormatter(); dayF.locale = Locale(identifier: "en_US_POSIX"); dayF.dateFormat = "yyyy-MM-dd"
        let day = dayF.string(from: now)
        // The 30 s tick must not launch a second digest, but a FAILED one has to retry — so the in-flight
        // guard is in memory and the persistent "done" marker is written only once the runner succeeds.
        // Writing the marker up front meant a login error at 20:00 silently cost the whole day.
        guard !inFlight else { return }
        inFlight = true
        // Every early return below must clear the flag, or the digest never runs again this process.
        var launched = false
        defer { if !launched { inFlight = false } }
        let cfg = EngineConfig.load()
        let fm = FileManager.default
        let month = String(day.prefix(7))
        let tDir = cfg.transcriptsDir.appendingPathComponent(month)
        let transcripts = ((try? fm.contentsOfDirectory(atPath: tDir.path)) ?? [])
            .filter { $0.hasSuffix(".md") }.map { tDir.appendingPathComponent($0).path }
        let sumPref = Pref.explicit(Pref.summaryOut, "MR_SUMMARY_OUT")
        let sDir = sumPref.isEmpty ? tDir.path
                                   : ((sumPref as NSString).expandingTildeInPath + "/" + month)
        let summaries = ((try? fm.contentsOfDirectory(atPath: sDir)) ?? [])
            .filter { $0.hasSuffix(".md") }.map { sDir + "/" + $0 }
        // The digest is promoted with `mv`, which overwrites whatever sits at the destination. A name
        // template that resolves onto an existing transcript/summary would silently destroy it.
        let existingNotes = Set(transcripts.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let out = dailyDigestOutputPath(day: day,
                                        outDir: Pref.explicit(Pref.dailyDigestOut, "MR_DAILY_DIGEST_OUT"),
                                        summaryOutDir: sumPref, transcriptsDir: cfg.transcriptsDir.path,
                                        nameTemplate: Pref.explicit(Pref.dailyDigestName, "MR_DAILY_DIGEST_NAME"))
        func retire(_ outcome: DigestOutcome) {
            if digestMarksDayDone(outcome) { Pref.d.set(day, forKey: Pref.dailyDigestLastRun) }
        }
        guard !existingNotes.contains(URL(fileURLWithPath: out).standardizedFileURL.path) else {
            elog("digest: \(out) is an existing transcript — refusing to overwrite it")
            retire(.wouldOverwrite)   // retrying changes nothing until the user edits the name
            Notifier.push(title: "Daily digest skipped",
                          body: "The file name resolves onto an existing note (\(URL(fileURLWithPath: out).lastPathComponent)). "
                              + "Change it in Settings › Summaries › File name.")
            return
        }
        // Exclude the digest itself: it lands in a folder we just scanned and shares the day prefix.
        let inputs = dailyDigestInputs(day: day, transcripts: transcripts, summaries: summaries, excluding: out)
        guard !inputs.isEmpty else { elog("digest: no meetings on \(day) — skipping"); retire(.nothingToDo); return }
        let runner = SummaryRunner(rawValue: Pref.explicit(Pref.summaryRunner, "MR_SUMMARY_RUNNER")) ?? .claude
        let inline = effectiveSummaryPrompt(inline: Pref.explicit(Pref.dailyPrompt, "MR_DAILY_DIGEST_PROMPT"),
                                            filePath: Pref.explicit(Pref.dailyPromptFile, "MR_DAILY_DIGEST_PROMPT_FILE"))
        let prompt = inline.isEmpty ? defaultDailyDigestPrompt : inline
        guard let cmd = dailyDigestInvocation(runner: runner, prompt: prompt,
                                              inputs: inputs, outPath: out) else { retire(.nothingToDo); return }
        elog("digest: \(day) — \(inputs.count) inputs → \(out)")
        SummaryStatus.shared.started("daily digest \(day)")
        launched = true
        spawnCount += 1
        run(cmd) { [weak self] status in
            guard let self else { return }
            defer { self.inFlight = false }
            if status == 0 {
                // Only a SUCCESSFUL run retires the day; a failure retries with backoff.
                elog("digest: \(day) finished (exit 0)")
                if digestMarksDayDone(.wrote) { Pref.d.set(day, forKey: Pref.dailyDigestLastRun) }
                self.failures = 0; self.nextAttempt = .distantPast
                SummaryStatus.shared.finished("daily digest \(day)", at: self.now(), output: out)
                Notifier.push(title: "Daily digest ready", body: "\(day) — \(inputs.count) meetings", filePath: out)
            } else {
                let why = reapFailedPostProcess(outPath: out)
                self.failures += 1
                let delay = digestRetryDelay(afterFailures: self.failures)
                self.nextAttempt = self.now().addingTimeInterval(delay)
                // The reason belongs in the LOG too, not only in a notification the user may miss.
                elog("digest: \(day) failed (exit \(status))" + (why.map { " — \($0)" } ?? " — no output")
                    + " — retry #\(self.failures) in \(Int(delay / 60)) min")
                SummaryStatus.shared.failed("daily digest \(day)", at: self.now(), reason: why)
                if digestShouldNotifyFailure(consecutiveFailures: self.failures) {
                    Notifier.push(title: "Daily digest failed",
                                  body: why ?? "The summary command exited with code \(status) — check Settings › Summaries.")
                }
            }
        }
    }
}
