import AppKit
import AVFoundation
import Compression
import EventKit
import Foundation

// MARK: L3 — daily digest (see PIPELINE.md; aggregates the day's summaries at a set time)

let defaultDailyDigestPrompt = "These are summaries (or transcripts) of one day's meetings, in "
    + "chronological order. Write a daily digest: an overview of the day, highlights per meeting, "
    + "and a combined list of decisions and action items with owners. Answer in the same language "
    + "as the input."

/// Is the daily digest due? True once `now` passes today's HH:mm deadline and today's digest
/// hasn't run yet. The last-run marker (not a fired timer) is what makes a slept-through deadline
/// CATCH UP on wake instead of skipping the day. Pure + testable.
func dailyDigestDue(now: Date, time: String, lastRun: String, calendar: Calendar = .current) -> Bool {
    let hm = time.split(separator: ":").compactMap { Int($0) }
    guard hm.count == 2, (0..<24).contains(hm[0]), (0..<60).contains(hm[1]) else { return false }
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd"
    let today = f.string(from: now)
    guard lastRun != today else { return false }
    let mins = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
    return mins >= hm[0] * 60 + hm[1]
}

/// Should the day be marked done, given how the digest ended? Only a run that produced a file, or one
/// that can never succeed today (nothing to summarize, a name that would clobber a note), retires the
/// day. A runner that failed — no login, no network — must be retried on the next tick, or a transient
/// error at 20:00 silently costs the whole day. Pure + selftested.
enum DigestOutcome: Equatable { case wrote, nothingToDo, wouldOverwrite, runnerFailed }
func digestMarksDayDone(_ outcome: DigestOutcome) -> Bool {
    switch outcome {
    case .wrote, .nothingToDo, .wouldOverwrite: return true
    case .runnerFailed:                         return false
    }
}

/// The digest's file name from a user template: `{date}` / `{month}`, default `{date}.md`. Separators
/// are stripped (a `/` would escape the month folder) and the day is forced in — a template without it
/// resolves to one path for the whole month and the atomic `mv` would eat yesterday. Pure + selftested.
let dailyDigestNameDefault = "{date}.md"
func dailyDigestFileName(day: String, template: String = dailyDigestNameDefault) -> String {
    let t = template.trimmingCharacters(in: .whitespacesAndNewlines)
    var name = (t.isEmpty ? dailyDigestNameDefault : t)
        .replacingOccurrences(of: "{date}", with: day)
        .replacingOccurrences(of: "{month}", with: String(day.prefix(7)))
        .replacingOccurrences(of: "/", with: "-")
    if !name.lowercased().hasSuffix(".md") { name += ".md" }
    if name == ".md" { name = "\(day).md" }
    // A template with no {date} ("notes.md", or only {month}) resolves to the SAME path every day of
    // the month, and the digest's atomic promote is an `mv` — yesterday's digest would be overwritten
    // without a word. The day is not negotiable; the rest of the name is the user's.
    return name.contains(day) ? name : "\(day)-\(name)"
}

/// The day's digest inputs: the meeting SUMMARY where one exists, else the transcript, joined on the
/// shared `yyyy-MM-dd-HHmm` basename and sorted by name. `excluding` is the digest about to be written —
/// it shares the folder and the day prefix, so without this it feeds on its own output.
func dailyDigestInputs(day: String, transcripts: [String], summaries: [String], excluding: String = "") -> [String] {
    let skip = excluding.isEmpty ? "" : URL(fileURLWithPath: excluding).standardizedFileURL.path
    func kept(_ p: String) -> Bool { skip.isEmpty || URL(fileURLWithPath: p).standardizedFileURL.path != skip }
    // A summary saved next to its transcript is named `<base>-sum.md` (summaryOutputPath). Keying the
    // map on the raw basename meant `<base>-sum` never matched `<base>`, so the digest silently fed on
    // raw transcripts instead of the compact summaries whenever "Save summary to" was left empty.
    let summaryByBase = Dictionary(summaries.filter(kept).map { p -> (String, String) in
        let b = URL(fileURLWithPath: p).deletingPathExtension().lastPathComponent
        return (b.hasSuffix("-sum") ? String(b.dropLast(4)) : b, p)
    }, uniquingKeysWith: { a, _ in a })
    return transcripts
        .filter { kept($0) && URL(fileURLWithPath: $0).lastPathComponent.hasPrefix(day) }
        .sorted { URL(fileURLWithPath: $0).lastPathComponent < URL(fileURLWithPath: $1).lastPathComponent }
        .map { summaryByBase[URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent] ?? $0 }
}

/// Where the digest lands: `<dir>/YYYY-MM/<name>`. "" falls back to the summaries dir (or the
/// transcripts dir when summaries also default) — the same month folder as the day's notes. Pure.
func dailyDigestOutputPath(day: String, outDir: String, summaryOutDir: String, transcriptsDir: String,
                           nameTemplate: String = dailyDigestNameDefault) -> String {
    let dir = outDir.trimmingCharacters(in: .whitespacesAndNewlines)
    let sum = summaryOutDir.trimmingCharacters(in: .whitespacesAndNewlines)
    let root: URL
    if !dir.isEmpty {
        root = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
    } else if !sum.isEmpty {
        root = URL(fileURLWithPath: (sum as NSString).expandingTildeInPath)
    } else {
        root = URL(fileURLWithPath: transcriptsDir)
    }
    return root.appendingPathComponent(String(day.prefix(7)), isDirectory: true)
        .appendingPathComponent(dailyDigestFileName(day: day, template: nameTemplate)).path
}

/// The `> .partial && promote` tail shared by the summary and digest invocations, now prepending an H1
/// equal to the FILE name (user rule: the runner's output carries no reliable title of its own). The H1
/// is composed only AFTER the runner succeeds — a failed run's .partial must keep the runner's own words
/// for reapFailedPostProcess, not a header line masquerading as the reason. Pure + selftested.
func titledPromoteTail(runnerCmd: String, outPath: String) -> String {
    let title = URL(fileURLWithPath: outPath).deletingPathExtension().lastPathComponent
    let partial = outPath + ".partial", staged = outPath + ".partial2"
    return "\(runnerCmd) > \(shq(partial))"
        + " && { printf '# %s\\n\\n' \(shq(title)); cat \(shq(partial)); } > \(shq(staged))"
        + " && mv \(shq(staged)) \(shq(outPath)) && rm -f \(shq(partial))"
}

/// Shell invocation for the digest: cat the day's inputs into the summary runner, atomic promote.
/// Same runner CLI templates and .partial contract as the per-meeting summary. Pure + testable.
func dailyDigestInvocation(runner: SummaryRunner, prompt: String, inputs: [String], outPath: String) -> String? {
    guard !inputs.isEmpty else { return nil }
    let dir = URL(fileURLWithPath: outPath).deletingLastPathComponent().path
    let cat = "cat " + inputs.map(shq).joined(separator: " ")
    let runnerCmd: String
    switch runner {
    case .claude: runnerCmd = "\(cat) | claude -p \(shq(prompt))"
    case .gemini: runnerCmd = "\(cat) | gemini -p \(shq(prompt))"
    case .codex:  runnerCmd = "{ printf '%s\\n\\n' \(shq(prompt)); \(cat); } | codex exec -"
    }
    return "mkdir -p \(shq(dir)) && " + titledPromoteTail(runnerCmd: runnerCmd, outPath: outPath)
}

/// What post-processing is doing right now. Without this the pipeline is a black box: a summary runs
/// after a transcript is saved, leaves no trace, and the app looks broken.
enum SummaryActivity: Equatable {
    case off
    case idle
    case running(String)
    case done(String, Date)
    case failed(String, Date, reason: String?)
}

/// The tray row for post-processing. Pure + selftested.
func summaryMenuTitle(_ activity: SummaryActivity, hm: (Date) -> String) -> String {
    switch activity {
    case .off:                 return "Summaries: off"
    case .idle:                return "Summary: after the next transcript"
    case .running(let file):   return "Summary: running… \(file)"
    case .done(let file, let t):      return "Summary: \(file) · \(hm(t))"
    case .failed(let file, let t, _): return "Summary FAILED: \(file) · \(hm(t))"
    }
}

/// What clicking the summary row does. Enablement and the action come from ONE decision, so a row can
/// never be clickable and then do nothing — the defect this project keeps reproducing. Pure + selftested.
enum SummaryRowAction: Equatable {
    case none
    case reveal(String)              // the file it produced
    case explain(String, String?)    // (file, why it failed)
}
func summaryRowAction(_ activity: SummaryActivity, lastOutput: String?) -> SummaryRowAction {
    switch activity {
    case .failed(let file, _, let reason): return .explain(file, reason)
    case .done, .idle, .running:
        guard let out = lastOutput else { return .none }
        return .reveal(out)
    case .off: return .none
    }
}

/// The tray row for the daily digest. Pure + selftested.
func digestMenuTitle(enabled: Bool, dueTime: String, lastRun: String, today: String) -> String {
    guard enabled else { return "Daily digest: off" }
    if lastRun == today { return "Daily digest: written today" }
    return "Daily digest: due at \(dueTime)"
}

/// Last known post-processing activity. Written from the process queue, read on the main thread.
final class SummaryStatus {
    static let shared = SummaryStatus()
    private let lock = NSLock()
    private var activity: SummaryActivity = .idle
    private var lastPath: String?

    var current: SummaryActivity { lock.lock(); defer { lock.unlock() }; return activity }
    var lastOutput: String? { lock.lock(); defer { lock.unlock() }; return lastPath }
    /// Both halves under ONE lock: reading them separately lets a failure land between the two and the
    /// row then offers to reveal a file for a run that just failed.
    var snapshot: (SummaryActivity, String?) { lock.lock(); defer { lock.unlock() }; return (activity, lastPath) }

    func started(_ file: String) { lock.lock(); activity = .running(file); lock.unlock() }
    func finished(_ file: String, at date: Date, output: String?) {
        lock.lock(); activity = .done(file, date); lastPath = output; lock.unlock()
    }
    func failed(_ file: String, at date: Date, reason: String?) {
        lock.lock(); activity = .failed(file, date, reason: reason); lock.unlock()
    }
    func resetForTest() { lock.lock(); activity = .idle; lastPath = nil; lock.unlock() }
}

/// The claude CLI's current OAuth access token, parsed from its own Keychain item JSON. Works around the
/// CLI reporting "Not logged in" whenever its process tree starts at launchd (anthropics/claude-code#77213)
/// — the token itself authenticates fine there via CLAUDE_CODE_OAUTH_TOKEN; only the CLI's own lookup
/// fails. nil for malformed JSON or an expired token (expiresAt is epoch-milliseconds). Pure + selftested.
func claudeCliAccessToken(fromKeychainJSON json: String, now: Date = Date()) -> String? {
    guard let data = json.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let o = (obj["claudeAiOauth"] as? [String: Any]) ?? obj
    guard let tok = o["accessToken"] as? String, !tok.isEmpty else { return nil }
    if let exp = (o["expiresAt"] as? NSNumber)?.doubleValue, exp > 0,
       now.timeIntervalSince1970 * 1000 >= exp { return nil }
    return tok
}

/// Read the claude CLI's Keychain item via /usr/bin/security — empirically prompt-free (the item's ACL
/// admits the security tool), including from launchd. Best-effort: any failure returns nil and the
/// runner simply runs without a token (the digest backoff handles the resulting failure).
func readClaudeCliKeychainJSON() -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// How long to wait before retrying a FAILED digest. The old behavior retried on every 30 s tick —
/// 453 claude spawns (and 453 failure notifications) in one afternoon when the CLI lost its login.
/// Backoff: 10 min, 30 min, then hourly; the day is never given up (a fixed login still digests today).
/// Pure + selftested.
func digestRetryDelay(afterFailures n: Int) -> TimeInterval {
    switch n {
    case ..<1: return 0
    case 1: return 600
    case 2: return 1800
    default: return 3600
    }
}

/// Notify about a digest failure only ONCE per failure streak — the fix is the same whether it failed
/// once or fifty times, and a notification per retry is spam that gets the app silenced. Pure + selftested.
func digestShouldNotifyFailure(consecutiveFailures n: Int) -> Bool { n == 1 }

/// Does this mode write a summary file at the summary path? Only the built-in `.summary` mode redirects
/// into `<out>.partial` and promotes it. A freeform shell hook is handed the transcript and writes
/// wherever it likes — offering to reveal `<out>` after it runs would open a file that never existed,
/// and reading `<out>.partial` for a failure reason would find nothing. Pure + selftested.
func postProcessWritesSummaryFile(_ mode: PostProcessMode) -> Bool { mode == .summary }

/// A summary runner writes its STDOUT to `<out>.partial` and only then promotes it, so when it fails
/// the reason is inside that file, not on stderr — `claude` exiting 1 with "Not logged in · Please run
/// /login" left nothing but "exit 1" in the log. On failure, read the reason back and delete the orphan.
/// Returns the first line worth showing, if any. Pure enough to test: the path is injected.
@discardableResult
func reapFailedPostProcess(outPath: String, fs: FileManager = .default) -> String? {
    let partial = outPath + ".partial"
    defer { try? fs.removeItem(atPath: partial) }
    // Read a head, not the file: a runner can stream megabytes before it dies. Lossy decoding, because a
    // half-written UTF-8 sequence at the cut must not throw the reason away.
    guard let h = FileHandle(forReadingAtPath: partial) else { return nil }
    defer { try? h.close() }
    let head = (try? h.read(upToCount: 8192)) ?? Data()
    guard !head.isEmpty else { return nil }
    let text = String(decoding: head, as: UTF8.self)
    let reason = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        .first(where: { !$0.isEmpty })
    return reason.map { String($0.prefix(200)) }
}

func postProcessInvocationFromPrefs(transcriptPath: String) -> String? {
    let mode = effectivePostProcessMode(rawMode: Pref.explicit(Pref.postProcessMode, "MR_POST_PROCESS_MODE"),
                                        shellCmd: Pref.postProcessCommand)
    let runner = SummaryRunner(rawValue: Pref.explicit(Pref.summaryRunner, "MR_SUMMARY_RUNNER")) ?? .claude
    let prompt = effectiveSummaryPrompt(inline: Pref.explicit(Pref.summaryPrompt, "MR_SUMMARY_PROMPT"),
                                        filePath: Pref.explicit(Pref.summaryPromptFile, "MR_SUMMARY_PROMPT_FILE"))
    return postProcessInvocation(mode: mode, runner: runner,
                                 prompt: prompt,
                                 shellCmd: Pref.postProcessCommand,
                                 transcriptPath: transcriptPath,
                                 outDir: Pref.explicit(Pref.summaryOut, "MR_SUMMARY_OUT"))
}

/// Fire-and-forget: a slow or hung command can never block the engine. Runs in a LOGIN shell
/// (`zsh -lc`) so PATH/brew/rc setup apply (agent CLIs like `claude` just work). Output (both
/// streams) is read to EOF BEFORE waiting on exit — reading after would deadlock once the pipe
/// buffer fills. `completion` receives the exit status (or -1 when the launch failed); selftest uses it.
func runPostProcessCommand(_ command: String, completion: ((Int32) -> Void)? = nil) {
    let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cmd.isEmpty else { return }
    DispatchQueue.global(qos: .utility).async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", cmd]
        // `zsh -l` reads .zprofile/.zshenv but NOT .zshrc — where many users export PATH. Prepend the
        // common CLI install dirs so `claude`/`gemini`/`codex` resolve regardless of rc-file layout.
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin:\(home)/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        // The claude CLI authenticates fine from a terminal but reports "Not logged in" when its process
        // tree starts at launchd (anthropics/claude-code#77213). CLAUDE_CODE_OAUTH_TOKEN works there, so:
        // an exported var wins; else an explicit Settings token; else BORROW the CLI's own current token
        // from its Keychain item — zero user setup, same scope the CLI already holds.
        if env["CLAUDE_CODE_OAUTH_TOKEN"] == nil, cmd.contains("claude") {
            if let t = Keychain.get("claude"), !t.isEmpty {
                env["CLAUDE_CODE_OAUTH_TOKEN"] = t
            } else if !Keychain.disabled, let json = readClaudeCliKeychainJSON(),
                      let t = claudeCliAccessToken(fromKeychainJSON: json) {
                env["CLAUDE_CODE_OAUTH_TOKEN"] = t
            }
        }
        p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        do {
            try p.run()
            // A hook whose child keeps the pipe open would pin this thread forever (review finding) —
            // terminate after 15 min; readDataToEndOfFile then unblocks on pipe EOF.
            let killer = DispatchWorkItem { [weak p] in
                guard let p, p.isRunning else { return }
                elog("post-process: timed out after 15 min — terminating")
                p.terminate()
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 900, execute: killer)
            let data = out.fileHandleForReading.readDataToEndOfFile()   // EOF first, then exit — no pipe deadlock
            p.waitUntilExit()
            killer.cancel()
            // The command redirects its own stdout into `<out>.partial`, so this pipe is usually empty and
            // the reason lives in that file — see reapFailedPostProcess, which the callers use on failure.
            let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            elog("post-process: exit \(p.terminationStatus)" + (s.isEmpty ? "" : " — \(s.prefix(400))"))
            completion?(p.terminationStatus)
        } catch {
            elog("post-process: launch failed — \(error.localizedDescription)")
            completion?(-1)
        }
    }
}
