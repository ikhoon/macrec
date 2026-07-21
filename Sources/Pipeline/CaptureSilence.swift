import Foundation

// MARK: - captured-silence detection (the "dropped-metric" silent-failure class)

/// A MIC segment of pure digital silence: a live, authorized microphone floors above `epsilon`
/// (its noise floor), so a peak below it means the capture path produced no signal at all — a
/// muted/dead mic or a wrong input device. Mic ONLY, deliberately: the system-audio tap is a
/// digital source whose peak is exactly 0 whenever no app renders audio, so it can never separate
/// "dead" from "idle" and would cry wolf on every quiet stretch. Pure.
func isCaptureSilent(micPeak: Float, epsilon: Float = 0.001) -> Bool {
    micPeak < epsilon
}

/// The run verdict: fire only after `threshold` CONSECUTIVE pure-silence mic segments — one can be
/// a fluke; a sustained run of digital zero from a live mic is a capture failure. Pure.
func capturedSilenceRun(silentStreak: Int, threshold: Int = 2) -> Bool {
    silentStreak >= threshold
}

/// Should this segment feed the silence streak at all? Only a LIVE rotation with the mic granted:
/// a suspended (locked/asleep) rotation records nothing by design, a missing mic grant records
/// nothing by permission, a manual flush is user-driven, and an adopted orphan belongs to a PAST
/// run — counting any of them would alarm on a healthy recorder. Pure.
func captureSilenceEligible(micGranted: Bool, suspended: Bool, manual: Bool, adopted: Bool) -> Bool {
    micGranted && !suspended && !manual && !adopted
}

/// Persist + read back the day-keyed verdict (the #27 outage pattern): stamped once per run when
/// the streak trips, surfaced by Today, self-clears the next local day.
enum CaptureSilence {
    static func record(now: Date = Date(), d: UserDefaults = Pref.d) {
        d.set(now.timeIntervalSince1970, forKey: Pref.capturedSilenceAt)
    }

    static func detectedToday(now: Date = Date(), d: UserDefaults = Pref.d, calendar: Calendar = .current) -> Bool {
        let at = d.double(forKey: Pref.capturedSilenceAt)
        guard at > 0 else { return false }
        return todayString(Date(timeIntervalSince1970: at), calendar: calendar) == todayString(now, calendar: calendar)
    }
}
