import AVFoundation
import Foundation

// MARK: - scenario QA (tier 1): whole incidents replayed in-process, not unit checks
//
// These drive REAL components end-to-end in a sandbox — virtual clock, injected runner/events, fixture
// audio — because the incidents they guard lived in the WIRING (tick loops, pipeline plumbing), where
// every pure function was already correct and already unit-tested. Each scenario names the incident it
// replays and asserts the exact values from it.

func scenarioSelftests(_ check: (String, Bool) -> Void) {
    let fm = FileManager.default

    func date(_ s: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.timeZone = Calendar.current.timeZone
        return f.date(from: s)!
    }

    // ---- S-STORM — the digest retry storm (453 spawns + 453 notifications in one afternoon) ----
    // Replays the evening of the incident against the real DigestCoordinator tick at the real 30 s
    // cadence, with a virtual clock and an always-failing runner. Pre-backoff wiring spawns ~360 times
    // by 23:00 and notifies every time; the fixed wiring spawns 5 times and notifies once.
    do {
        let scratch = fm.temporaryDirectory.appendingPathComponent("mr-scenario-\(UUID().uuidString)")
        let month = scratch.appendingPathComponent("2026-07", isDirectory: true)
        try? fm.createDirectory(at: month, withIntermediateDirectories: true)
        // One mock meeting note for the day, so the digest actually launches its runner.
        try? "project kickoff notes".write(to: month.appendingPathComponent("2026-07-14-1000.md"),
                                           atomically: true, encoding: .utf8)
        Pref.d.set(true, forKey: Pref.dailyDigest)
        Pref.d.set("20:00", forKey: Pref.dailyDigestTime)
        Pref.d.set(scratch.path, forKey: Pref.txtDir)
        Pref.d.set("", forKey: Pref.summaryOut)
        Pref.d.removeObject(forKey: Pref.dailyDigestLastRun)
        var notifications = 0
        Notifier.sinkForTest = { _, _ in notifications += 1 }
        SummaryStatus.shared.resetForTest()

        let coord = DigestCoordinator()
        var clock = date("2026-07-14 19:59:30")
        coord.now = { clock }
        coord.run = { _, done in done(1) }   // the incident: `claude` exiting 1 ("Not logged in")
        while clock < date("2026-07-14 23:00:00") {   // 20:00 → 23:00 at the real tick cadence
            clock = clock.addingTimeInterval(30)
            coord.tick()
        }
        let stormSpawns = coord.spawnCount, stormNotifies = notifications
        let dayNotRetired = Pref.d.string(forKey: Pref.dailyDigestLastRun) == nil
        check("scenario S-STORM: a failing digest backs off (5 spawns by 23:00, not ~360) and notifies once",
              stormSpawns == 5 && stormNotifies == 1 && dayNotRetired)

        coord.run = { _, done in done(0) }   // the login gets fixed later that evening
        while clock < date("2026-07-14 23:45:00") {
            clock = clock.addingTimeInterval(30)
            coord.tick()
        }
        check("scenario S-STORM: after the fix, the NEXT backoff attempt succeeds and retires the day",
              coord.spawnCount == 6 && Pref.d.string(forKey: Pref.dailyDigestLastRun) == "2026-07-14")

        Notifier.sinkForTest = nil
        SummaryStatus.shared.resetForTest()
        for k in [Pref.dailyDigest, Pref.dailyDigestTime, Pref.txtDir, Pref.summaryOut, Pref.dailyDigestLastRun] {
            Pref.d.removeObject(forKey: k)
        }
        try? fm.removeItem(at: scratch)
    }

    // ---- S-PIPELINE — a fixture WAV through the REAL pipeline, headless ----
    // SourceWriter's real energy-VAD accumulates the stats, convert16 really converts, a stub
    // whisper-cli emits a canned line, writeTranscript writes the real markdown. No hardware, no TCC.
    do {
        let scratch = fm.temporaryDirectory.appendingPathComponent("mr-scenario-\(UUID().uuidString)")
        let tDir = scratch.appendingPathComponent("t"), aDir = scratch.appendingPathComponent("a")
        let wDir = scratch.appendingPathComponent("w")
        for d in [tDir, aDir, wDir] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let stub = scratch.appendingPathComponent("stub-whisper.sh")
        try? "#!/bin/sh\necho \"[00:00:01.000 --> 00:00:04.000] 안녕하세요\"\n".write(to: stub, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let model = scratch.appendingPathComponent("model.bin")
        fm.createFile(atPath: model.path, contents: Data([0]))

        func cfg(model: String, calendarTitles: Bool) -> EngineConfig {
            EngineConfig(segmentSeconds: 3600, voiceMinSeconds: 5,
                         transcriptsDir: tDir, audioDir: aDir, workDir: wDir,
                         whisperCli: stub.path, whisperModel: model, vadModel: "", vadEnabled: false,
                         useCalendarTitles: calendarTitles, whisperLang: "ko", keepAudio: false,
                         audioRawDays: 0, audioRetentionDays: 0, transcriptRetentionDays: 0,
                         excludeBundleIds: [])
        }
        // Speech-shaped fixture: 0.3-amplitude sine bursts (400 ms on / 100 ms off — utterance-length,
        // so the envelope speech detector sees them) through the REAL SourceWriter VAD; the sys side
        // stays silent. Stats come from the writers, not hand-picked. reps × 500 ms of audio.
        func writeFixtureWAVs(voiced: Bool, reps: Int = 20) -> (mic: URL, sys: URL, micVoiced: Double, micSpeech: Double, micPeak: Float)? {
            let micURL = wDir.appendingPathComponent("fix-\(UUID().uuidString).mic.wav")
            let sysURL = wDir.appendingPathComponent("fix-\(UUID().uuidString).sys.wav")
            guard let micW = try? SourceWriter(url: micURL), let sysW = try? SourceWriter(url: sysURL),
                  let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
                  let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 8000) else { return nil }
            buf.frameLength = 8000   // 500 ms: 400 ms burst + 100 ms silence
            for rep in 0..<reps {
                for i in 0..<8000 {
                    let inBurst = i < 6400
                    buf.floatChannelData![0][i] = (voiced && inBurst) ? sinf(Float(rep * 8000 + i) * 0.13) * 0.3 : 0
                }
                micW.append(buf)
                for i in 0..<8000 { buf.floatChannelData![0][i] = 0 }
                sysW.append(buf)
            }
            return (micURL, sysURL, micW.voicedSeconds, micW.speechSeconds, micW.peak)
        }
        func segment(_ fix: (mic: URL, sys: URL, micVoiced: Double, micSpeech: Double, micPeak: Float),
                     start: Date) -> CompletedSegment {
            CompletedSegment(start: start, sysURL: fix.sys, micURL: fix.mic,
                             micVoicedSeconds: fix.micVoiced, sysVoicedSeconds: 0,
                             micSpeechSeconds: fix.micSpeech, sysSpeechSeconds: 0,
                             sysPeak: 0, micPeak: fix.micPeak, durationSeconds: 3600)
        }
        Notifier.sinkForTest = { _, _ in }
        var results: [String] = []
        let start = date("2026-03-01 10:00:00")

        // Base: voiced fixture → a real transcript lands at the start-only name with the ko labels.
        if let fix = writeFixtureWAVs(voiced: true) {
            let engine = RecordingEngine(cfg: cfg(model: model.path, calendarTitles: false))
            engine.onSegmentResult = { results.append($0) }
            engine.process(segment(fix, start: start))
            let out = tDir.appendingPathComponent("2026-03/2026-03-01-1000.md")
            let body = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
            check("scenario S-PIPELINE: fixture WAV → real VAD stats → stub whisper → transcript on disk",
                  fix.micVoiced > 5 && body.contains("안녕하세요") && body.contains("나"))
        } else {
            check("scenario S-PIPELINE: fixture WAV setup", false)
        }
        // (a) model missing → deferred, no file.
        if let fix = writeFixtureWAVs(voiced: true) {
            results = []
            let engine = RecordingEngine(cfg: cfg(model: scratch.appendingPathComponent("absent.bin").path,
                                                  calendarTitles: false))
            engine.onSegmentResult = { results.append($0) }
            engine.process(segment(fix, start: date("2026-03-01 11:00:00")))
            check("scenario S-PIPELINE(a): missing model defers transcription instead of failing silently",
                  results.contains { $0.contains("Downloading model") }
                  && !fm.fileExists(atPath: tDir.appendingPathComponent("2026-03/2026-03-01-1100.md").path))
        }
        // (b) silence → below the minimum-speech gate, skipped, no file.
        if let fix = writeFixtureWAVs(voiced: false) {
            results = []
            let engine = RecordingEngine(cfg: cfg(model: model.path, calendarTitles: false))
            engine.onSegmentResult = { results.append($0) }
            engine.process(segment(fix, start: date("2026-03-01 12:00:00")))
            check("scenario S-PIPELINE(b): a silent segment is skipped by the minimum-speech gate",
                  results.contains { $0.contains("No speech") }
                  && !fm.fileExists(atPath: tDir.appendingPathComponent("2026-03/2026-03-01-1200.md").path))
        }
        // (c) titling through the real path: a 2-minute blip fails the overlap floor; the meeting that
        // fills the segment titles the file (the wrong-calendar incident's decision, exercised end-to-end).
        if let fix = writeFixtureWAVs(voiced: true) {
            let segStart = date("2026-03-01 13:00:00")
            CalendarLookup.eventsOverrideForTest = [
                EventCandidate(title: "coffee break", start: date("2026-03-01 13:58:00"),
                               end: date("2026-03-01 14:30:00"), hasLink: false),   // padding blip — must lose
                EventCandidate(title: "project kickoff", start: segStart,
                               end: date("2026-03-01 14:00:00"), hasLink: true),
            ]
            let engine = RecordingEngine(cfg: cfg(model: model.path, calendarTitles: true))
            engine.process(segment(fix, start: segStart))
            CalendarLookup.eventsOverrideForTest = nil
            let out = tDir.appendingPathComponent("2026-03/2026-03-01-1300-project-kickoff.md")
            check("scenario S-PIPELINE(c): the meeting that fills the segment titles it; a blip cannot",
                  fm.fileExists(atPath: out.path))
        }
        // (d) MANUAL flush: the user's explicit "Transcribe now" bypasses BOTH hygiene gates — a silent,
        // meeting-less segment still reaches whisper, which gets the final word (a real manual flush was
        // once discarded by the no-meeting rule; user P1).
        if let fix = writeFixtureWAVs(voiced: false) {
            CalendarLookup.eventsOverrideForTest = []   // no meeting either — the auto path would drop this twice
            let engine = RecordingEngine(cfg: cfg(model: model.path, calendarTitles: true))
            engine.process(segment(fix, start: date("2026-03-01 15:00:00")), manual: true)
            CalendarLookup.eventsOverrideForTest = nil
            check("scenario S-PIPELINE(d): a manual Transcribe-now bypasses the hygiene gates",
                  fm.fileExists(atPath: tDir.appendingPathComponent("2026-03/2026-03-01-1500.md").path))
        }
        // (e) THE lost-call incident, auto path: an uncalendared segment with ~16 s of real oscillating
        // speech must be KEPT by the no-meeting gate — no manual bypass. The old per-sample speech-run
        // metric scored ALL real audio 0 s (a sine crosses the threshold every half-cycle, so a 50 ms
        // sample run is physically impossible) and every uncalendared call was silently discarded, even
        // after the bar dropped 180 s → 15 s. The stats here come from the REAL SourceWriter.
        if let fix = writeFixtureWAVs(voiced: true, reps: 50) {   // 25 s: 20 s of bursts → ~20 s speech-run
            CalendarLookup.eventsOverrideForTest = []   // no meeting overlaps the segment
            let engine = RecordingEngine(cfg: cfg(model: model.path, calendarTitles: true))
            engine.process(segment(fix, start: date("2026-03-01 16:00:00")))
            CalendarLookup.eventsOverrideForTest = nil
            let out = tDir.appendingPathComponent("2026-03/2026-03-01-1600.md")
            let body = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
            // ≥18 s: the fixture really measures ~20.6 s — a bound near the 15 s gate would let an
            // accounting regression that undercounts by a quarter slip through green.
            check("scenario S-PIPELINE(e): an uncalendared call with real speech is kept by the auto path",
                  fix.micSpeech >= 18 && body.contains("안녕하세요"))
        }
        // (f) dropped-metric: two LIVE zero-mic segments fire ONE push + the day-keyed verdict; a
        // voiced run never does. Eligibility corners (suspended/manual/adopted) are unit-pinned.
        do {
            var pushes = 0
            Notifier.sinkForTest = { t, _ in if t.contains("recording silence") { pushes += 1 } }
            var voicedResults: [String] = []
            if let fix = writeFixtureWAVs(voiced: true) {
                let e = RecordingEngine(cfg: cfg(model: model.path, calendarTitles: false))
                e.micGrantedProbe = { true }
                e.onSegmentResult = { voicedResults.append($0) }
                e.process(segment(fix, start: date("2026-03-01 17:00:00")))
            }
            let e2 = RecordingEngine(cfg: cfg(model: model.path, calendarTitles: false))
            e2.micGrantedProbe = { true }
            var silentResults: [String] = []
            e2.onSegmentResult = { silentResults.append($0) }
            for h in ["18", "19"] {
                if let fix = writeFixtureWAVs(voiced: false) {
                    e2.process(segment(fix, start: date("2026-03-01 \(h):00:00")))
                }
            }
            check("scenario S-PIPELINE(f): a zero-mic run is surfaced once (dropped-metric); a voiced run is not",
                  pushes == 1 && silentResults.contains { $0.contains("Capturing silence") }
                      && CaptureSilence.detectedToday()
                      && !voicedResults.contains { $0.contains("Capturing silence") })
        }
        Notifier.sinkForTest = nil
        try? fm.removeItem(at: scratch)
    }

    // ---- S-ADOPT — a dead run's segment files get their turn on the next start ----
    // The restart-eats-the-partial incident: the files survive the process, the in-memory stats
    // don't. Adoption re-derives them from the files and pushes a NORMAL segment through the
    // NORMAL gates. First run must sweep the pre-existing backlog aside, not re-transcribe it.
    do {
        let scratch = fm.temporaryDirectory.appendingPathComponent("mr-adopt-\(UUID().uuidString)")
        let tDir = scratch.appendingPathComponent("t"), aDir = scratch.appendingPathComponent("a")
        let wDir = scratch.appendingPathComponent("w")
        for d in [tDir, aDir, wDir] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let stub = scratch.appendingPathComponent("stub-whisper.sh")
        try? "#!/bin/sh\necho \"[00:00:01.000 --> 00:00:04.000] 입양된 세그먼트\"\n".write(to: stub, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let model = scratch.appendingPathComponent("model.bin")
        fm.createFile(atPath: model.path, contents: Data([0]))
        let cfg = EngineConfig(segmentSeconds: 3600, voiceMinSeconds: 5,
                               transcriptsDir: tDir, audioDir: aDir, workDir: wDir,
                               whisperCli: stub.path, whisperModel: model.path, vadModel: "", vadEnabled: false,
                               useCalendarTitles: false, whisperLang: "ko", keepAudio: false,
                               audioRawDays: 0, audioRetentionDays: 0, transcriptRetentionDays: 0,
                               excludeBundleIds: [])
        func writeOrphanPair(_ stem: String, voiced: Bool, ageSeconds: TimeInterval) {
            guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
                  let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 8000) else { return }
            for suffix in ["mic", "sys"] {
                let url = wDir.appendingPathComponent("\(stem).\(suffix).wav")
                do {   // narrow scope: the writer's deinit FLUSHES the file (touching its mtime),
                    // so it must run BEFORE the backdating below or the file looks fresh.
                    guard let w = try? SourceWriter(url: url) else { continue }
                    buf.frameLength = 8000
                    for rep in 0..<24 {   // 12 s — clears the adopter's 10 s floor
                        for i in 0..<8000 {
                            let on = voiced && suffix == "mic" && i < 6400
                            buf.floatChannelData![0][i] = on ? sinf(Float(rep * 8000 + i) * 0.13) * 0.3 : 0
                        }
                        w.append(buf)
                    }
                }
                try? fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -ageSeconds)],
                                      ofItemAtPath: url.path)
            }
        }
        let engine = RecordingEngine(cfg: cfg)
        // (a) first run: the backlog sweeps to processed/, nothing is transcribed.
        writeOrphanPair("seg-2026-03-05-100000", voiced: true, ageSeconds: 600)
        engine.adoptOrphanSegments()
        engine.drainProcessQueueForTest()
        check("scenario S-ADOPT(a): first run sweeps the backlog aside instead of re-transcribing it",
              fm.fileExists(atPath: wDir.appendingPathComponent("processed/seg-2026-03-05-100000.mic.wav").path)
                  && !fm.fileExists(atPath: tDir.appendingPathComponent("2026-03/2026-03-05-1000.md").path))
        // (b) a NEW orphan (dead run's partial) is adopted → transcript through the normal gates.
        writeOrphanPair("seg-2026-03-05-110000", voiced: true, ageSeconds: 300)
        engine.adoptOrphanSegments()
        engine.drainProcessQueueForTest()
        let adopted = tDir.appendingPathComponent("2026-03/2026-03-05-1100.md")
        check("scenario S-ADOPT(b): an orphaned voiced segment becomes a transcript on the next start",
              fm.fileExists(atPath: adopted.path)
                  && ((try? String(contentsOf: adopted, encoding: .utf8)) ?? "").contains("입양된 세그먼트")
                  && !fm.fileExists(atPath: wDir.appendingPathComponent("seg-2026-03-05-110000.mic.wav").path))
        // (c) FRESH files (a live writer is flushing them) are never touched.
        writeOrphanPair("seg-2026-03-05-120000", voiced: true, ageSeconds: 0)
        engine.adoptOrphanSegments()
        engine.drainProcessQueueForTest()
        check("scenario S-ADOPT(c): fresh files stay untouched; adoption is idempotent",
              fm.fileExists(atPath: wDir.appendingPathComponent("seg-2026-03-05-120000.mic.wav").path)
                  && !fm.fileExists(atPath: tDir.appendingPathComponent("2026-03/2026-03-05-1200.md").path))
        try? fm.removeItem(at: scratch)
    }
}
