import AVFoundation
import Foundation

// MARK: - adopting orphaned segments (a restart must not cost a recording)

// Engine stop/crash leaves the in-flight segment's track WAVs in workDir and used to throw the
// audio away ("trailing partial segment discarded") — a dev-loop restart once ate the first five
// minutes of a real call. The pipeline is file-based and idempotent (PIPELINE.md), so the next
// start ADOPTS what it finds: re-derive the stats the dead writers held in memory by scanning the
// files, then push a normal CompletedSegment through the normal gates. Never twice: candidates are
// MOVED before processing, processed-but-kept debug tracks live in processed/, and the first run
// with this feature sweeps the pre-existing backlog aside instead of re-transcribing history.

/// Parse "seg-yyyy-MM-dd-HHmmss" back into the segment's start date.
func orphanSegmentStart(_ stem: String, timeZone: TimeZone = .current) -> Date? {
    guard stem.hasPrefix("seg-") else { return nil }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = timeZone
    f.dateFormat = "yyyy-MM-dd-HHmmss"
    return f.date(from: String(stem.dropFirst(4)))
}

/// The stems safe to adopt from a workDir listing: seg-* track files with a parseable date where
/// EVERY file of the stem has been untouched for `minAgeSeconds` — a live writer flushes
/// constantly, so age is what separates a dead run's files from the current session's. Pure.
func orphanSegmentStems(names: [String], modified: (String) -> Date?, now: Date,
                        minAgeSeconds: TimeInterval = 120) -> [String] {
    var old = Set<String>(), fresh = Set<String>()
    for n in names where n.hasSuffix(".mic.wav") || n.hasSuffix(".sys.wav") {
        let stem = n.replacingOccurrences(of: ".mic.wav", with: "")
            .replacingOccurrences(of: ".sys.wav", with: "")
        guard orphanSegmentStart(stem) != nil else { continue }
        if let m = modified(n), now.timeIntervalSince(m) >= minAgeSeconds {
            old.insert(stem)
        } else {
            fresh.insert(stem)
        }
    }
    return old.subtracting(fresh).sorted()
}

/// Re-derive a finished track's stats by STREAMING it through a real SourceWriter (writing to a
/// throwaway scratch file) — identical numbers by construction, no third copy of the envelope
/// rules to drift. Returns nil when the file can't be read.
func scanWavStats(_ url: URL, scratchDir: URL) -> (voiced: Double, speech: Double, peak: Float, duration: Double)? {
    guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
    let scratch = scratchDir.appendingPathComponent("stat-scan-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: scratch) }
    guard let writer = try? SourceWriter(url: scratch),
          let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1 << 16)
    else { return nil }
    while file.framePosition < file.length {
        guard (try? file.read(into: buf, frameCount: 1 << 16)) != nil, buf.frameLength > 0 else { break }
        writer.append(buf)
    }
    let duration = Double(file.length) / file.processingFormat.sampleRate
    return (writer.voicedSeconds, writer.speechSeconds, writer.peak, duration)
}
