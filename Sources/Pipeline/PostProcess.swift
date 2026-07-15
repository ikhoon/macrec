import AppKit
import AVFoundation
import Compression
import EventKit
import Foundation

// MARK: - post-process hook (ETL stage 1: the app triggers, the user's script pipelines)
//
// After each transcript is saved, run the user's command with the file path appended — summarize with
// an LLM, translate, load into a notes DB, whatever; the pipeline lives in the user's script, so it
// changes without an app release. Runs in a LOGIN shell (`zsh -lc`) so PATH/brew/rc setup apply.
/// Fire-and-forget: a slow or hung hook can never block the engine. Output (both streams) is read to
/// EOF BEFORE waiting on exit — reading after would deadlock once the pipe buffer fills. `completion`
/// receives the exit status (or -1 when the launch itself failed); used by the selftest.
/// Shell-quote a single argument for the zsh command line.
func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// How a finished transcript is post-processed: off, the built-in summary, or a user shell command.
enum PostProcessMode: String { case off, summary, shell }
/// The agent CLI used for the built-in summary.
enum SummaryRunner: String, CaseIterable { case claude, codex, gemini }

/// The built-in summary prompt — the turn-key default (editable in Settings). Answering in the
/// transcript's own language keeps it correct for mixed ko/en/ja meetings.
let defaultSummaryPrompt = "Summarize this meeting transcript: key points, decisions made, and action items "
    + "with owners. If the file includes a calendar meeting-notes section, use it as context (agenda, "
    + "attendees, terminology) and note anything planned there that was not discussed. Answer in the same "
    + "language as the transcript."

/// Where the automatic summary lands. A dedicated output dir mirrors the transcripts' monthly
/// layout with the PLAIN transcript name (`<dir>/YYYY-MM/<name>.md` — the folder already says
/// "summary", and `.summary.md` read as clutter); only the next-to-the-transcript fallback ("")
/// keeps a short `-sum` marker to avoid colliding with the transcript itself. Pure + testable.
/// (The invocation mkdir -p's the parent, so the month folder appears on first use.)
func summaryOutputPath(transcriptPath: String, outDir: String) -> String {
    let t = URL(fileURLWithPath: transcriptPath)
    let base = t.deletingPathExtension().lastPathComponent
    let dir = outDir.trimmingCharacters(in: .whitespacesAndNewlines)
    if dir.isEmpty { return t.deletingLastPathComponent().appendingPathComponent("\(base)-sum.md").path }
    var root = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
    let month = String(base.prefix(7))                                     // "2026-07" from the file name
    if month.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil {
        root.appendPathComponent(month, isDirectory: true)
    }
    return root.appendingPathComponent("\(base).md").path
}

/// Build the shell invocation for a post-process run — nil when there's nothing to do. Pure + testable.
/// BUILT-IN (summary): the agent CLI gets the prompt and the transcript on stdin, output redirected to
/// the summary path. FREEFORM (shell): the user's command with the transcript path appended.
func postProcessInvocation(mode: PostProcessMode, runner: SummaryRunner, prompt: String, shellCmd: String,
                           transcriptPath: String, outDir: String) -> String? {
    switch mode {
    case .off:
        return nil
    case .shell:
        let c = shellCmd.trimmingCharacters(in: .whitespacesAndNewlines)
        return c.isEmpty ? nil : c + " " + shq(transcriptPath)
    case .summary:
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = p.isEmpty ? defaultSummaryPrompt : p
        let out = summaryOutputPath(transcriptPath: transcriptPath, outDir: outDir)
        let dir = URL(fileURLWithPath: out).deletingLastPathComponent().path
        let runnerCmd: String
        switch runner {
        case .claude: runnerCmd = "claude -p \(shq(effective)) < \(shq(transcriptPath))"
        case .gemini: runnerCmd = "gemini -p \(shq(effective)) < \(shq(transcriptPath))"
        // codex exec takes the prompt from stdin with `-`; prepend it to the transcript.
        case .codex:  runnerCmd = "{ printf '%s\\n\\n' \(shq(effective)); cat \(shq(transcriptPath)); } | codex exec -"
        }
        // The output dir may not exist (review finding: the redirect just failed); and a failed run
        // must not leave a misleading empty .summary.md — write .partial, promote only on success.
        return "mkdir -p \(shq(dir)) && \(runnerCmd) > \(shq(out + ".partial")) && mv \(shq(out + ".partial")) \(shq(out))"
    }
}

/// The effective mode. Migration (review finding): v1 had no mode key — the hook fired whenever the
/// command was set. An UNSET mode with a non-empty v1 command (pref or MR_POST_PROCESS) therefore
/// means `.shell`, or upgrading would silently kill an existing pipeline. Pure + testable.
func effectivePostProcessMode(rawMode: String, shellCmd: String) -> PostProcessMode {
    if let m = PostProcessMode(rawValue: rawMode) { return m }
    return shellCmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .off : .shell
}

/// Whether a completed segment is worth a transcript file. A segment that overlapped a calendar MEETING
/// is always kept; an ad-hoc recording with no meeting is kept only when there was real speech — at least
/// `minNonMeetingSeconds` (default 3 min) — so short non-meeting blips (a hallway chat, a passing video)
/// don't litter the notes (user rule). Pure + selftested.
func shouldKeepTranscript(hasMeeting: Bool, speechSeconds: Double, minNonMeetingSeconds: Double = 180) -> Bool {
    hasMeeting || speechSeconds >= minNonMeetingSeconds
}

/// Read the post-process prefs and build the invocation for a just-saved transcript.
/// The effective summary prompt: a readable prompt FILE overrides the inline text (same "…or file"
/// pattern as the hints; keep the prompt in your notes repo and iterate without touching Settings).
/// An unreadable configured file falls back to the inline text — and logs, never fails silently.
func effectiveSummaryPrompt(inline: String, filePath: String) -> String {
    let fp = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
    if !fp.isEmpty {
        let path = (fp as NSString).expandingTildeInPath
        if let txt = try? String(contentsOfFile: path, encoding: .utf8),
           !txt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return txt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        elog("summary: couldn't read prompt file \(path) — using the inline prompt")
    }
    return inline
}
