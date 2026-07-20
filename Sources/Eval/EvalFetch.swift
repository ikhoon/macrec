import AVFoundation
import Foundation

// MARK: - `macrec eval-fetch` — build a ko/ja eval corpus clip from a YouTube video (#31)
//
// Transcription quality is table stakes, and the only honest way to improve it is to MEASURE it on
// real ko/ja speech. YouTube gives us both halves for free: the audio, and a caption track to score
// against. `eval-fetch <url> --lang ko` downloads the audio → 16 kHz mono WAV and the caption track →
// plain-text reference, dropping "<id>.<lang>.wav" + "<id>.<lang>.txt" straight into a corpus dir the
// existing `macrec eval` already understands. Then `eval` scores whisper (and any competing engine)
// against it as CER.
//
// A caption track is one of two shapes (verified against real tracks): a CLEAN track (human or
// machine-translated — one plain line per cue) or a ROLLING auto-caption (each cue echoes the last
// finalized line as plain text, then adds the newly-spoken words carrying inline <c>/<timestamp>
// tags). The pure `vttToText` collapses both to the spoken transcript; the yt-dlp/ffmpeg calls are the
// thin IO shell around it. We PREFER a human track and say which we used — an auto-caption reference
// is itself ASR output, so scoring against it measures agreement-with-YouTube, not ground truth.

/// A WebVTT caption track → its plain spoken transcript. Pure + selftested against both shapes.
/// CUE-BASED (not per-line) so structure disambiguates content: a block is skipped whole when it's the
/// WEBVTT header or a NOTE/STYLE block (their multi-line bodies must not leak as speech); within a real
/// cue, only the lines AFTER the "-->" timing line are text (so a numeric cue-IDENTIFIER before it is
/// ignored, while a numeric caption line like "10" is kept); and rolling-vs-clean is decided PER CUE:
/// if a cue carries inline word-timing/highlight tags, only those tag-bearing lines are the
/// freshly-spoken words (the plain lines are echoes of the previous cue), else every line is kept.
/// Consecutive exact repeats collapse — this removes the rolling echo and YouTube "hold" cues, at the
/// documented cost of under-counting a line genuinely repeated back-to-back (e.g. a chorel "네, 네").
func vttToText(_ vtt: String) -> String {
    let normalized = vtt.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    var out: [String] = []
    for block in normalized.components(separatedBy: "\n\n") {
        let lines = block.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first else { continue }
        if first.hasPrefix("WEBVTT") || first.hasPrefix("NOTE") || first == "STYLE" { continue }   // non-cue block
        guard let tIdx = lines.firstIndex(where: { $0.contains("-->") }) else { continue }          // stray metadata
        let textLines = Array(lines[(tIdx + 1)...])
        let tagged = textLines.filter { $0.contains("<") }
        for line in tagged.isEmpty ? textLines : tagged {                                           // rolling ⇒ tagged only
            let clean = stripVttTags(line)
            if clean.isEmpty || out.last == clean { continue }
            out.append(clean)
        }
    }
    return out.joined(separator: " ")
}

/// Strip WebVTT inline tags — highlight/emphasis/voice/ruby spans and inline word timestamps — while
/// leaving a stray "<"/">" in real speech (e.g. "5 < 10 > 3") untouched (a blanket <[^>]*> would eat it).
func stripVttTags(_ line: String) -> String {
    line.replacingOccurrences(
        of: #"</?(c|i|b|u|v|lang|ruby|rt)(\.[^>\s]+)?( [^>]*)?>|<\d{2}:\d{2}:\d{2}[.,]\d{3}>"#,
        with: "", options: .regularExpression
    ).trimmingCharacters(in: .whitespaces)
}

/// A yt-dlp language argument for our two supported eval languages.
func evalFetchLang(_ raw: String) -> String? {
    switch raw.lowercased() {
    case "ko", "kor", "korean": return "ko"
    case "ja", "jp", "jpn", "japanese": return "ja"
    default: return nil
    }
}

/// `macrec eval-fetch <youtube-url> --lang ko|ja [--out <dir>] [--id <name>] [--yt-dlp <path>]` —
/// build one corpus clip (16 kHz WAV + caption reference). Or `--vtt-file <path>` to re-derive a
/// reference from a saved caption (no download). Needs yt-dlp + ffmpeg; every failure exits non-zero
/// WITH the subprocess's own stderr, never silently.
func runEvalFetchSubcommand(_ args: [String]) -> Never {
    var url = "", lang = "", outDir = "corpus", id = "", ytdlp = "", vttFile = ""
    var bare: [String] = []
    var i = 0
    while i < args.count {
        let a = args[i]
        func val() -> String { defer { i += 1 }; return args[safe: i + 1] ?? "" }
        switch a {
        case "--lang": lang = val()
        case "--out": outDir = val()
        case "--id": id = val()
        case "--yt-dlp": ytdlp = val()
        case "--vtt-file": vttFile = val()
        default:
            if a.hasPrefix("--") { evalFetchDie("unknown flag \(a)", 2) }
            bare.append(a)
        }
        i += 1
    }

    // Reprocess mode: parse a saved caption to plain text (re-derive a reference without a download —
    // the deterministic test seam, and a way to hand-correct a caption before re-deriving text).
    if !vttFile.isEmpty {
        guard let vtt = try? String(contentsOfFile: (vttFile as NSString).expandingTildeInPath, encoding: .utf8) else {
            evalFetchDie("can't read --vtt-file \(vttFile)", 2)
        }
        print(vttToText(vtt)); exit(0)
    }

    if bare.count > 1 { evalFetchDie("more than one URL given: \(bare.joined(separator: " "))", 2) }
    url = bare.first ?? ""
    guard !url.isEmpty, let ln = evalFetchLang(lang) else { evalFetchUsage() }

    let yt = ytdlp.isEmpty ? resolveOnPath("yt-dlp") : ytdlp
    guard let yt else { evalFetchDie("yt-dlp not found on PATH — `brew install yt-dlp`", 3) }
    if !ytdlp.isEmpty, !FileManager.default.isExecutableFile(atPath: yt) {
        evalFetchDie("--yt-dlp \(yt) is not an executable file", 3)
    }
    guard resolveOnPath("ffmpeg") != nil else { evalFetchDie("ffmpeg not found on PATH — `brew install ffmpeg`", 3) }

    let out = (outDir as NSString).expandingTildeInPath
    do { try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true) }
    catch { evalFetchDie("can't create --out \(out): \(error.localizedDescription)", 3) }
    let stem = evalFetchStem(id.isEmpty ? (evalFetchVideoID(yt: yt, url: url) ?? "clip") : id)

    // 1) Caption track — human first, auto as a labelled fallback. NOTE: exit() does NOT run `defer`,
    // so the downloaded .vtt files are cleaned explicitly, on every path, once their text is in memory.
    let (vttPath, human) = fetchCaption(yt: yt, url: url, lang: ln, outDir: out, stem: stem)
    guard let vttPath else {
        removeCaptionFiles(outDir: out, stem: stem)   // a failed attempt can still leave a partial
        evalFetchDie("no \(ln) caption track for this video — can't build a reference", 4)
    }
    let vtt = (try? String(contentsOfFile: vttPath, encoding: .utf8)) ?? ""
    let text = vttToText(vtt)
    removeCaptionFiles(outDir: out, stem: stem)        // content is now in `text`; the .vtt files aren't needed
    guard !text.isEmpty else { evalFetchDie("the \(ln) caption track parsed to empty or unreadable text", 4) }
    let refPath = "\(out)/\(stem).\(ln).txt"
    do { try text.write(toFile: refPath, atomically: true, encoding: .utf8) }
    catch { evalFetchDie("can't write \(refPath): \(error.localizedDescription)", 5) }
    // Persist provenance so a later `eval` / reviewer can tell an AUTO reference (agreement, not truth)
    // from a human one — the console label alone is lost once a corpus accumulates across runs.
    try? (human ? "human" : "auto").write(toFile: "\(out)/\(stem).\(ln).source", atomically: true, encoding: .utf8)

    // 2) Audio → 16 kHz mono WAV (whisper's native rate; matches the recorder's own capture). The WHOLE
    // video: the reference is the whole caption track, so the audio must match it — trimming only one
    // side would misalign CER. A long clip is warned about (eval kills a clip at 300 s/engine).
    let wavPath = "\(out)/\(stem).\(ln).wav"
    if let err = fetchAudioAs16kMono(yt: yt, url: url, wavPath: wavPath) {
        try? FileManager.default.removeItem(atPath: wavPath)   // never leave a partial/corrupt WAV
        evalFetchDie("audio download/convert failed (the reference \(refPath) was written — rerun for the WAV)\n\(err)", 5)
    }
    let secs = (try? AVAudioFile(forReading: URL(fileURLWithPath: wavPath))).map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0
    let longNote = secs > 280 ? "\n  note: \(Int(secs)) s clip — `eval` kills a clip at 300 s/engine; pick a shorter video" : ""
    print("""
    eval-fetch: wrote \(stem).\(ln).wav (\(String(format: "%.0f", secs)) s) + \(stem).\(ln).txt \
    (\(human ? "human" : "AUTO-generated — measures agreement, not truth") caption, \(text.count) chars)
      corpus: \(out)
      score:  macrec eval \(shq(out)) --engine 'whisper=<your whisper-cli invocation> {wav}'\(longNote)
    """)
    exit(0)
}

private func evalFetchUsage() -> Never {
    print("""
    usage: macrec eval-fetch <youtube-url> --lang ko|ja [--out <dir>] [--id <name>] [--yt-dlp <path>]
           macrec eval-fetch --vtt-file <path>          # re-derive a reference from a saved caption
      Downloads the audio (16 kHz mono WAV) + caption track (plain-text reference) into <dir> as
      <id>.<lang>.wav / <id>.<lang>.txt — a corpus clip `macrec eval` scores as CER. A human caption
      track is preferred over auto-generated (an auto track is itself ASR — it measures agreement,
      not truth); which was used is reported AND written to <id>.<lang>.source. Pick a short video
      (`eval` kills a clip at 300 s/engine). Requires yt-dlp + ffmpeg (brew install yt-dlp ffmpeg).
    """)
    exit(2)
}

private func evalFetchDie(_ message: String, _ code: Int32) -> Never {
    print("eval-fetch: \(message)"); exit(code)
}

/// A file-name-safe stem: no path separators or parent refs (so --id can't write outside --out).
func evalFetchStem(_ s: String) -> String {
    let cleaned = s.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
        .trimmingCharacters(in: .whitespaces)
    return cleaned.isEmpty ? "clip" : cleaned
}

/// The last N non-empty lines of a subprocess's stderr, indented — surfaced on failure so the reason
/// isn't hidden (the "a subprocess that redirects stderr has hidden its own error message" rule).
private func stderrTail(_ err: String, lines: Int = 6) -> String {
    err.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        .suffix(lines).map { "  \($0)" }.joined(separator: "\n")
}

/// First executable named `tool` on PATH (login-shell PATH, so brew/user bins resolve), or nil.
private func resolveOnPath(_ tool: String) -> String? {
    let (st, out, _) = runShell("command -v \(tool)")
    let s = out.trimmingCharacters(in: .whitespacesAndNewlines)
    return (st == 0 && !s.isEmpty) ? s : nil
}

/// Run a command in a login shell (PATH/brew apply); return status + stdout + stderr. stdout and
/// stderr are drained concurrently so neither pipe filling can deadlock the child.
private func runShell(_ command: String) -> (status: Int32, out: String, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", command]
    let o = Pipe(), e = Pipe()
    p.standardOutput = o; p.standardError = e
    do { try p.run() } catch { return (-1, "", error.localizedDescription) }
    var od = Data(), ed = Data()
    let g = DispatchGroup()
    DispatchQueue.global().async(group: g) { od = o.fileHandleForReading.readDataToEndOfFile() }
    DispatchQueue.global().async(group: g) { ed = e.fileHandleForReading.readDataToEndOfFile() }
    p.waitUntilExit(); g.wait()
    return (p.terminationStatus, String(decoding: od, as: UTF8.self), String(decoding: ed, as: UTF8.self))
}

/// The video's own id (a stable, file-safe stem). Login-shell rc files can print banners to stdout,
/// so take the LAST non-empty line and keep it only if it looks like a yt-dlp id.
private func evalFetchVideoID(yt: String, url: String) -> String? {
    let (st, out, _) = runShell("\(shq(yt)) --no-warnings --print id \(shq(url))")
    guard st == 0 else { return nil }
    let id = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? ""
    return id.range(of: #"^[A-Za-z0-9_-]{3,64}$"#, options: .regularExpression) != nil ? id : nil
}

/// Download the caption track for `lang`, human-authored first then auto. Returns (vtt path, wasHuman).
/// `ln.*` matches regional variants (ko-KR, ja-orig). Stale caption files from a prior run are cleared
/// first, so the human/auto label reflects THIS run's download, not a leftover.
private func fetchCaption(yt: String, url: String, lang: String, outDir: String, stem: String) -> (String?, Bool) {
    func found() -> String? {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: outDir)) ?? []
        return files.first { $0.hasPrefix("\(stem).cap.") && $0.hasSuffix(".vtt") }.map { "\(outDir)/\($0)" }
    }
    func clearStale() { if let f = found() { try? FileManager.default.removeItem(atPath: f) } }
    func attempt(auto: Bool) -> String? {
        clearStale()
        let flag = auto ? "--write-auto-subs" : "--write-subs"
        _ = runShell("\(shq(yt)) --no-warnings --skip-download \(flag) --sub-langs \(shq("\(lang).*")) "
            + "--sub-format vtt -o \(shq("\(outDir)/\(stem).cap")) \(shq(url))")
        return found()
    }
    if let human = attempt(auto: false) { return (human, true) }
    if let auto = attempt(auto: true) { return (auto, false) }
    return (nil, false)
}

/// Download best audio → 16 kHz mono 16-bit WAV (whisper's native input). Returns nil on success, or
/// an error string (with the subprocess's stderr tail) on failure.
private func fetchAudioAs16kMono(yt: String, url: String, wavPath: String) -> String? {
    let (st, _, err) = runShell("\(shq(yt)) --no-warnings --no-progress -f bestaudio -x --audio-format wav "
        + "--postprocessor-args \(shq("ffmpeg:-ar 16000 -ac 1")) -o \(shq(wavPath)) \(shq(url))")
    if st == 0, FileManager.default.fileExists(atPath: wavPath) { return nil }
    return stderrTail(err)
}

/// Remove every downloaded caption file for this stem — `--sub-langs ln.*` can fetch several variants
/// (ja + ja-orig), so cleaning only the one we parsed would leave the rest in the corpus dir.
private func removeCaptionFiles(outDir: String, stem: String) {
    for f in (try? FileManager.default.contentsOfDirectory(atPath: outDir)) ?? []
        where f.hasPrefix("\(stem).cap.") && f.hasSuffix(".vtt") {
        try? FileManager.default.removeItem(atPath: "\(outDir)/\(f)")
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
