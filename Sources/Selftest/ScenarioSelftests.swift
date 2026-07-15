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
        // Speech-shaped fixture: 10 s of 0.3-amplitude sine bursts (200 ms on / 100 ms off) through the
        // REAL SourceWriter VAD; the sys side stays silent. Stats come from the writers, not hand-picked.
        func writeFixtureWAVs(voiced: Bool) -> (mic: URL, sys: URL, micVoiced: Double, micSpeech: Double, micPeak: Float)? {
            let micURL = wDir.appendingPathComponent("fix-\(UUID().uuidString).mic.wav")
            let sysURL = wDir.appendingPathComponent("fix-\(UUID().uuidString).sys.wav")
            guard let micW = try? SourceWriter(url: micURL), let sysW = try? SourceWriter(url: sysURL),
                  let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
                  let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4800) else { return nil }
            buf.frameLength = 4800   // 300 ms: 200 ms burst + 100 ms silence
            for rep in 0..<33 {      // ~10 s
                for i in 0..<4800 {
                    let inBurst = i < 3200
                    buf.floatChannelData![0][i] = (voiced && inBurst) ? sinf(Float(rep * 4800 + i) * 0.13) * 0.3 : 0
                }
                micW.append(buf)
                for i in 0..<4800 { buf.floatChannelData![0][i] = 0 }
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
        Notifier.sinkForTest = nil
        try? fm.removeItem(at: scratch)
    }
}
