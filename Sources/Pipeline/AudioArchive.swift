import AppKit
import AVFoundation
import Compression
import EventKit
import Foundation

// MARK: - audio archive tiers (raw WAV → AAC after N days → deleted after M days)
//
// An hour of voiced 16 kHz mono PCM is ~115 MB; the same hour as 32 kbps AAC is ~14 MB (⅛).
// Recent segments stay WAV (instant scrubbing / re-transcription); older ones are archived to
// .m4a and the transcript's audio link is rewritten to match. Deletion applies to both forms.

enum AudioTier: Equatable { case raw, compressed, deleted }

struct AudioArchivePolicy: Equatable {
    var rawDays: Int      // days a file stays raw WAV; 0 = never compress
    var totalDays: Int    // age at which audio (raw or compressed) is deleted; 0 = keep forever

    func tier(ageDays: Double) -> AudioTier {
        if totalDays > 0, ageDays >= Double(totalDays) { return .deleted }   // delete beats compress
        if rawDays > 0, ageDays >= Double(rawDays) { return .compressed }
        return .raw
    }

    /// Combo-box text → days. "90 days" / "6 months" / "2 weeks" / "1 year" / bare "45";
    /// "Unlimited" / "Don't compress" / "0" → 0 (forever / never). nil = unparseable.
    static func parseRetentionDays(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty { return nil }
        if t == "0" || t.hasPrefix("unlimited") || t.hasPrefix("forever")
            || t.hasPrefix("never") || t.hasPrefix("don") { return 0 }
        let digits = t.prefix { $0.isNumber }
        guard !digits.isEmpty, let n = Int(digits), n >= 0 else { return nil }
        let unit = t.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        // checked multiply: this runs on every Settings keystroke — pasting "…775807 years" must
        // turn the field red, not trap and kill the recorder mid-meeting.
        func mul(_ b: Int) -> Int? {
            let r = n.multipliedReportingOverflow(by: b); return r.overflow ? nil : r.partialValue
        }
        if unit.isEmpty || unit.hasPrefix("d") { return n }
        if unit.hasPrefix("w") { return mul(7) }
        if unit.hasPrefix("mo") { return mul(30) }
        if unit.hasPrefix("y") { return mul(365) }
        return nil
    }

    static func retentionTitle(_ days: Int) -> String {
        if days == 0 { return "Unlimited" }
        if days % 365 == 0 { return days == 365 ? "1 year" : "\(days / 365) years" }
        return "\(days) days"
    }
}

enum AudioArchiver {
    /// WAV → AAC 32 kbps .m4a (afconvert). Writes to a .partial temp, then promotes — a killed
    /// sweep never leaves a half-written archive behind. The original's modification date is
    /// carried over so the retention clock keeps counting from RECORDING time, not archive time.
    /// 16 kHz mono rejects higher AAC bitrates (64k fails with '!dat'), so 32k is also the ceiling.
    static func compress(_ wav: URL, to out: URL) -> Bool {
        let fm = FileManager.default
        // pid-unique temp: the tray app's sweep and a manual `macrec sweep` can overlap — a shared
        // temp name would let one process promote the other's still-being-written file.
        let tmp = out.appendingPathExtension("partial-\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.removeItem(at: tmp)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "m4af", "-d", "aac", "-b", "32000", wav.path, tmp.path]
        do { try p.run() } catch { elog("archive: afconvert launch failed: \(error)"); return false }
        p.waitUntilExit()
        let size = (try? fm.attributesOfItem(atPath: tmp.path))?[.size] as? Int ?? 0
        guard p.terminationStatus == 0, size > 0 else {
            elog("archive: afconvert failed (status \(p.terminationStatus)) — keeping \(wav.lastPathComponent)")
            try? fm.removeItem(at: tmp)
            return false
        }
        let mdate = (try? wav.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        try? fm.removeItem(at: out)
        do { try fm.moveItem(at: tmp, to: out) } catch { try? fm.removeItem(at: tmp); return false }
        if let mdate { try? fm.setAttributes([.modificationDate: mdate], ofItemAtPath: out.path) }
        return true
    }
}
