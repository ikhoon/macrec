import AppKit
import AVFoundation
import Compression
import EventKit
import Foundation

// MARK: - recording engine (continuous, hourly rotation, mic-gated transcription)

/// The recording engine: rotates capture into segments, transcribes voiced ones, runs retention sweeps.
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
