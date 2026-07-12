// The transcript pipeline: which calendar event a segment belongs to, whisper-cli transcription,
// the continuous recording engine, the audio archive tiers, the schedule, and the post-process
// hook that turns a transcript into a summary and a daily digest.

import AppKit   // availableCalendars() returns NSColor; a UI concern that lives here for now
import AVFoundation
import Compression   // zlib ratio — the whisper repetition-loop detector
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

// MARK: - transcriber (per-track whisper-cli → speaker-labeled, time-merged transcript)

enum Transcriber {
    /// Run whisper-cli (VAD + suppress-non-speech) on a 16kHz/16-bit WAV; return its timestamped stdout.
    private static func runWhisper(_ wav16: URL, _ cfg: EngineConfig, hints: String = "") -> String {
        guard FileManager.default.isExecutableFile(atPath: cfg.whisperCli),
              FileManager.default.fileExists(atPath: cfg.whisperModel) else {
            elog("transcribe: whisper-cli or model missing (\(cfg.whisperCli))"); return ""
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cfg.whisperCli)
        var args = ["-m", cfg.whisperModel, "-f", wav16.path, "-l", cfg.whisperLang, "-np", "-sns",
                    // Anti-hallucination (whisper.cpp #2286, openai/whisper #679): killing the
                    // rolling text context stops a degenerate window from feeding the NEXT window's
                    // prompt — the self-reinforcing repetition loop that junked whole hours of
                    // broadcast/BGM audio. Raised entropy/logprob thresholds make the decoder retry
                    // at higher temperature instead of accepting low-entropy loop output; the
                    // temperature fallback itself stays ON — it is the escape hatch.
                    "--entropy-thold", "2.6", "--logprob-thold", "-1.25"]
        if hints.isEmpty {
            args += ["--max-context", "0"]
        } else {
            // whisper-cli gates ALL prompt injection on max-context > 0, so a flat 0 would silently
            // kill the hints. Instead: carry the hints into EVERY window (an upgrade — previously
            // they only biased the first ~30s) and size max-context to roughly the hint tokens, so
            // the rolling-context budget left over for loop-feeding stays ~0.
            let hintTokens = min(224, max(16, hints.utf8.count / 3))
            args += ["--carry-initial-prompt", "--max-context", String(hintTokens)]
        }
        if cfg.vadEnabled && FileManager.default.fileExists(atPath: cfg.vadModel) {
            // Tightened VAD: the default threshold (0.5) passed sung vocals into the decoder and
            // one-burst noises (a cough) transcribed to a word. Longer min-durations drop those;
            // generous padding keeps soft sentence tails.
            args += ["--vad", "--vad-model", cfg.vadModel,
                     "--vad-threshold", "0.55",
                     "--vad-min-speech-duration-ms", "300",
                     "--vad-min-silence-duration-ms", "300",
                     "--vad-speech-pad-ms", "150"]
        }
        if !hints.isEmpty { args += ["--prompt", hints] }   // proper-noun dictionary biases decoding
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { elog("whisper run: \(error)"); return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Parse "[HH:MM:SS.mmm --> ...]  text" lines into (startSeconds, text).
    private static func parse(_ output: String) -> [(Double, String)] {
        var segs: [(Double, String)] = []
        for raw in output.split(separator: "\n") {
            let line = String(raw)
            guard line.hasPrefix("["), let arrow = line.range(of: " --> "), let close = line.range(of: "]") else { continue }
            let ts = line[line.index(after: line.startIndex)..<arrow.lowerBound].split(separator: ":")
            guard ts.count == 3, let h = Double(ts[0]), let m = Double(ts[1]), let s = Double(ts[2]) else { continue }
            let text = line[close.upperBound...].trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { segs.append((h * 3600 + m * 60 + s, text)) }
        }
        return segs
    }

    // MARK: hallucination scrubbing — whisper fabricates fluent text on music/noise/silence
    // (its training data paired non-speech audio with video credits), and a degenerate window can
    // loop one sentence for many minutes. These pure detectors run per TRACK before the merge.

    /// YouTube-outro boilerplate whisper hallucinates on non-speech — seen VERBATIM in our junk
    /// transcripts (ご視聴ありがとうございました on a quiet living-room hour, etc.).
    static let hallucinationBoilerplate = [
        "시청해 주셔서 감사합니다", "시청해주셔서 감사합니다", "구독과 좋아요", "다음 영상에서 만나",
        "thank you for watching", "thanks for watching", "ご視聴ありがとうございました",
    ]

    /// Within-line degeneration: "oh, oh, oh, oh…" compresses absurdly well. Ratio of raw UTF-8
    /// size to compressed size; real sentences land ~1.0–1.5, loops blow past 2.4. Apple's
    /// COMPRESSION_ZLIB emits raw DEFLATE (no 2-byte header/4-byte adler) — the +6 keeps the ratio
    /// calibrated to the zlib-framed implementation the 2.4 threshold comes from (openai/whisper).
    static func compressionRatio(_ s: String) -> Double {
        let src = Array(s.utf8)
        guard src.count > 0 else { return 1 }
        var dst = [UInt8](repeating: 0, count: src.count + 1024)
        let n = compression_encode_buffer(&dst, dst.count, src, src.count, nil, COMPRESSION_ZLIB)
        guard n > 0 else { return 1 }
        return Double(src.count) / Double(n + 6)
    }

    /// Share of the most frequent word 4-gram — a loop shows one 4-gram dominating. Only
    /// meaningful with ≥20 grams (≥23 words); shorter lines return 0.
    static func maxNgramShare(_ s: String, n: Int = 4) -> Double {
        let words = s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count >= n + 19 else { return 0 }
        var counts: [String: Int] = [:]
        for i in 0...(words.count - n) { counts[words[i..<(i + n)].joined(separator: " "), default: 0] += 1 }
        return Double(counts.values.max() ?? 0) / Double(words.count - n + 1)
    }

    static func isHallucinatedLine(_ text: String) -> Bool {
        // Boilerplate must BE the line (± a little punctuation), not merely appear in it — a real
        // sentence that *mentions* a boilerplate phrase (an A/B-test discussion, a demo ending with
        // "thank you for watching the demo…") must survive.
        let t = text.lowercased()
        if hallucinationBoilerplate.contains(where: { t.contains($0.lowercased()) && text.count <= $0.count + 10 }) {
            return true
        }
        // The 80-byte gate keeps short real repetition alive (backchannels, chants) —
        // per-line ratios on tiny strings are noisy, and sub-80-byte junk is cheap collateral.
        if text.utf8.count > 80, compressionRatio(text) > 2.4 { return true }
        // A phrase-loop's max share ≈ 1/period — 0.1 catches periods ≤ 9 words; longer-period
        // loops compress well and are caught by the ratio check above instead.
        if maxNgramShare(text) > 0.1 { return true }
        return false
    }

    /// Drop hallucinated lines and COLLAPSE identical-line runs (the minutes-long loop that
    /// repeats one sentence hundreds of times keeps its first occurrence only). The 30 s gap guard
    /// keeps REAL repeats: two identical backchannels half an hour apart are both kept — loop
    /// lines arrive seconds apart, so every link in the chain stays inside the window.
    static func scrubLines(_ lines: [(Double, String)]) -> (kept: [(Double, String)], dropped: Int) {
        var kept: [(Double, String)] = []
        var dropped = 0
        var prevText = ""
        var prevTime = -1e9
        for l in lines {
            defer { prevText = l.1; prevTime = l.0 }
            if isHallucinatedLine(l.1) { dropped += 1; continue }
            if l.1 == prevText, l.0 - prevTime < 30 { dropped += 1; continue }
            kept.append(l)
        }
        return (kept, dropped)
    }

    /// Convert a float32 WAV to 16kHz/16-bit (what whisper-cli expects). Returns the temp file URL.
    private static func convert16(_ src: URL) -> URL? {
        do {
            let inFile = try AVAudioFile(forReading: src)
            guard inFile.length > 0 else { return nil }
            let outURL = URL(fileURLWithPath: src.deletingPathExtension().path + ".16.wav")
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
            let outFile = try AVAudioFile(forWriting: outURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let block: AVAudioFrameCount = 16000
            while inFile.framePosition < inFile.length {
                guard let buf = AVAudioPCMBuffer(pcmFormat: canon, frameCapacity: block) else { break }
                try inFile.read(into: buf, frameCount: block)
                if buf.frameLength == 0 { break }
                try outFile.write(from: buf)
            }
            return outURL
        } catch { elog("convert16(\(src.lastPathComponent)): \(error)"); return nil }
    }

    /// Transcribe mic ("me") and system ("them") SEPARATELY, then merge by time into a speaker-labeled
    /// transcript. Mixes a kept WAV only when keepAudio. Returns (mixedWav?, text).
    static func transcribe(_ seg: CompletedSegment, cfg: EngineConfig) -> (mixed: URL?, text: String)? {
        var mixed: URL? = nil
        if cfg.keepAudio {
            let stem = URL(fileURLWithPath: seg.sysURL.path).deletingPathExtension().deletingPathExtension()
            let m = URL(fileURLWithPath: stem.path + ".wav")
            do { try mixDown(sysURL: seg.sysURL, micURL: seg.micURL, outURL: m); mixed = m }
            catch { elog("mixdown: \(error)") }
        }
        // Speaker labels follow the transcription language (auto → the system language).
        let lang = cfg.whisperLang == "auto" ? Locale.current.language.languageCode?.identifier : cfg.whisperLang
        let (mine, theirs) = speakerLabels(forLanguage: lang)
        let hints = transcriptionHints(start: seg.start, end: seg.start.addingTimeInterval(seg.durationSeconds))
        if !hints.isEmpty { elog("transcribe: hints (\(hints.split(separator: ",").count) terms)") }
        var merged: [(start: Double, who: String, text: String)] = []
        var scrubbed = 0
        if let mic16 = convert16(seg.micURL) {
            let (kept, dropped) = scrubLines(parse(runWhisper(mic16, cfg, hints: hints)))
            merged += kept.map { (start: $0.0, who: mine, text: $0.1) }
            scrubbed += dropped
            try? FileManager.default.removeItem(at: mic16)
        }
        if let sys16 = convert16(seg.sysURL) {
            let (kept, dropped) = scrubLines(parse(runWhisper(sys16, cfg, hints: hints)))
            merged += kept.map { (start: $0.0, who: theirs, text: $0.1) }
            scrubbed += dropped
            try? FileManager.default.removeItem(at: sys16)
        }
        if scrubbed > 0 { elog("transcribe: scrubbed \(scrubbed) hallucinated/looping lines") }
        merged.sort { $0.start < $1.start }
        // Belt to the AEC's braces: the residual the canceller leaves still transcribes — drop mic
        // lines that are (garbled) copies of a nearby far-end line (see suppressEchoLines).
        if EchoCanceller.shared.enabled {
            let before = merged.count
            merged = suppressEchoLines(merged, mine: mine)
            if merged.count != before { elog("transcribe: suppressed \(before - merged.count) echo line(s)") }
        }
        let tf = DateFormatter(); tf.locale = Locale(identifier: "en_US_POSIX"); tf.dateFormat = "HH:mm:ss"
        let text = merged.map { "[\(tf.string(from: seg.start.addingTimeInterval($0.start)))] \($0.who): \($0.text)" }
            .joined(separator: "\n")
        return (mixed, text)
    }
}

// MARK: - recording engine (continuous, hourly rotation, mic-gated transcription)

final class RecordingEngine {
    let cfg: EngineConfig
    let session: CaptureSession
    private let timerQueue = DispatchQueue(label: "macrec.timer")
    private let processQueue = DispatchQueue(label: "macrec.process")  // serial: transcribe one at a time
    private var timer: DispatchSourceTimer?
    private(set) var running = false
    private var recovering = false
    private var suspended = false   // true while the display/system is asleep
    private var exclusionRefresh: DispatchWorkItem?   // debounces the app-launch exclusion re-scan
    private var warnedDeadMic = false            // one dead-mic push per engine run (not per hour)
    var onTranscriptSaved: ((String) -> Void)?   // (message) — for refreshing UI state
    var onTranscriptURL: ((URL) -> Void)?        // path of the saved transcript file — notification click → open file
    var onSegmentResult: ((String) -> Void)?      // (message) — notify even when dropped for no speech

    init(cfg: EngineConfig) {
        self.cfg = cfg
        self.session = CaptureSession(excludeBundleIds: cfg.excludeBundleIds, workDir: cfg.workDir)
    }

    /// Cut what's recorded so far and transcribe/save it immediately, without waiting for the on-the-hour rotation (tray "Transcribe now").
    func flushNow() {
        guard running, let seg = session.rotate() else { return }
        processQueue.async { self.process(seg) }
    }

    /// On sleep: stop the system-audio stream so we don't hold the display/audio while it powers down.
    private func suspendForSleep() {
        guard running, !suspended else { return }
        suspended = true
        elog("engine: lock/sleep → suspending capture (mic + system)")
        onSegmentResult?("Paused (locked/asleep)")
        Task { await session.suspendStream() }
    }

    /// On unlock/wake: clear suspension and rebuild the stream.
    private func wake() {
        guard running else { return }
        suspended = false
        elog("engine: unlock/wake → resuming capture")
        onSegmentResult?("Recording · mic + system audio")
        recover()
    }

    /// Current per-source input level (0..1) for the live menu meter — is audio coming in right now?
    func liveLevels() -> (mic: Float, sys: Float) {
        guard running else { return (0, 0) }
        // Writers are swapped/released ON rec.queue at every rotation; reading the refs off-queue
        // races that swap (review finding: the 1 Hz voice poll could catch the old writer's final
        // release → over-release). Snapshot on the queue — its work items are short buffer appends,
        // and nothing on rec.queue ever syncs back to main, so this can't deadlock.
        let rec = session.rec
        return rec.queue.sync { (rec.micWriter?.recentLevel ?? 0, rec.sysWriter?.recentLevel ?? 0) }
    }

    /// Coalesce a burst of launch/quit notifications into one exclusion re-scan.
    private func scheduleExclusionRefresh() {
        exclusionRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running, !self.suspended else { return }
            Task { await self.session.refreshExclusionsIfStale() }
        }
        exclusionRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// A tap created before "System Audio Recording Only" was granted delivers muted (zero) buffers.
    /// Poll the grant for a few minutes; the moment it flips to authorized, rebuild the tap so real
    /// system audio starts flowing — no manual Resume needed after the user clicks Allow.
    func waitForAudioGrantThenRestart() {
        Task { [weak self] in
            for _ in 0..<90 {   // ~3 min
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.running, !self.suspended else { return }
                if audioCaptureAuthorized() {
                    elog("engine: System Audio Recording granted — rebuilding tap to capture audio")
                    _ = await self.session.restartStream()
                    return
                }
            }
        }
    }

    /// Rebuild the capture (tap + mic) if it stopped delivering — e.g. the default output device
    /// changed under the aggregate device. Retries every 2s. Called on wake/unlock.
    func recover() {
        guard running, !suspended, !recovering else { return }
        recovering = true
        Task { [weak self] in
            for attempt in 1...60 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.running else { break }
                if await self.session.restartStream() {
                    elog("engine: capture stream recovered (attempt \(attempt))")
                    break
                }
            }
            self?.recovering = false
        }
    }

    func start() async throws {
        let audioOK = audioCaptureAuthorized()   // preflight == granted
        let micOK = micAuthorized()
        // Fire the consent prompts if anything is missing. From the .app bundle (which carries the
        // NSAudioCaptureUsageDescription), TCCAccessRequest surfaces the "System Audio Recording
        // Only" dialog; AVCaptureDevice surfaces the Microphone one. We do NOT hard-block on an
        // undetermined system-audio grant — we start the tap anyway (silent until granted) and
        // rebuild it the moment the user allows, so capture just begins with no manual restart.
        if !audioOK || !micOK {
            elog("engine: requesting permissions (system-audio granted=\(audioOK), mic=\(micOK))")
            _ = requestPermissions()
        }
        try await session.start()
        running = true
        elog("engine: recording (segment=\(Int(cfg.segmentSeconds))s, voiceMin=\(Int(cfg.voiceMinSeconds))s, exclude=\(cfg.excludeBundleIds.joined(separator: ",")))")
        if !audioOK { waitForAudioGrantThenRestart() }   // rebuild the muted tap once the user allows
        processQueue.async { [weak self] in self?.cleanupRetention() }   // tidy old files on start
        // Sleep/wake: stop capture cleanly on sleep and resume on wake.
        let wc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.suspendForSleep() }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.wake() }
        }
        // An excluded app launching (or relaunching with a new pid) after the tap was built is NOT
        // excluded by it — the tap froze a set of process object IDs. Re-scan on launch/quit and rebuild
        // only when the set actually drifted. Debounced: an app's helper processes appear in a burst.
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleExclusionRefresh()
            }
        }
        // Screen lock/unlock (distributed notifications) — pause while locked, too.
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.suspendForSleep() }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.wake() }
        // Clock alignment: snap the first rotation to a clock boundary (top of the hour, or a multiple of the segment size).
        // E.g. segment=3600 → next :00; 900 → next :00/:15/:30/:45.
        let cal = Calendar.current; let nowD = Date()
        let intoHour = Double(cal.component(.minute, from: nowD) * 60 + cal.component(.second, from: nowD))
        let firstDelay = cfg.segmentSeconds - intoHour.truncatingRemainder(dividingBy: cfg.segmentSeconds)
        elog("engine: first rotation in \(Int(firstDelay))s (clock-aligned), then every \(Int(cfg.segmentSeconds))s")
        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        t.schedule(deadline: .now() + firstDelay, repeating: cfg.segmentSeconds)
        t.setEventHandler { [weak self] in
            guard let self = self, let seg = self.session.rotate() else { return }
            self.processQueue.async { self.process(seg); self.cleanupRetention() }
        }
        t.resume()
        timer = t
    }

    /// Finalize the current segment and stop the stream (called on shutdown). The trailing partial
    /// segment is discarded (not transcribed) to keep shutdown fast.
    func stop() async {
        running = false   // set first so the stream-stopped event during shutdown doesn't trigger recover()
        timer?.cancel(); timer = nil
        let seg = await session.stop()
        if let seg = seg {
            try? FileManager.default.removeItem(at: seg.sysURL)
            try? FileManager.default.removeItem(at: seg.micURL)
        }
        elog("engine: stopped (trailing partial segment discarded)")
    }

    /// CLI `sweep` entry — one retention/archive pass, synchronously.
    func runRetentionSweep() { cleanupRetention() }

    /// Age audio through the archive tiers (raw WAV → AAC → deleted) and drop expired transcripts.
    /// Recurses under each root so the monthly subfolders are covered too (transcripts/YYYY-MM/*.md,
    /// audioDir/YYYY-MM/*.{wav,m4a} plus any legacy layout). Runs on processQueue.
    private func cleanupRetention() {
        let fm = FileManager.default
        func ageDays(_ u: URL) -> Double? {
            guard let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { return nil }
            return Date().timeIntervalSince(m) / 86400
        }
        if cfg.transcriptRetentionDays > 0,
           let en = fm.enumerator(at: cfg.transcriptsDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            var n = 0
            for case let u as URL in en where u.pathExtension.lowercased() == "md" {
                if let a = ageDays(u), a >= Double(cfg.transcriptRetentionDays) { try? fm.removeItem(at: u); n += 1 }
            }
            if n > 0 { elog("engine: retention — deleted \(n) md file(s) (>\(cfg.transcriptRetentionDays)d)") }
        }
        let policy = AudioArchivePolicy(rawDays: cfg.audioRawDays, totalDays: cfg.audioRetentionDays)
        guard let en = fm.enumerator(at: cfg.audioDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        var deleted = 0, archived = 0
        var budget = 12   // bound conversions per sweep (~1 s each) — transcription shares this queue
        for case let u as URL in en {
            let ext = u.pathExtension.lowercased()
            if u.lastPathComponent.contains(".partial-"), let a = ageDays(u), a > 1 {
                try? fm.removeItem(at: u); continue   // temp left by a killed sweep
            }
            guard ext == "wav" || ext == "m4a", let a = ageDays(u) else { continue }
            switch policy.tier(ageDays: a) {
            case .deleted:
                try? fm.removeItem(at: u); deleted += 1
            case .compressed where ext == "wav" && budget > 0:
                budget -= 1   // count ATTEMPTS — a batch of corrupt WAVs must not afconvert forever
                let out = u.deletingPathExtension().appendingPathExtension("m4a")
                if AudioArchiver.compress(u, to: out) {
                    relinkTranscriptAudio(from: u)
                    try? fm.removeItem(at: u)
                    archived += 1
                }
            default: break
            }
        }
        if deleted > 0 || archived > 0 {
            elog("engine: retention — deleted \(deleted) audio file(s), AAC-compressed \(archived) (raw>\(cfg.audioRawDays)d)")
        }
    }

    /// After archiving audio/YYYY-MM/<slug>.wav → .m4a, point the matching transcript's audio link
    /// at the new file. The transcript shares the slug: transcripts/YYYY-MM/<slug>.md.
    private func relinkTranscriptAudio(from wav: URL) {
        let slug = wav.deletingPathExtension().lastPathComponent
        let month = wav.deletingLastPathComponent().lastPathComponent
        let md = cfg.transcriptsDir.appendingPathComponent(month).appendingPathComponent("\(slug).md")
        guard let text = try? String(contentsOf: md, encoding: .utf8), text.contains("\(slug).wav") else { return }
        let mdate = (try? md.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        try? text.replacingOccurrences(of: "\(slug).wav", with: "\(slug).m4a")
            .write(to: md, atomically: true, encoding: .utf8)
        // The rewrite must not reset the transcript's own retention clock.
        if let mdate { try? FileManager.default.setAttributes([.modificationDate: mdate], ofItemAtPath: md.path) }
    }

    private func process(_ seg: CompletedSegment) {
        elog("engine: segment \(segFormatter().string(from: seg.start)) — voiced mic=\(String(format: "%.1f", seg.micVoicedSeconds))s sys=\(String(format: "%.1f", seg.sysVoicedSeconds))s (micPeak=\(String(format: "%.3f", seg.micPeak)) sysPeak=\(String(format: "%.3f", seg.sysPeak))) dur=\(Int(seg.durationSeconds))s")
        // Dead/misrouted input detector: the ENERGY gate says the mic was active, but nothing held
        // above the threshold for speech-length runs — clicks/hum, not a voice. Surface it instead
        // of silently discarding "no speech" segments for hours (the jack-input incident).
        if micLooksDead(voiced: seg.micVoicedSeconds, speech: seg.micSpeechSeconds) {
            elog("engine: MIC WARNING — energy without speech-length runs; input device may be dead/misrouted")
            onSegmentResult?("Mic looks dead — check the input device (Sound → Input)")
            if !warnedDeadMic {
                warnedDeadMic = true
                Notifier.push(title: "macrec can't hear a voice",
                              body: "The mic records energy but nothing speech-like. Check System Settings → Sound → Input.")
            }
        }
        // debugKeepTrackAudio: keep the PER-TRACK mic/sys wavs (normally deleted after the mix) in
        // workDir — transcription-quality A/B work (echo-dedup validation against real meetings)
        // needs the separated tracks, and the mixed wav can't be un-mixed. Off by default; workDir
        // lives under /tmp, so leftovers vanish on reboot regardless.
        let keepTracks = Pref.bool("debugKeepTrackAudio", "MR_DEBUG_KEEP_TRACKS", false)
        defer {
            if !keepTracks {
                try? FileManager.default.removeItem(at: seg.sysURL)
                try? FileManager.default.removeItem(at: seg.micURL)
            }
        }

        // Transcribe if anyone spoke — my mic or the other side (system) — including listen-only meetings.
        guard seg.voicedSeconds >= cfg.voiceMinSeconds else {
            elog("engine:   → no speech (\(String(format: "%.1f", seg.voicedSeconds))s < \(Int(cfg.voiceMinSeconds))s), discarding")
            onSegmentResult?("No speech — skipped")
            return
        }
        // Short-blip filter (user rule): when calendar titling is on, a segment with NO overlapping
        // meeting and under 3 min of speech isn't worth a file — meetings are always kept. Gate BEFORE
        // transcription so throwaway blips never reach whisper. (Only when titling is on: without a
        // calendar we can't tell "no meeting" from "a meeting we couldn't see", so we don't discard.)
        // ONE calendar query per segment: whisper runs for minutes between the gate and the write, and
        // two queries can return different answers.
        let meeting = cfg.useCalendarTitles
            ? CalendarLookup.match(start: seg.start, end: seg.start.addingTimeInterval(seg.durationSeconds))
            : nil
        if cfg.useCalendarTitles {
            guard shouldKeepTranscript(hasMeeting: meeting != nil, speechSeconds: seg.speechSeconds) else {
                elog("engine:   → no meeting & speech \(String(format: "%.0f", seg.speechSeconds))s < 180s — discarding")
                onSegmentResult?("No meeting · short — skipped")
                return
            }
        }
        // Model not downloaded yet (first run) — defer rather than write a "transcription failed" file.
        guard FileManager.default.fileExists(atPath: cfg.whisperModel) else {
            elog("engine:   → model not ready (\(cfg.whisperModel)) — deferring transcription")
            onSegmentResult?("Downloading model — transcription deferred")
            return
        }
        onSegmentResult?("Transcribing…")
        guard let (mixed, text) = Transcriber.transcribe(seg, cfg: cfg) else {
            onSegmentResult?("Transcription failed")   // a waiting "Transcribe now" push must not dangle
            return
        }
        // A segment can pass the energy gate (keyboard noise, a cough) yet transcribe to NOTHING —
        // those "auto transcript" shells with an empty body were piling up hourly (user report).
        // No transcript lines → no file, and the mixed WAV goes too (nothing to reference it).
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let mixed { try? FileManager.default.removeItem(at: mixed) }
            elog("engine: segment transcribed to nothing — discarded (mic \(String(format: "%.1f", seg.micVoicedSeconds))s, sys \(String(format: "%.1f", seg.sysVoicedSeconds))s)")
            onSegmentResult?("No speech — discarded")
            return
        }
        do {
            let url = try writeTranscript(seg: seg, text: text, mixed: mixed, event: meeting)
            onTranscriptURL?(url)
            onTranscriptSaved?("Saved: \(url.lastPathComponent)")
            if let cmd = postProcessInvocationFromPrefs(transcriptPath: url.path) {
                let file = url.lastPathComponent
                SummaryStatus.shared.started(file)
                let mode = effectivePostProcessMode(rawMode: Pref.explicit(Pref.postProcessMode, "MR_POST_PROCESS_MODE"),
                                                    shellCmd: Pref.postProcessCommand)
                // A shell hook writes nowhere we know, so there is no file to reveal and no partial to reap.
                let out = postProcessWritesSummaryFile(mode)
                    ? summaryOutputPath(transcriptPath: url.path, outDir: Pref.explicit(Pref.summaryOut, "MR_SUMMARY_OUT"))
                    : nil
                runPostProcessCommand(cmd) { status in
                    guard status != 0 else { SummaryStatus.shared.finished(file, at: Date(), output: out); return }
                    let why = out.flatMap { reapFailedPostProcess(outPath: $0) }
                    SummaryStatus.shared.failed(file, at: Date(), reason: why)
                    elog("engine: post-process exited \(status) for \(file)" + (why.map { " — \($0)" } ?? ""))
                    Notifier.push(title: "Summary failed",
                                  body: why ?? "The summary command exited with code \(status) — check Settings › Summaries.")
                }
            }
        } catch { elog("engine: writeTranscript: \(error)") }
    }

    @discardableResult
    private func writeTranscript(seg: CompletedSegment, text: String, mixed: URL?,
                                 event: CalendarLookup.Match?) throws -> URL {
        let fm = FileManager.default
        let dayF = DateFormatter(); dayF.locale = Locale(identifier: "en_US_POSIX"); dayF.dateFormat = "yyyy-MM-dd"
        let hmF = DateFormatter(); hmF.locale = Locale(identifier: "en_US_POSIX"); hmF.dateFormat = "HH:mm"
        let monthF = DateFormatter(); monthF.locale = Locale(identifier: "en_US_POSIX"); monthF.dateFormat = "yyyy-MM"

        let end = seg.start.addingTimeInterval(seg.durationSeconds)

        // The overlapping calendar event, resolved ONCE by the caller (see `process`).
        let l10n = TranscriptL10n.current
        let title = event?.title ?? l10n.autoTitle
        // Stamp the file with the MEETING's start when one maps, else the segment's. Name, month
        // folder and the header's range all derive from this one value so they can never disagree.
        let stamp = transcriptStart(segStart: seg.start, segEnd: end, eventStart: event?.start)
        let mins = max(1, Int((end.timeIntervalSince(stamp) + 30) / 60))
        let base = transcriptBaseName(start: stamp)
        let slug = event.map { "\(base)-\(slugify($0.title))" } ?? base

        // Organize transcripts into monthly subfolders: transcripts/YYYY-MM/…  (audio under YYYY-MM/audio/).
        let monthDir = cfg.transcriptsDir.appendingPathComponent(monthF.string(from: stamp), isDirectory: true)
        try fm.createDirectory(at: monthDir, withIntermediateDirectories: true)

        // keep the mixed WAV per the keepAudio setting (mixed is nil when keepAudio is off)
        var audioLine = "- \(l10n.audio): \(l10n.audioNotKept)"
        if cfg.keepAudio, let mixed = mixed {
            let audioMonthDir = cfg.audioDir.appendingPathComponent(monthF.string(from: stamp), isDirectory: true)
            try fm.createDirectory(at: audioMonthDir, withIntermediateDirectories: true)
            let keptAudio = audioMonthDir.appendingPathComponent("\(slug).wav")
            try? fm.removeItem(at: keptAudio)
            try fm.moveItem(at: mixed, to: keptAudio)
            audioLine = "- \(l10n.audio): [\(slug).wav](\(relativePath(fromDir: monthDir, toFile: keptAudio)))"
        }

        var meta = ""
        if let link = event?.link { meta += "\n- \(l10n.meetingLink): \(link)" }
        if let names = event?.attendees, !names.isEmpty { meta += "\n- \(l10n.attendees): \(names.prefix(12).joined(separator: ", "))" }

        // The body's speaker labels follow the TRANSCRIPTION language (same derivation as Transcriber).
        let bodyLang = cfg.whisperLang == "auto" ? Locale.current.language.languageCode?.identifier : cfg.whisperLang
        let (bodyMine, bodyTheirs) = speakerLabels(forLanguage: bodyLang)
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? l10n.failureNote(model: cfg.whisperModel) : text
        let doc = TranscriptDoc(
            title: title,
            day: dayF.string(from: stamp), hmStart: hmF.string(from: stamp), hmEnd: hmF.string(from: end),
            mins: mins,
            micVoiced: seg.micVoicedSeconds, sysVoiced: seg.sysVoicedSeconds,
            modelName: URL(fileURLWithPath: cfg.whisperModel).lastPathComponent,
            audioLine: audioLine, meta: meta, excludes: cfg.excludeBundleIds.joined(separator: ", "),
            bodyMine: bodyMine, bodyTheirs: bodyTheirs,
            body: body)
        let mdURL = monthDir.appendingPathComponent("\(slug).md")
        try doc.markdown(l10n).write(to: mdURL, atomically: true, encoding: .utf8)
        elog("engine:   → transcript saved: \(mdURL.path)")
        return mdURL
    }
}

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

// MARK: - recording schedule (record only Mon–Fri 10:00–19:00, minus lunch — instead of 24/7)
//
// Days ("mon-fri", "mon,wed,fri") and hour ranges ("10:00-12:00, 13:00-19:00" — the gap between
// ranges IS the lunch exclusion). Outside the window the engine is suspended; a manual Pause/Resume
// overrides the schedule until the next boundary.

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
/// sustained speech-length runs. Real speech always forms >=50 ms runs; electrical clicks and hum
/// from a mic-less input never do. Pure + testable.
func micLooksDead(voiced: Double, speech: Double) -> Bool {
    voiced >= 5 && speech < 0.5
}

/// Reference implementation of the writer's speech-run accounting (samples inside >=minRun
/// contiguous above-threshold runs) — selftests pin the semantics here.
func speechlikeFrames(_ samples: [Float], threshold: Float = 0.02, minRun: Int = 800) -> Int {
    var total = 0, run = 0
    for a in samples.map({ abs($0) }) {
        if a > threshold {
            run += 1
            if run == minRun { total += run } else if run > minRun { total += 1 }
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

// MARK: - transcript-level echo suppression (belt to the AEC's braces)
//
// The acoustic canceller attenuates the speaker→mic echo ~15-26 dB, but live engines still transcribe
// the residual: the far-end shows up again under the MIC speaker as an (often garbled) copy a moment
// later. Acoustic cancellation can't fully win that fight, so we also suppress at the TRANSCRIPT
// level: a mic line whose tokens are largely contained in a recent far-end line is an echo, not the
// user. One-directional (system audio can't contain the user's voice) and length-guarded so genuine
// short replies ("yes", "right") are never eaten.

/// Containment similarity of `a` in `b`: fraction of `a`'s unique tokens present in `b` (echo copies
/// are garbled SUBSETS of the far-end line, so containment beats symmetric Jaccard). Pure + testable.
func echoSimilarity(_ a: String, _ b: String) -> Double {
    func toks(_ s: String) -> Set<String> {
        Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }
    let ta = toks(a), tb = toks(b)
    guard !ta.isEmpty, !tb.isEmpty else { return 0 }
    return Double(ta.intersection(tb).count) / Double(ta.count)
}

/// Is the MIC text most likely the far-end's echo? ≥ 4 tokens (protects genuine short replies) and
/// ≥ 80% of its tokens contained in the far-end line.
func isLikelyEcho(mine: String, theirs: String) -> Bool {
    let tokens = mine.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    return tokens.count >= 4 && echoSimilarity(mine, theirs) >= 0.8
}

/// Drop mic-speaker lines that are echoes of a nearby (±windowSec) far-end line in a merged,
/// time-sorted transcript. Pure + testable — used by the saved-transcript merge.
func suppressEchoLines(_ merged: [(start: Double, who: String, text: String)], mine: String,
                       windowSec: Double = 8) -> [(start: Double, who: String, text: String)] {
    merged.filter { line in
        guard line.who == mine else { return true }
        return !merged.contains { other in
            other.who != mine && abs(other.start - line.start) <= windowSec
                && isLikelyEcho(mine: line.text, theirs: other.text)
        }
    }
}

// MARK: - transcription hints (a proper-noun dictionary biases recognition toward YOUR vocabulary)
//
// whisper's initial prompt (--prompt) steers decoding toward the given tokens — team/product names,
// domain jargon, attendee names stop coming out mangled. Merged from three sources: the Settings terms,
// an external file (git-manageable), and optionally the overlapping calendar event.

/// Split a hints blob into terms: comma- or newline-separated, trimmed. A `#` starts a comment that
/// runs to the END OF THE LINE — commas inside a comment must not resurrect its tail as terms
/// (review finding: "# old, stuff" leaked "stuff" into prompts).
func parseHintTerms(_ text: String) -> [String] {
    text.split(separator: "\n")
        .map { line in line.firstIndex(of: "#").map { String(line[..<$0]) } ?? String(line) }
        .flatMap { $0.split(separator: ",") }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

/// Merge hint sources in priority order, dedupe case-insensitively, cap the count (whisper's prompt
/// window is small — past ~60 terms the tail is ignored anyway). Pure + testable.
func mergeHintTerms(direct: [String], file: [String], event: [String], cap: Int = 60) -> [String] {
    var seen = Set<String>(), out: [String] = []
    for t in direct + file + event where out.count < cap {
        let k = t.lowercased()
        if !seen.contains(k) { seen.insert(k); out.append(t) }
    }
    return out
}

/// Assemble the effective hints prompt for a recording window from prefs (+ calendar when enabled).
func transcriptionHints(start: Date, end: Date) -> String {
    let direct = parseHintTerms(Pref.explicit(Pref.hintsTerms, "MR_HINTS"))
    var file: [String] = []
    let fp = Pref.explicit(Pref.hintsFile, "MR_HINTS_FILE").trimmingCharacters(in: .whitespacesAndNewlines)
    if !fp.isEmpty {
        let path = (fp as NSString).expandingTildeInPath
        if let txt = try? String(contentsOfFile: path, encoding: .utf8) { file = parseHintTerms(txt) }
        else { elog("hints: couldn't read \(path) — skipping the file terms") }
    }
    var event: [String] = []
    if Pref.bool(Pref.hintsCalendar, "MR_HINTS_CALENDAR", false), let e = CalendarLookup.match(start: start, end: end) {
        event = [e.title] + e.attendees
    }
    return mergeHintTerms(direct: direct, file: file, event: event).joined(separator: ", ")
}

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

enum PostProcessMode: String { case off, summary, shell }
enum SummaryRunner: String, CaseIterable { case claude, codex, gemini }

/// The built-in summary prompt — the turn-key default (editable in Settings). Answering in the
/// transcript's own language keeps it correct for mixed ko/en/ja meetings.
let defaultSummaryPrompt = "Summarize this meeting transcript: key points, decisions made, and action items with owners. Answer in the same language as the transcript."

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
    return "mkdir -p \(shq(dir)) && \(runnerCmd) "
         + "> \(shq(outPath + ".partial")) && mv \(shq(outPath + ".partial")) \(shq(outPath))"
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
