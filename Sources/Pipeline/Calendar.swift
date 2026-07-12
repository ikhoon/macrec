import AppKit
import AVFoundation
import Compression
import EventKit
import Foundation

/// A calendar event reduced to what titling a recorded segment depends on — a pure stand-in for
/// `EKEvent` so the choice below is directly testable.
struct EventCandidate: Equatable {
    let title: String
    let start: Date
    let end: Date
    let hasLink: Bool   // a Zoom/Meet/Teams/Webex URL sits somewhere on the event
}

/// Seconds of the recorded segment `[segStart, segEnd]` the event actually covers.
func eventOverlap(_ e: EventCandidate, segStart: Date, segEnd: Date) -> TimeInterval {
    max(0, min(e.end, segEnd).timeIntervalSince(max(e.start, segStart)))
}

/// Can this event plausibly be what the segment recorded? It must overlap at least HALF of whichever
/// is shorter — itself, or the segment. Any positive overlap used to qualify, so the next meeting
/// bleeding two minutes into a 62-minute recording could title the whole thing. Half-of-the-shorter
/// still admits a one-minute tail that lies wholly inside a 90-minute meeting: that IS the meeting.
func explainsSegment(_ e: EventCandidate, segStart: Date, segEnd: Date) -> Bool {
    let ov = eventOverlap(e, segStart: segStart, segEnd: segEnd)
    guard ov > 0 else { return false }   // caught only by the ±padding: it belongs to a neighbour
    let shorter = min(e.end.timeIntervalSince(e.start), segEnd.timeIntervalSince(segStart))
    return ov * 2 >= shorter
}

/// Index of the event that best titles a recorded segment. Among the events that could plausibly BE
/// the segment, a meeting link decides: it separates a real online meeting from the all-day offsite
/// and the personal blocks sitting on top of it — a 32-minute "Service Mesh Weekly Sync" should win
/// over a 58-minute "인버터". Raw overlap cannot make that call, which is why the eligibility floor,
/// not the ordering, is what keeps a 2-minute sliver from stealing the name. Pure + selftested.
func bestEventIndex(segStart: Date, segEnd: Date, candidates: [EventCandidate]) -> Int? {
    func ov(_ e: EventCandidate) -> TimeInterval { eventOverlap(e, segStart: segStart, segEnd: segEnd) }
    return candidates.indices
        .filter { explainsSegment(candidates[$0], segStart: segStart, segEnd: segEnd) }
        .sorted { i, j in
            let a = candidates[i], b = candidates[j]
            if a.hasLink != b.hasLink { return a.hasLink }     // an online meeting beats a calendar block
            if ov(a) != ov(b) { return ov(a) > ov(b) }         // then the one that fills the segment
            if a.start != b.start { return a.start < b.start } // still tied → earliest, then by title,
            return a.title < b.title                           // so the pick never depends on EK order
        }
        .first
}

/// Is a calendar meeting live right now (± `padding`)? The gate for "record only during meetings":
/// `now` ∈ [start − pad, end + pad) for a real (end > start) event. Negative padding is clamped to 0
/// so it can never silently shrink the window; a zero/negative-duration event is ignored. Selftested.
func meetingActiveNow(_ events: [EventCandidate], now: Date, padding: TimeInterval) -> Bool {
    let pad = max(0, padding)
    return events.contains {
        $0.end > $0.start && now >= $0.start.addingTimeInterval(-pad) && now < $0.end.addingTimeInterval(pad)
    }
}

// MARK: - calendar lookup (title a transcript from the overlapping event)

enum CalendarLookup {
    static let store = EKEventStore()

    static var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Trigger the one-time Calendar permission prompt (no-op if already decided).
    static func requestAccess() {
        store.requestFullAccessToEvents { ok, err in
            if let err = err { elog("calendar access: \(err)") } else { elog("calendar access granted=\(ok)") }
        }
    }

    /// `start` is the EVENT's start (not the segment's) — a transcript stamps itself with the meeting's
    /// time when one maps. See `transcriptStart`.
    struct Match { let title: String; let link: String?; let attendees: [String]; let start: Date }

    /// The event calendars the user chose to source titles from (by title). Empty selection — or a
    /// selection that matches nothing (e.g. a renamed calendar) — means "all calendars" (nil).
    static var selectedCalendars: [EKCalendar]? {
        let names = (Pref.d.stringArray(forKey: Pref.calendars) ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        let want = Set(names)
        let cals = store.calendars(for: .event).filter { want.contains($0.title) }
        return cals.isEmpty ? nil : cals
    }

    /// Titles of all available event calendars (deduped, sorted) — for the Settings picker.
    static func availableCalendarNames() -> [String] {
        guard authorized else { return [] }
        return Array(Set(store.calendars(for: .event).map { $0.title })).sorted()
    }

    /// Calendars with the color the user assigned them in Calendar.app, so the picker reads like the
    /// calendar they already know. `EKCalendar.color` is normalized to sRGB before use — a calendar can
    /// carry a color in another space, and the components are only meaningful once converted (same
    /// approach as maccal's `hexColor`). Deduped by title (first color wins), sorted by title.
    static func availableCalendars() -> [(name: String, color: NSColor)] {
        guard authorized else { return [] }
        var byName: [String: NSColor] = [:]
        for c in store.calendars(for: .event) where byName[c.title] == nil {
            byName[c.title] = c.color?.usingColorSpace(.sRGB) ?? .secondaryLabelColor
        }
        return byName.keys.sorted().map { ($0, byName[$0]!) }
    }

    /// Best event overlapping [start, end] — the one that fills most of it (see `bestEventIndex`).
    static func match(start: Date, end: Date) -> Match? {
        guard authorized else { return nil }
        let pred = store.predicateForEvents(withStart: start.addingTimeInterval(-300), end: end.addingTimeInterval(60), calendars: selectedCalendars)
        let events = store.events(matching: pred).filter { !$0.isAllDay && !($0.title ?? "").isEmpty }
        guard !events.isEmpty else { return nil }

        func link(_ e: EKEvent) -> String? {
            let hay = [e.location, e.notes, e.url?.absoluteString].compactMap { $0 }.joined(separator: "\n")
            let pats = ["zoom.us/j/", "zoom.us/my/", "zoom.us/s/", "meet.google.com/", "teams.microsoft.com/", "webex.com/"]
            for tok in hay.split(whereSeparator: { " \n\t\r<>\"'(),".contains($0) }) {
                let s = String(tok)
                if pats.contains(where: { s.lowercased().contains($0) }) { return s }
            }
            return nil
        }

        // An event caught only by the ±padding has zero true overlap: it belongs to the NEXT segment, and
        // since the event's start stamps the file name, keeping it makes two segments collide.
        let candidates = events.map {
            EventCandidate(title: $0.title, start: $0.startDate, end: $0.endDate, hasLink: link($0) != nil)
        }
        guard let i = bestEventIndex(segStart: start, segEnd: end, candidates: candidates) else { return nil }
        let chosen = events[i]
        let names = (chosen.attendees ?? []).compactMap { $0.name }.filter { !$0.isEmpty }
        return Match(title: chosen.title, link: link(chosen), attendees: names, start: chosen.startDate)
    }
}
