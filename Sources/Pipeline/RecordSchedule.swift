import AppKit
import AVFoundation
import Compression
import EventKit
import Foundation

// MARK: - recording schedule (record only Mon–Fri 10:00–19:00, minus lunch — instead of 24/7)
//
// Days ("mon-fri", "mon,wed,fri") and hour ranges ("10:00-12:00, 13:00-19:00" — the gap between
// ranges IS the lunch exclusion). Outside the window the engine is suspended; a manual Pause/Resume
// overrides the schedule until the next boundary.

/// Record now, given BOTH gates? Each gate admits the moment when its toggle is off; recording runs
/// only in the intersection (schedule hours AND, if calendar-gated, a live meeting). Both off = always
/// record — no behaviour change unless opted in. Pure + selftested.
func recordingWindowActive(scheduleEnabled: Bool, scheduleActive: Bool,
                           calendarGated: Bool, meetingActive: Bool) -> Bool {
    (!scheduleEnabled || scheduleActive) && (!calendarGated || meetingActive)
}

/// Why the recorder is parked, so the menu can explain the pause (`nil` = record now).
enum RecordPause: Equatable { case offHours, noMeeting }

/// When a manual Pause/Resume override should expire: the schedule's next boundary, or — when the
/// schedule defines none (disabled, or calendar-only gating) — the distant future, so the override
/// HOLDS until the user acts again. `nextBoundary` alone returns nil there, which would collapse the
/// override to "none" and let the next 30 s tick re-park a just-resumed engine. Pure + selftested.
func overrideExpiry(_ schedule: RecordSchedule, now: Date) -> Date {
    schedule.nextBoundary(after: now) ?? .distantFuture
}

/// The recording-window decision WITH its reason, layering calendar-permission fail-open onto
/// `recordingWindowActive`. Gating fails OPEN without Calendar access — a permission the user hasn't
/// granted must never silently stop all recording. Schedule is the outer gate, so when both block the
/// reason is off-hours. Pure + selftested.
func recordingWindowState(scheduleEnabled: Bool, scheduleActive: Bool, calendarGated: Bool,
                          calendarAuthorized: Bool, meetingActive: Bool) -> RecordPause? {
    let gated = calendarGated && calendarAuthorized   // no permission → not gated (fail open)
    if recordingWindowActive(scheduleEnabled: scheduleEnabled, scheduleActive: scheduleActive,
                             calendarGated: gated, meetingActive: meetingActive) { return nil }
    return (scheduleEnabled && !scheduleActive) ? .offHours : .noMeeting
}

/// The recording schedule — which weekdays + hour ranges recording is allowed, parsed from the fields.
struct RecordSchedule: Equatable {
    var enabled: Bool
    var weekdays: Set<Int>            // 1=Sun … 7=Sat (Calendar.component(.weekday))
    var ranges: [(start: Int, end: Int)]   // minutes since midnight, half-open [start, end)

    static func == (a: RecordSchedule, b: RecordSchedule) -> Bool {
        a.enabled == b.enabled && a.weekdays == b.weekdays
            && a.ranges.map { $0.start } == b.ranges.map { $0.start }
            && a.ranges.map { $0.end } == b.ranges.map { $0.end }
    }

    /// Users paste schedules from Notes/Slack where autocorrect swaps "-" for – / —, and Korean/Japanese
    /// input naturally writes ranges as 10:00~19:00 with full-width punctuation — accept all of it.
    static func normalized(_ s: String) -> String {
        var t = s
        for dash in ["–", "—", "−", "~", "〜", "～"] { t = t.replacingOccurrences(of: dash, with: "-") }
        for (from, to) in [("：", ":"), ("、", ","), ("，", ",")] { t = t.replacingOccurrences(of: from, with: to) }
        return t
    }

    /// "mon-fri" / "sat-mon" (wraps) / "mon,wed,fri" / "" → empty set. Case-insensitive. Pure + testable.
    static func parseDays(_ s: String) -> Set<Int> {
        let names = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]
        var out = Set<Int>()
        for part in normalized(s).lowercased().split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if let dash = part.firstIndex(of: "-") {
                guard let a = names[String(part[..<dash]).trimmingCharacters(in: .whitespaces)],
                      let b = names[String(part[part.index(after: dash)...]).trimmingCharacters(in: .whitespaces)] else { continue }
                var d = a
                while true { out.insert(d); if d == b { break }; d = d % 7 + 1 }   // wraps sat-mon
            } else if let d = names[part] {
                out.insert(d)
            }
        }
        return out
    }

    /// "10:00-12:00, 13:00-19:00" → minute ranges; "24:00" allowed as end-of-day. A start AFTER its
    /// end ("22:00-06:00") wraps past midnight into two ranges. Bad chunks skipped.
    static func parseRanges(_ s: String) -> [(start: Int, end: Int)] {
        func minutes(_ t: String) -> Int? {
            let p = t.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard p.count == 2, let h = p[0], let m = p[1], (0...24).contains(h), (0..<60).contains(m),
                  h < 24 || m == 0 else { return nil }
            return h * 60 + m
        }
        return normalized(s).split(separator: ",").flatMap { chunk -> [(start: Int, end: Int)] in
            let sides = chunk.split(separator: "-", maxSplits: 1).map(String.init)
            guard sides.count == 2, let a = minutes(sides[0]), let b = minutes(sides[1]), a != b else { return [] }
            if a < b { return [(a, b)] }
            return [(a, 1440), (0, b)].filter { $0.0 < $0.1 }   // overnight, e.g. 22:00-06:00
        }
    }

    /// A non-empty field where SOME chunk didn't parse is a typo, not intent — the Settings pane
    /// paints the field red so "10am-7pm" can't silently fall back to record-everything.
    static func daysValid(_ s: String) -> Bool { chunksOK(s) { !parseDays($0).isEmpty } }
    static func hoursValid(_ s: String) -> Bool { chunksOK(s) { !parseRanges($0).isEmpty } }
    private static func chunksOK(_ s: String, _ ok: (String) -> Bool) -> Bool {
        normalized(s).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.allSatisfy(ok)
    }

    static func from(enabled: Bool, days: String, hours: String) -> RecordSchedule {
        RecordSchedule(enabled: enabled, weekdays: parseDays(days), ranges: parseRanges(hours))
    }

    /// Should recording run at `date`? Disabled schedule = always. An enabled schedule with an EMPTY
    /// days/ranges field treats that dimension as "every day" / "all hours" (a half-filled form must
    /// never silently stop all recording).
    func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return true }
        if !weekdays.isEmpty, !weekdays.contains(calendar.component(.weekday, from: date)) { return false }
        guard !ranges.isEmpty else { return true }
        let mins = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        return ranges.contains { mins >= $0.start && mins < $0.end }
    }

    /// First active↔inactive flip after `date` (minute granularity), or nil when the schedule never
    /// changes state (disabled, or empty fields = always on). A manual override stores this as its
    /// EXPIRY TIMESTAMP — comparing against wall-clock time survives sleeping across any number of
    /// boundaries, where edge-detection on sampled state misses even flip counts.
    func nextBoundary(after date: Date, calendar: Calendar = .current) -> Date? {
        guard enabled, !(weekdays.isEmpty && ranges.isEmpty) else { return nil }
        let startActive = isActive(at: date, calendar: calendar)
        var t = date.addingTimeInterval(60 - date.timeIntervalSince1970.truncatingRemainder(dividingBy: 60))
        let limit = date.addingTimeInterval(8 * 86400)   // 11,520 one-minute probes worst case — trivial
        while t <= limit {
            if isActive(at: t, calendar: calendar) != startActive { return t }
            t = t.addingTimeInterval(60)
        }
        return nil
    }

    static var fromPrefs: RecordSchedule {
        from(enabled: Pref.bool(Pref.schedEnabled, "MR_SCHEDULE", false),
             days: Pref.explicit(Pref.schedDays, "MR_SCHEDULE_DAYS"),
             hours: Pref.explicit(Pref.schedHours, "MR_SCHEDULE_HOURS"))
    }
}

/// Dead/misrouted-input verdict: plenty of ENERGY-gate "voiced" time but almost none of it in
/// sustained speech-length envelope runs. Real speech forms ≥256 ms envelope runs; electrical
/// clicks and hum from a mic-less input never do. The voiced bar sits at 12 s because this is a
/// warning-only heuristic: real click incidents measured 14–50 s voiced per segment, while an hour
/// of short-backchannel speech (each utterance under the run bar) stays below it — crying "dead
/// mic" during a real conversation costs more than a missed warning. Pure + testable.
func micLooksDead(voiced: Double, speech: Double) -> Bool {
    voiced >= 12 && speech < 0.5
}

/// Reference implementation of the writer's envelope speech-run accounting — selftests pin the
/// semantics here, and a selftest feeds the SAME signal to the real SourceWriter to prove the two
/// never drift. A 16 ms block (256 samples) is voiced when its RMS clears the threshold AND ≥ ¼ of
/// its samples do (RMS alone lets dense click trains through); speech = samples inside ≥ 16
/// consecutive voiced blocks (~256 ms). Works on the envelope, NOT on raw samples: audio crosses
/// zero every half-cycle, so a per-sample run metric scores all real audio 0.
func speechlikeFrames(_ samples: [Float], threshold: Float = 0.02,
                      blockFrames: Int = 256, minRunBlocks: Int = 16) -> Int {
    var total = 0, run = 0
    for b in stride(from: 0, through: samples.count - blockFrames, by: blockFrames) {
        var sumSq = 0.0, above = 0
        for i in b..<(b + blockFrames) {
            let raw = abs(samples[i])
            let a = raw.isFinite ? raw : 0   // mirror the writer: corrupt samples poison nothing
            sumSq += Double(a) * Double(a)
            if a > threshold { above += 1 }
        }
        if sumSq / Double(blockFrames) > Double(threshold * threshold), above * 4 >= blockFrames {
            run += 1
            if run == minRunBlocks { total += run * blockFrames }
            else if run > minRunBlocks { total += blockFrames }
        } else { run = 0 }
    }
    return total
}

/// Self-clocking tail scheduler's fire decision — exactly one request in flight, refire only when
/// the tail actually moved, never after finalization. Pure + testable (the timing regressions
/// "not real-time" and "second line slow" both lived in this decision).
func shouldFireTailTranslation(tail: String, lastSent: String, inFlight: Bool, final: Bool) -> Bool {
    !final && !inFlight && !tail.isEmpty && tail != lastSent
}

/// Sentences that have COMPLETED inside a growing partial (terminator seen) — the unfinished tail
/// is excluded. A '.' only terminates when followed by whitespace, so "3.5" never splits and the
/// final period of a still-streaming line waits for its confirming space. Drives sentence-streamed
/// live translation. Pure + testable.
func completeSentences(_ text: String) -> [String] {
    var out: [String] = []
    var cur = ""
    let hard: Set<Character> = ["!", "?", "。", "！", "？", "…"]
    let chars = Array(text)
    for (i, ch) in chars.enumerated() {
        cur.append(ch)
        let ends = hard.contains(ch) || (ch == "." && i + 1 < chars.count && chars[i + 1].isWhitespace)
        if ends {
            let t = cur.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { out.append(t) }
            cur = ""
        }
    }
    return out
}
