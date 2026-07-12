import AppKit
import AVFoundation
import Foundation
import Speech
import Translation

/// whisper.cpp live engine: accumulates fed audio into a 16 kHz mono segment, and every ~2 s re-runs
/// `whisper-cli` on the current segment for a volatile caption line. A lightweight energy gate finalizes
/// the line after ~1 s of silence (or a 12 s cap). Reuses the same whisper-cli + model as the saved
/// transcript. Not on the real-time path — runs on its own queue. Tunables are named constants below.
final class WhisperLiveTranscriber: LiveTranscribing {
    private let label: String
    private let locale: Locale
    private let lang: String                    // whisper -l code (e.g. "ko"; "auto" if unknown)
    private let onUpdate: (String, Bool) -> Void
    private let onLocale: ((Locale) -> Void)?
    private let cfg = EngineConfig.load()
    // Same proper-noun dictionary as the saved transcript; snapshotted on q at start() (the overlay
    // builds engines on the MAIN thread, and transcriptionHints does file IO + an EventKit query —
    // review finding: a slow hints file/calendar froze the whole app). q-confined thereafter.
    private var hints = ""
    private let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let wavURL = FileManager.default.temporaryDirectory.appendingPathComponent("macrec-live-\(UUID().uuidString).wav")
    private let q = DispatchQueue(label: "macrec.whisperlive", qos: .userInitiated)
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var seg: [Float] = []               // current segment samples (16 kHz mono)
    private var startedAt = 0.0                 // systemUptime when the segment began
    private var lastVoiceAt = 0.0               // systemUptime of the last non-silent buffer
    private var timer: DispatchSourceTimer?
    private var running = false                 // a whisper-cli run is in flight
    private var proc: Process?                  // the in-flight whisper-cli, so stop() can terminate it

    // Tunables (kept named for future exposure as options).
    private let tick = 1.0, minDur = 0.6, silenceGap = 0.8, maxDur = 8.0, maxWindow = 30.0
    private let voiceRMS: Float = 0.006         // ~ -44 dBFS gate — permissive; only drops true silence
    private var voicedSamples = 0               // above-threshold samples in the current segment
    private let minVoicedSec = 0.2              // require this much real speech before running whisper

    init(label: String, locale: Locale, onLocale: ((Locale) -> Void)? = nil,
         onUpdate: @escaping (String, Bool) -> Void) {
        self.label = label; self.locale = locale; self.onLocale = onLocale; self.onUpdate = onUpdate
        self.lang = locale.language.languageCode?.identifier ?? "auto"
    }

    func start() {
        onLocale?(locale)   // whisper uses the requested language directly; surface it in the title
        q.async { [weak self] in   // hints do file IO + EventKit — off the main thread, before the first tick
            guard let self else { return }
            self.hints = transcriptionHints(start: Date(), end: Date())
        }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + tick, repeating: tick)
        t.setEventHandler { [weak self] in self?.transcribeIfReady() }
        t.resume(); timer = t
        elog("whisperlive[\(label)]: started (lang=\(lang), model=\((cfg.whisperModel as NSString).lastPathComponent))")
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let conv = to16kMono(buffer), let ch = conv.floatChannelData?[0] else { return }
        let n = Int(conv.frameLength); guard n > 0 else { return }
        var sum: Float = 0; for i in 0..<n { sum += ch[i] * ch[i] }
        let rms = (sum / Float(n)).squareRoot()
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        if seg.isEmpty { startedAt = now; voicedSamples = 0 }
        seg.append(contentsOf: UnsafeBufferPointer(start: ch, count: n))
        if rms > voiceRMS { lastVoiceAt = now; voicedSamples += n }
        let cap = Int(fmt.sampleRate * maxWindow)
        if seg.count > cap { seg.removeFirst(seg.count - cap) }
        lock.unlock()
    }

    func stop() {
        timer?.cancel(); timer = nil
        lock.lock(); let p = proc; proc = nil; lock.unlock()
        p?.terminate()   // kill any in-flight whisper-cli so it doesn't keep burning CPU / leak
        q.async {   // runs after any in-flight transcribeIfReady() (serial queue) so the wav isn't recreated post-delete
            self.lock.lock(); self.seg.removeAll(); self.running = false; self.lock.unlock()
            try? FileManager.default.removeItem(at: self.wavURL)
        }
    }

    /// Convert an incoming buffer (mic native / 48 kHz tap) to 16 kHz mono float.
    private func to16kMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == fmt { return buffer }
        lock.lock()
        if converter == nil || converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: fmt) }
        let c = converter; lock.unlock()
        guard let c else { return nil }
        let ratio = fmt.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: capacity) else { return nil }
        var fed = false; var err: NSError?
        c.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        return (err == nil && out.frameLength > 0) ? out : nil
    }

    /// Timer handler (on `q`). Snapshots the segment, decides finalize vs volatile, runs whisper-cli.
    private func transcribeIfReady() {
        lock.lock()
        if running { lock.unlock(); return }
        let samples = seg, started = startedAt, lastVoice = lastVoiceAt, voiced = voicedSamples
        lock.unlock()
        let now = ProcessInfo.processInfo.systemUptime
        let dur = Double(samples.count) / fmt.sampleRate
        guard dur >= minDur else { return }
        // Whisper hallucinates ("Thank you", "Thanks for watching"…) on silence — only run it once the segment holds
        // enough real voice; otherwise drop the silence untranscribed.
        if Double(voiced) / fmt.sampleRate < minVoicedSec {
            lock.lock(); seg.removeAll(keepingCapacity: true); startedAt = 0; voicedSamples = 0; lock.unlock()
            return
        }
        let finalize = (now - lastVoice > silenceGap) || (now - started > maxDur)
        lock.lock(); running = true; lock.unlock()
        let text = runWhisper(samples)
        if !text.isEmpty { onUpdate(text, finalize) }
        lock.lock()
        if finalize { seg.removeAll(keepingCapacity: true); startedAt = 0; voicedSamples = 0 }
        running = false
        lock.unlock()
    }

    private func runWhisper(_ samples: [Float]) -> String {
        guard FileManager.default.isExecutableFile(atPath: cfg.whisperCli),
              FileManager.default.fileExists(atPath: cfg.whisperModel) else {
            elog("whisperlive[\(label)]: whisper-cli or model missing (\(cfg.whisperCli))"); return ""
        }
        guard writeWav(samples) else { return "" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cfg.whisperCli)
        // -nt: plain text (no timestamps); -bs 1: greedy for latency; half the cores to spare the engine.
        var args = ["-m", cfg.whisperModel, "-f", wavURL.path, "-l", lang, "-nt", "-np", "-sns",
                    "-bs", "1", "-t", String(max(4, ProcessInfo.processInfo.activeProcessorCount - 2))]
        if !hints.isEmpty { args += ["--prompt", hints] }   // same proper-noun dictionary as the saved transcript
        p.arguments = args
        let out = Pipe(); p.standardOutput = out
        p.standardError = FileHandle.nullDevice   // discard stderr — draining a Pipe we never read can deadlock waitUntilExit()
        lock.lock(); proc = p; lock.unlock()
        do { try p.run() } catch { elog("whisperlive run: \(error)"); lock.lock(); proc = nil; lock.unlock(); return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        lock.lock(); proc = nil; lock.unlock()
        let raw = String(data: data, encoding: .utf8) ?? ""
        let text = raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") }.joined(separator: " ")
        if text.isEmpty || p.terminationStatus != 0 { elog("whisperlive[\(label)]: whisper exit \(p.terminationStatus), raw \(raw.count) chars → empty") }
        return text
    }

    private func writeWav(_ samples: [Float]) -> Bool {
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) else { return false }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        do {
            let file = try AVAudioFile(forWriting: wavURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buf); return true
        } catch { elog("whisperlive writeWav: \(error)"); return false }
    }
}

/// Convert a capture buffer to 16-bit little-endian PCM (mono) at `fmt`'s sample rate, reusing the
/// caller's converter — the exact conversion every streaming STT client feeds its socket (raw bytes for
/// binary framing, or the payload a base64 JSON frame wraps). Feed-thread only. Shared by the WebSocket
/// engines below; the first brick of the reusable streaming base (see ARCHITECTURE.md).
func pcm16LE(from buffer: AVAudioPCMBuffer, to fmt: AVAudioFormat, converter: inout AVAudioConverter?) -> Data? {
    let mono: AVAudioPCMBuffer
    if buffer.format == fmt {
        mono = buffer
    } else {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: fmt)
        }
        guard let c = converter else { return nil }
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * fmt.sampleRate / buffer.format.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return nil }
        var fed = false; var err: NSError?
        c.convert(to: out, error: &err) { _, s in if fed { s.pointee = .noDataNow; return nil }; fed = true; s.pointee = .haveData; return buffer }
        guard err == nil, out.frameLength > 0 else { return nil }
        mono = out
    }
    guard let ch = mono.floatChannelData?[0] else { return nil }
    let n = Int(mono.frameLength); guard n > 0 else { return nil }
    var i16 = [Int16](repeating: 0, count: n)
    for i in 0..<n { let v = max(-1, min(1, ch[i])); i16[i] = Int16(v * 32767) }
    return i16.withUnsafeBufferPointer { Data(buffer: $0) }
}

/// Cloud live engine: streams 16 kHz linear16 audio to Deepgram's realtime WebSocket API and maps its
/// interim/final results onto the overlay's volatile/final line model. THE ONLY feature that sends audio
/// off-device, and only while the overlay is open with this engine selected — the saved whisper transcript
/// stays fully local. Needs an API key (Settings → Live; `MR_DEEPGRAM_KEY`). No SDK — URLSessionWebSocketTask.
final class DeepgramLiveTranscriber: NSObject, LiveTranscribing, URLSessionWebSocketDelegate {
    private let label: String
    private let locale: Locale
    private let onUpdate: (String, Bool) -> Void
    private let onLocale: ((Locale) -> Void)?
    private let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let q = DispatchQueue(label: "macrec.deepgram", qos: .userInitiated)   // serializes task/pending/stopped
    private var converter: AVAudioConverter?   // feed thread only (one capture thread per transcriber)
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pending = Data()               // audio awaiting send (batch ≈100 ms — DG likes 20–250 ms chunks)
    private var stopped = false
    private var keepalive: DispatchSourceTimer?
    private var lastSentAt = 0.0
    private let batchBytes = 1600 * 2          // 100 ms of 16 kHz Int16

    /// The key the user stored (Keychain, migrating any pre-Keychain prefs value). Used by both the
    /// engine and the Settings field, so upgraders see their key instead of an empty field. The legacy
    /// value is removed ONLY once the Keychain write is confirmed (a failed save must not drop the
    /// sole stored credential).
    static var storedKey: String? {
        if let k = Keychain.get("deepgram") { return k }
        guard !Keychain.disabled else { return nil }   // never migrate (and never delete the legacy pref) in tests
        if let k = Pref.d.string(forKey: Pref.deepgramKey), !k.isEmpty {
            if Keychain.set("deepgram", k) { Pref.d.removeObject(forKey: Pref.deepgramKey) }
            return k
        }
        return nil
    }
    static var apiKey: String { storedKey ?? ProcessInfo.processInfo.environment["MR_DEEPGRAM_KEY"] ?? "" }

    init(label: String, locale: Locale, onLocale: ((Locale) -> Void)? = nil,
         onUpdate: @escaping (String, Bool) -> Void) {
        self.label = label; self.locale = locale; self.onLocale = onLocale; self.onUpdate = onUpdate
    }

    /// The realtime endpoint for a language + hint keywords (each term becomes a `keywords` boost —
    /// same proper-noun dictionary as the saved transcript; capped for URL sanity). Pure + testable.
    static func listenURL(lang: String, keywords: [String]) -> URL {
        var comps = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        var items: [URLQueryItem] = [
            .init(name: "model", value: "nova-2"),
            .init(name: "language", value: lang),
            .init(name: "encoding", value: "linear16"),
            .init(name: "sample_rate", value: "16000"),
            .init(name: "channels", value: "1"),
            .init(name: "interim_results", value: "true"),
            .init(name: "smart_format", value: "true"),
            .init(name: "punctuate", value: "true"),
            .init(name: "endpointing", value: "300"),
        ]
        items += keywords.prefix(30).map { URLQueryItem(name: "keywords", value: $0) }
        comps.queryItems = items
        return comps.url!
    }

    func start() {
        onLocale?(locale)
        let key = Self.apiKey
        guard !key.isEmpty else {
            onUpdate("Deepgram API key not set — Settings → Live (or MR_DEEPGRAM_KEY)", true)
            elog("deepgram[\(label)]: no API key — engine idle")
            return
        }
        let lang = locale.language.languageCode?.identifier ?? "en"
        q.async { [self] in   // all connection state (task/session/pending/lastSentAt/stopped) lives on q
            guard !stopped else { return }   // stop() can land before this block on a quick toggle — don't orphan a socket
            // Hints do file IO + an EventKit query — computed HERE, not on the main thread that
            // builds engines (review finding: a slow hints file/calendar froze the app).
            let keywords = parseHintTerms(transcriptionHints(start: Date(), end: Date()))
            var req = URLRequest(url: Self.listenURL(lang: lang, keywords: keywords))
            req.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
            let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            let t = s.webSocketTask(with: req)
            session = s; task = t
            lastSentAt = ProcessInfo.processInfo.systemUptime   // fresh socket = no send gap yet
            t.resume()
            receiveLoop(t)
            // Deepgram closes the socket after ~10 s without messages; audio normally flows continuously
            // (silence included), but a paused/stalled source shouldn't kill the connection.
            let ka = DispatchSource.makeTimerSource(queue: q)
            ka.schedule(deadline: .now() + 5, repeating: 5)
            ka.setEventHandler { [weak self] in
                guard let self, let t = self.task, !self.stopped else { return }
                if ProcessInfo.processInfo.systemUptime - self.lastSentAt > 5 {
                    t.send(.string(#"{"type":"KeepAlive"}"#)) { _ in }
                }
            }
            ka.resume(); keepalive = ka
        }
        elog("deepgram[\(label)]: connecting (lang=\(lang))")
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        // No early `task` check — that state is q-confined (reading it here would race start()/stop()).
        // The no-connection case (e.g. missing key) just converts ~µs worth and drops inside q.async.
        guard let data = pcm16LE(from: buffer, to: fmt, converter: &converter) else { return }
        q.async { [weak self] in
            guard let self, let t = self.task, !self.stopped else { return }
            self.pending.append(data)
            guard self.pending.count >= self.batchBytes else { return }
            let out = self.pending; self.pending.removeAll(keepingCapacity: true)
            self.lastSentAt = ProcessInfo.processInfo.systemUptime
            t.send(.data(out)) { [weak self] err in
                if let err, let self, !self.stopped { elog("deepgram[\(self.label)] send: \(err.localizedDescription)") }
            }
        }
    }

    func stop() {
        q.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.stopped = true
            self.keepalive?.cancel(); self.keepalive = nil
            guard let t = self.task else { return }
            self.task = nil
            let s = self.session; self.session = nil
            if !self.pending.isEmpty {   // flush the sub-batch tail (≤100 ms) so the final caption isn't clipped
                let tail = self.pending; self.pending.removeAll(keepingCapacity: false)
                t.send(.data(tail)) { _ in }   // WebSocket frames are ordered — this precedes CloseStream
            }
            // Cancel only after CloseStream had its chance to flush — an immediate cancel can drop it.
            t.send(.string(#"{"type":"CloseStream"}"#)) { _ in
                t.cancel(with: .normalClosure, reason: nil)
                s?.finishTasksAndInvalidate()
            }
            elog("deepgram[\(self.label)]: stopped")
        }
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.q.async {   // state (stopped) is q-confined; also serializes handle() with teardown
                guard !self.stopped else { return }
                switch result {
                case .failure(let err):
                    elog("deepgram[\(self.label)] receive: \(err.localizedDescription)")
                    self.onUpdate("(Deepgram connection lost: \(err.localizedDescription))", true)
                    // Dead connection → full teardown; otherwise KeepAlive keeps firing and feed()
                    // keeps queueing sends into a socket that will never deliver.
                    self.stopped = true
                    self.keepalive?.cancel(); self.keepalive = nil
                    self.task?.cancel(with: .abnormalClosure, reason: nil); self.task = nil
                    self.session?.finishTasksAndInvalidate(); self.session = nil
                case .success(let msg):
                    if case .string(let text) = msg { self.handle(text) }
                    self.receiveLoop(t)   // keep listening (also drains pings/metadata)
                }
            }
        }
    }

    func handle(_ text: String) {   // internal for the selftest (message-parsing is the pure logic here)
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if obj["type"] as? String == "Error" || obj["error"] != nil {
            elog("deepgram[\(label)] error message: \(text.prefix(300))")
            onUpdate("(Deepgram error — check the API key / log)", true)
            return
        }
        guard obj["type"] as? String == "Results",
              let channel = obj["channel"] as? [String: Any],
              let alts = channel["alternatives"] as? [[String: Any]],
              let transcript = alts.first?["transcript"] as? String else { return }
        let isFinal = obj["is_final"] as? Bool ?? false
        guard !transcript.isEmpty else { return }
        onUpdate(transcript, isFinal)
    }
}

/// Cloud live engine #2: OpenAI's Realtime transcription API (gpt-4o-transcribe). Streams pcm16 @ 24 kHz
/// over a WebSocket; the server VAD segments turns, transcript DELTAS append to the current line and
/// `completed` finalizes it. Same rules as Deepgram: sends audio off-device ONLY while the overlay runs
/// with this engine selected; API key in the Keychain (Settings → Live; `MR_OPENAI_KEY`). No SDK.
final class OpenAILiveTranscriber: NSObject, LiveTranscribing, URLSessionWebSocketDelegate {
    private let label: String
    private let locale: Locale
    private let onUpdate: (String, Bool) -> Void
    private let onLocale: ((Locale) -> Void)?
    private let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    private let q = DispatchQueue(label: "macrec.openailive", qos: .userInitiated)   // confines all connection state
    private var converter: AVAudioConverter?   // feed thread only (one capture thread per transcriber)
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pending = Data()               // audio awaiting send (batch ≈100 ms)
    private var accum = ""                     // running transcript of the current turn (deltas append)
    private var stopped = false
    private let batchBytes = 2400 * 2          // 100 ms of 24 kHz Int16

    static var storedKey: String? { Keychain.get("openai") }
    static var apiKey: String { storedKey ?? ProcessInfo.processInfo.environment["MR_OPENAI_KEY"] ?? "" }

    /// Realtime endpoint for a BASE (an OpenAI-compatible proxy/gateway host, e.g. a corporate LLM
    /// proxy). Accepts `https://`, `http://`, `wss://` or `ws://` bases, with or without a path prefix;
    /// http(s) is mapped to the matching WebSocket scheme and `/v1/realtime?intent=transcription` is
    /// appended. Empty/invalid → the official endpoint. Pure + testable (see `macrec selftest`).
    static func realtimeURL(base: String) -> URL {
        let official = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
        let raw = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return official }
        guard var comps = URLComponents(string: raw), let scheme = comps.scheme?.lowercased(), comps.host != nil else {
            // Don't echo the raw value — a pasted URL can carry credentials/sensitive query params.
            elog("openailive: invalid base URL (redacted) — using the official endpoint")
            return official
        }
        switch scheme {
        case "https": comps.scheme = "wss"
        case "http":  comps.scheme = "ws"
        case "wss", "ws": break
        default:
            elog("openailive: unsupported base scheme '\(scheme)' — using the official endpoint")
            return official
        }
        while comps.path.hasSuffix("/") { comps.path.removeLast() }
        comps.path += "/v1/realtime"
        // Gateways often need their own query params — keep them, but never duplicate `intent`.
        var items = (comps.queryItems ?? []).filter { $0.name != "intent" }
        items.append(URLQueryItem(name: "intent", value: "transcription"))
        comps.queryItems = items
        return comps.url ?? official
    }
    /// The configured base: an EXPLICITLY saved value (even empty = "use the official endpoint")
    /// beats the MR_OPENAI_BASE env — otherwise clearing the Settings field couldn't override the env.
    static var configuredBase: String {
        if Pref.d.object(forKey: Pref.openaiBase) != nil { return Pref.d.string(forKey: Pref.openaiBase) ?? "" }
        return ProcessInfo.processInfo.environment["MR_OPENAI_BASE"] ?? ""
    }
    static var endpoint: URL { realtimeURL(base: configuredBase) }

    /// The transcription-session config event: pcm16 in, server VAD segmenting turns; a non-empty hints
    /// dictionary rides the transcription prompt (same proper nouns as the saved transcript). Pure + testable.
    static func sessionConfig(lang: String, hints: String) -> [String: Any] {
        var transcription: [String: Any] = ["model": "gpt-4o-transcribe", "language": lang]
        if !hints.isEmpty { transcription["prompt"] = hints }
        return ["type": "transcription_session.update", "session": [
            "input_audio_format": "pcm16",
            "input_audio_transcription": transcription,
            "turn_detection": ["type": "server_vad", "silence_duration_ms": 500],
        ] as [String: Any]]
    }

    init(label: String, locale: Locale, onLocale: ((Locale) -> Void)? = nil,
         onUpdate: @escaping (String, Bool) -> Void) {
        self.label = label; self.locale = locale; self.onLocale = onLocale; self.onUpdate = onUpdate
    }

    func start() {
        onLocale?(locale)
        let key = Self.apiKey
        guard !key.isEmpty else {
            onUpdate("OpenAI API key not set — Settings → Live (or MR_OPENAI_KEY)", true)
            elog("openailive[\(label)]: no API key — engine idle")
            return
        }
        let lang = locale.language.languageCode?.identifier ?? "en"
        let endpoint = Self.endpoint
        var req = URLRequest(url: endpoint)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        q.async { [self] in
            guard !stopped else { return }   // stop() can land before this block on a quick toggle
            let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            let t = s.webSocketTask(with: req)
            session = s; task = t
            t.resume()
            receiveLoop(t)
            // Configure the transcription session: raw pcm16 in, server VAD segmenting turns. The hints
            // dictionary rides the transcription prompt (same proper nouns as the saved transcript).
            let cfg = Self.sessionConfig(lang: lang, hints: transcriptionHints(start: Date(), end: Date()))
            if let d = try? JSONSerialization.data(withJSONObject: cfg), let str = String(data: d, encoding: .utf8) {
                t.send(.string(str)) { [weak self] err in
                    if let err, let self, !self.stopped { elog("openailive[\(self.label)] config: \(err.localizedDescription)") }
                }
            }
        }
        elog("openailive[\(label)]: connecting (lang=\(lang), host=\(endpoint.host ?? "?"))")
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        // No off-queue state peeks (q-confined); the no-connection case just converts ~µs and drops.
        guard let data = pcm16LE(from: buffer, to: fmt, converter: &converter) else { return }
        q.async { [weak self] in
            guard let self, self.task != nil, !self.stopped else { return }
            self.pending.append(data)
            guard self.pending.count >= self.batchBytes else { return }
            let out = self.pending; self.pending.removeAll(keepingCapacity: true)
            self.sendAudio(out)
        }
    }

    private func sendAudio(_ chunk: Data) {   // caller is on q
        guard let t = task else { return }
        let msg = #"{"type":"input_audio_buffer.append","audio":""# + chunk.base64EncodedString() + #""}"#
        t.send(.string(msg)) { [weak self] err in
            if let err, let self, !self.stopped { elog("openailive[\(self.label)] send: \(err.localizedDescription)") }
        }
    }

    func stop() {
        q.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.stopped = true
            guard let t = self.task else { return }
            self.task = nil
            let s = self.session; self.session = nil
            // Best-effort final flush: append any sub-batch tail, then COMMIT so the server transcribes
            // what it's holding before the close (server VAD normally commits on silence, but we're
            // closing now). A commit on a too-small/empty buffer can error — harmless: `stopped` is
            // already set, so the receive loop drops any late error event.
            let finish = {
                t.send(.string(#"{"type":"input_audio_buffer.commit"}"#)) { _ in
                    t.cancel(with: .normalClosure, reason: nil)
                    s?.finishTasksAndInvalidate()
                }
            }
            if !self.pending.isEmpty {
                let msg = #"{"type":"input_audio_buffer.append","audio":""# + self.pending.base64EncodedString() + #""}"#
                self.pending.removeAll(keepingCapacity: false)
                t.send(.string(msg)) { _ in finish() }
            } else {
                finish()
            }
            elog("openailive[\(self.label)]: stopped")
        }
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.q.async {   // state is q-confined; also serializes handle() with teardown
                guard !self.stopped else { return }
                switch result {
                case .failure(let err):
                    elog("openailive[\(self.label)] receive: \(err.localizedDescription)")
                    self.onUpdate("(OpenAI connection lost: \(err.localizedDescription))", true)
                    // Dead connection → full teardown; nothing should keep sending into it.
                    self.stopped = true
                    self.task?.cancel(with: .abnormalClosure, reason: nil); self.task = nil
                    self.session?.finishTasksAndInvalidate(); self.session = nil
                case .success(let msg):
                    if case .string(let text) = msg { self.handle(text) }
                    self.receiveLoop(t)
                }
            }
        }
    }

    func handle(_ text: String) {   // internal for the selftest (event parsing is the pure logic here)
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "conversation.item.input_audio_transcription.delta":
            guard let delta = obj["delta"] as? String, !delta.isEmpty else { return }
            accum += delta                     // OpenAI deltas APPEND (Deepgram interims replace)
            onUpdate(accum, false)
        case "conversation.item.input_audio_transcription.completed":
            let transcript = obj["transcript"] as? String ?? accum
            accum = ""
            guard !transcript.isEmpty else { return }
            onUpdate(transcript, true)
        case "error":
            elog("openailive[\(label)] error: \(text.prefix(300))")
            onUpdate("(OpenAI error — check the API key / log)", true)
        default: break   // session.created / committed / speech_started … — not caption-relevant
        }
    }
}

/// Cloud live engine #3: Gladia realtime v2 — notable for broad language coverage including Korean
/// STREAMING (the reason it was picked over AssemblyAI, whose realtime is English-centric). Two-step
/// protocol: a REST init (X-Gladia-Key) returns a single-use WebSocket URL; audio then streams as
/// binary pcm16 @ 16 kHz. Same rules as the other cloud engines: audio leaves the device ONLY while
/// the overlay runs with this engine; key in the Keychain (Settings → Live; MR_GLADIA_KEY). No SDK.
final class GladiaLiveTranscriber: NSObject, LiveTranscribing, URLSessionWebSocketDelegate {
    private let label: String
    private let locale: Locale
    private let onUpdate: (String, Bool) -> Void
    private let onLocale: ((Locale) -> Void)?
    private let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let q = DispatchQueue(label: "macrec.gladialive", qos: .userInitiated)   // confines all connection state
    private var converter: AVAudioConverter?   // feed thread only (one capture thread per transcriber)
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pending = Data()               // audio awaiting send (batch ≈100 ms)
    private var stopped = false
    private let batchBytes = 1600 * 2          // 100 ms of 16 kHz Int16

    static var storedKey: String? { Keychain.get("gladia") }
    static var apiKey: String { storedKey ?? ProcessInfo.processInfo.environment["MR_GLADIA_KEY"] ?? "" }

    init(label: String, locale: Locale, onLocale: ((Locale) -> Void)? = nil,
         onUpdate: @escaping (String, Bool) -> Void) {
        self.label = label; self.locale = locale; self.onLocale = onLocale; self.onUpdate = onUpdate
    }

    /// The REST-init body: stream format + language + the hints dictionary as custom vocabulary.
    /// Pure + testable (see `macrec selftest`).
    static func initBody(lang: String, vocabulary: [String]) -> [String: Any] {
        var body: [String: Any] = [
            "encoding": "wav/pcm", "sample_rate": 16000, "bit_depth": 16, "channels": 1,
        ]
        if !lang.isEmpty { body["language_config"] = ["languages": [lang], "code_switching": false] }
        if !vocabulary.isEmpty {
            body["realtime_processing"] = ["custom_vocabulary": true,
                                           "custom_vocabulary_config": ["vocabulary": vocabulary]] as [String: Any]
        }
        return body
    }

    func start() {
        onLocale?(locale)
        let key = Self.apiKey
        guard !key.isEmpty else {
            onUpdate("Gladia API key not set — Settings → Live (or MR_GLADIA_KEY)", true)
            elog("gladialive[\(label)]: no API key — engine idle")
            return
        }
        let lang = locale.language.languageCode?.identifier ?? ""
        elog("gladialive[\(label)]: requesting session (lang=\(lang.isEmpty ? "auto" : lang))")
        q.async { [self] in
            guard !stopped else { return }
            // Hints do file IO + an EventKit query — computed HERE, not on the main thread that
            // builds engines (review finding: a slow hints file/calendar froze the app).
            let vocab = parseHintTerms(transcriptionHints(start: Date(), end: Date()))
            var req = URLRequest(url: URL(string: "https://api.gladia.io/v2/live")!)
            req.httpMethod = "POST"
            req.setValue(key, forHTTPHeaderField: "X-Gladia-Key")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: Self.initBody(lang: lang, vocabulary: vocab))
            startSession(req)
        }
    }

    private func startSession(_ req: URLRequest) {   // on q
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self else { return }
            self.q.async {
                guard !self.stopped else { return }   // stop() can land before the session arrives
                let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
                guard err == nil, (200..<300).contains(status), let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let urlStr = obj["url"] as? String, let wsURL = URL(string: urlStr) else {
                    elog("gladialive[\(self.label)] init failed: status \(status) \(err?.localizedDescription ?? "")")
                    self.onUpdate("(Gladia session failed — check the API key / log)", true)
                    return
                }
                let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
                let t = s.webSocketTask(with: wsURL)   // single-use URL carries the auth token
                self.session = s; self.task = t
                t.resume()
                self.receiveLoop(t)
                if !self.pending.isEmpty {   // flush the PRE-ROLL buffered while the REST init ran
                    let out = self.pending; self.pending.removeAll(keepingCapacity: true)
                    t.send(.data(out)) { [weak self] err in
                        if let err, let self, !self.stopped { elog("gladialive[\(self.label)] preroll send: \(err.localizedDescription)") }
                    }
                }
            }
        }.resume()
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        // No off-queue state peeks (q-confined); the no-connection case just converts ~µs and drops.
        guard let data = pcm16LE(from: buffer, to: fmt, converter: &converter) else { return }
        q.async { [weak self] in
            guard let self, !self.stopped else { return }
            // PRE-ROLL: unlike the other engines, the socket only exists after Gladia's REST init
            // returns — audio spoken during that round trip must buffer, not drop (review finding:
            // the opening words after enabling captions were lost). Cap ~30 s in case init hangs.
            self.pending.append(data)
            if self.pending.count > 16000 * 2 * 30 { self.pending.removeFirst(self.pending.count - 16000 * 2 * 30) }
            guard let t = self.task, self.pending.count >= self.batchBytes else { return }
            let out = self.pending; self.pending.removeAll(keepingCapacity: true)
            t.send(.data(out)) { [weak self] err in
                if let err, let self, !self.stopped { elog("gladialive[\(self.label)] send: \(err.localizedDescription)") }
            }
        }
    }

    func stop() {
        q.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.stopped = true
            guard let t = self.task else { return }
            self.task = nil
            let s = self.session; self.session = nil
            if !self.pending.isEmpty {   // flush the sub-batch tail so the final words aren't clipped
                let tail = self.pending; self.pending.removeAll(keepingCapacity: false)
                t.send(.data(tail)) { _ in }   // frames are ordered — precedes stop_recording
            }
            t.send(.string(#"{"type":"stop_recording"}"#)) { _ in
                t.cancel(with: .normalClosure, reason: nil)
                s?.finishTasksAndInvalidate()
            }
            elog("gladialive[\(self.label)]: stopped")
        }
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.q.async {   // state is q-confined; also serializes handle() with teardown
                guard !self.stopped else { return }
                switch result {
                case .failure(let err):
                    elog("gladialive[\(self.label)] receive: \(err.localizedDescription)")
                    self.onUpdate("(Gladia connection lost: \(err.localizedDescription))", true)
                    self.stopped = true   // dead connection → full teardown
                    self.task?.cancel(with: .abnormalClosure, reason: nil); self.task = nil
                    self.session?.finishTasksAndInvalidate(); self.session = nil
                case .success(let msg):
                    if case .string(let text) = msg { self.handle(text) }
                    self.receiveLoop(t)
                }
            }
        }
    }

    func handle(_ text: String) {   // internal for the selftest (message parsing is the pure logic here)
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "transcript":
            guard let d = obj["data"] as? [String: Any],
                  let utterance = d["utterance"] as? [String: Any],
                  let t = utterance["text"] as? String, !t.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            onUpdate(t.trimmingCharacters(in: .whitespaces), (d["is_final"] as? Bool) ?? false)
        case "error":
            elog("gladialive[\(label)] error: \(text.prefix(300))")
            onUpdate("(Gladia error — check the API key / log)", true)
        default: break   // audio_chunk acks / lifecycle events — not caption-relevant
        }
    }
}

/// Cloud live engine: ElevenLabs Scribe v2 Realtime — best-in-class Korean/Japanese accuracy, streaming.
/// Sends audio off-device ONLY while the overlay runs with this engine selected; API key in the Keychain
/// (Settings → Live; `MR_ELEVENLABS_KEY`). No SDK. Server VAD segments turns: `partial_transcript` updates
/// the current (volatile) line, `committed_transcript` finalizes it. Audio is base64 PCM16 (16 kHz mono)
/// inside an `input_audio_chunk` JSON frame; auth is the `xi-api-key` header. Protocol per elevenlabs.io docs.
final class ElevenLabsLiveTranscriber: NSObject, LiveTranscribing, URLSessionWebSocketDelegate {
    private let label: String
    private let locale: Locale
    private let onUpdate: (String, Bool) -> Void
    private let onLocale: ((Locale) -> Void)?
    private let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let q = DispatchQueue(label: "macrec.elevenlabslive", qos: .userInitiated)   // confines connection state
    private var converter: AVAudioConverter?   // feed thread only (one capture thread per transcriber)
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pending = Data()               // audio awaiting send (batch ≈100 ms)
    private var stopped = false
    private let batchBytes = 1600 * 2          // 100 ms of 16 kHz Int16

    static var storedKey: String? { Keychain.get("elevenlabs") }
    static var apiKey: String { storedKey ?? ProcessInfo.processInfo.environment["MR_ELEVENLABS_KEY"] ?? "" }

    /// The realtime STT WebSocket URL: Scribe v2 Realtime, 16 kHz PCM in, server-VAD segmenting, and the
    /// caption language (ISO 639-1, e.g. "ko"/"ja"); empty language → server auto-detects. Pure + testable.
    static func realtimeURL(lang: String) -> URL {
        var c = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        var items = [URLQueryItem(name: "model_id", value: "scribe_v2_realtime"),
                     URLQueryItem(name: "audio_format", value: "pcm_16000"),
                     URLQueryItem(name: "commit_strategy", value: "vad")]
        if !lang.isEmpty { items.append(URLQueryItem(name: "language_code", value: lang)) }
        c.queryItems = items
        return c.url!
    }

    init(label: String, locale: Locale, onLocale: ((Locale) -> Void)? = nil,
         onUpdate: @escaping (String, Bool) -> Void) {
        self.label = label; self.locale = locale; self.onLocale = onLocale; self.onUpdate = onUpdate
    }

    func start() {
        onLocale?(locale)
        let key = Self.apiKey
        guard !key.isEmpty else {
            onUpdate("ElevenLabs API key not set — Settings → Live (or MR_ELEVENLABS_KEY)", true)
            elog("elevenlabslive[\(label)]: no API key — engine idle"); return
        }
        let lang = locale.language.languageCode?.identifier ?? ""
        var req = URLRequest(url: Self.realtimeURL(lang: lang))
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        q.async { [self] in
            guard !stopped else { return }   // stop() can land before this block on a quick toggle
            let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            let t = s.webSocketTask(with: req)
            session = s; task = t
            t.resume(); receiveLoop(t)
        }
        elog("elevenlabslive[\(label)]: connecting (lang=\(lang.isEmpty ? "auto" : lang))")
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let data = pcm16LE(from: buffer, to: fmt, converter: &converter) else { return }
        q.async { [weak self] in
            guard let self, self.task != nil, !self.stopped else { return }
            self.pending.append(data)
            guard self.pending.count >= self.batchBytes else { return }
            let out = self.pending; self.pending.removeAll(keepingCapacity: true)
            self.sendAudio(out, commit: false)
        }
    }

    private func sendAudio(_ chunk: Data, commit: Bool) {   // caller is on q
        guard let t = task else { return }
        let msg = #"{"message_type":"input_audio_chunk","audio_base_64":""# + chunk.base64EncodedString()
            + #"","commit":"# + (commit ? "true" : "false") + #","sample_rate":16000}"#
        t.send(.string(msg)) { [weak self] err in
            if let err, let self, !self.stopped { elog("elevenlabslive[\(self.label)] send: \(err.localizedDescription)") }
        }
    }

    func stop() {
        q.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.stopped = true
            guard let t = self.task else { return }
            self.task = nil; let s = self.session; self.session = nil
            // Flush the tail with a final commit so the server transcribes what it's holding, then close.
            let finish = { t.cancel(with: .normalClosure, reason: nil); s?.finishTasksAndInvalidate() }
            let msg = #"{"message_type":"input_audio_chunk","audio_base_64":""# + self.pending.base64EncodedString()
                + #"","commit":true,"sample_rate":16000}"#
            self.pending.removeAll(keepingCapacity: false)
            t.send(.string(msg)) { _ in finish() }
            elog("elevenlabslive[\(self.label)]: stopped")
        }
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.q.async {   // state is q-confined; also serializes handle() with teardown
                guard !self.stopped else { return }
                switch result {
                case .failure(let err):
                    elog("elevenlabslive[\(self.label)] receive: \(err.localizedDescription)")
                    self.onUpdate("(ElevenLabs connection lost: \(err.localizedDescription))", true)
                    self.stopped = true
                    self.task?.cancel(with: .abnormalClosure, reason: nil); self.task = nil
                    self.session?.finishTasksAndInvalidate(); self.session = nil
                case .success(let msg):
                    if case .string(let text) = msg { self.handle(text) }
                    self.receiveLoop(t)
                }
            }
        }
    }

    func handle(_ text: String) {   // internal for the selftest (message parsing is the pure logic here)
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["message_type"] as? String else { return }
        switch type {
        case "partial_transcript":                                   // full current partial → REPLACES the line
            if let t = obj["text"] as? String, !t.isEmpty { onUpdate(t, false) }
        case "committed_transcript", "committed_transcript_with_timestamps":   // final
            if let t = obj["text"] as? String, !t.isEmpty { onUpdate(t, true) }
        case "auth_error", "quota_exceeded", "unaccepted_terms":     // terminal + actionable → tell the user
            elog("elevenlabslive[\(label)] server \(type): \(obj["error"] as? String ?? "")")
            onUpdate("(ElevenLabs \(type) — check the API key/quota)", true)
        default:
            // The server closes on any error (receiveLoop then surfaces "connection lost"); log the reason.
            if type.hasSuffix("error") || type == "rate_limited" || type == "queue_overflow" {
                elog("elevenlabslive[\(label)] server \(type): \(obj["error"] as? String ?? "")")
            }
            // session_started, commit_throttled, etc. → ignore
        }
    }
}
