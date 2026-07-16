import Foundation

// MARK: - naming untitled recordings (title extracted from the finished summary)

// A recording with no calendar match lands as bare "YYYY-MM-DD-HHMM" — "(untitled)" everywhere it
// shows. Once its summary exists, the SAME runner that wrote the summary can name it: the summary
// is short, so the extra call costs pennies and seconds. Naming is the pipeline's join key
// (PIPELINE.md), so the rename covers the whole set — transcript + summary + kept audio — or
// nothing at all. Everything below the runner call is pure/testable; the call itself is one line.

/// A transcript stem with no calendar slug — exactly "YYYY-MM-DD-HHMM".
func isUntitledStem(_ stem: String) -> Bool {
    guard stem.count == 15 else { return false }
    for (i, ch) in stem.enumerated() {
        if i == 4 || i == 7 || i == 10 {
            if ch != "-" { return false }
        } else if !ch.isNumber {
            return false
        }
    }
    return true
}

/// The runner's reply → a usable title, or nil when it doesn't look like one. First non-empty
/// line only (models love to explain), wrapping quotes/markers stripped, whitespace collapsed;
/// must keep at least one letter or digit (an all-punctuation "title" must not slug to the
/// generic fallback) and stay short enough to be a file name.
func cleanExtractedTitle(_ raw: String) -> String? {
    guard let firstLine = raw.split(separator: "\n")
        .map({ $0.trimmingCharacters(in: .whitespaces) })
        .first(where: { !$0.isEmpty }) else { return nil }
    var t = firstLine
    while let f = t.first, "\"'“”‘’#*`「」[](){}".contains(f) { t.removeFirst() }
    while let l = t.last, "\"'“”‘’.。!?*`「」[](){}".contains(l) { t.removeLast() }
    t = t.split(separator: " ").joined(separator: " ")
    guard !t.isEmpty, t.count <= 80, t.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
    return t
}

/// The title-extraction command: the summary on stdin, ONLY the title on stdout. Same runner CLIs
/// (and the same PATH/auth environment) as the summary itself.
func titleExtractionInvocation(runner: SummaryRunner, summaryPath: String) -> String {
    let prompt = "Reply with ONLY a concise title (2-6 words) for this meeting note, in the note's "
        + "own language. No quotes, no trailing punctuation, no explanations."
    let cat = "cat \(shq(summaryPath))"
    switch runner {
    case .claude: return "\(cat) | claude -p \(shq(prompt))"
    case .gemini: return "\(cat) | gemini -p \(shq(prompt))"
    case .codex: return "{ printf '%s\\n\\n' \(shq(prompt)); \(cat); } | codex exec -"
    }
}

/// Run a runner command and hand back (status, stdout). Same shell/PATH/auth environment as the
/// summary runner; unlike the summary (which redirects itself into a file), the title call's
/// OUTPUT is the product.
func runCommandCapturingOutput(_ command: String, timeout: TimeInterval = 120,
                               completion: @escaping (Int32, String) -> Void) {
    DispatchQueue.global(qos: .utility).async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        p.environment = postProcessEnvironment(for: command)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            elog("title: launch failed — \(error.localizedDescription)")
            completion(-1, "")
            return
        }
        let killer = DispatchWorkItem { [weak p] in
            guard let p, p.isRunning else { return }
            elog("title: runner timed out after \(Int(timeout)) s — terminating")
            p.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()   // EOF first — no pipe deadlock
        p.waitUntilExit()
        killer.cancel()
        completion(p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// The rename set that gives an untitled recording its title: every EXISTING candidate moves to
/// the titled stem ("<stem>-<slug>" + whatever followed the stem, so a "-sum" summary keeps its
/// suffix). nil when any part of the move is unsafe — stem already titled, empty slug, a
/// candidate that is not a sibling, or a destination that already exists. Never overwrites.
func titleRenamePlan(files: [String], stem: String, slug: String,
                     exists: (String) -> Bool) -> [(from: String, to: String)]? {
    guard isUntitledStem(stem), !slug.isEmpty else { return nil }
    var plan: [(from: String, to: String)] = []
    for f in files where exists(f) {
        let dir = (f as NSString).deletingLastPathComponent
        let name = (f as NSString).lastPathComponent
        guard name.hasPrefix(stem) else { return nil }   // not a sibling — refuse the whole plan
        let to = dir + "/" + stem + "-" + slug + String(name.dropFirst(stem.count))
        guard !exists(to) else { return nil }
        plan.append((from: f, to: to))
    }
    return plan.isEmpty ? nil : plan
}

/// Execute the rename set and fix the files that mention the old stem: the transcript's audio
/// link, and the summary's H1 (which equals the file name). All-or-nothing on the renames — a
/// failed move rolls the earlier ones back. Returns the new (transcript, summary) paths, or nil
/// when nothing was (or could safely be) renamed.
@discardableResult
func applyExtractedTitle(transcriptPath: String, summaryPath: String?, audioDir: String?,
                         title: String) -> (transcript: String, summary: String?)? {
    let fm = FileManager.default
    let stem = ((transcriptPath as NSString).lastPathComponent as NSString).deletingPathExtension
    let slug = slugify(title)
    var files = [transcriptPath]
    if let s = summaryPath, s != transcriptPath { files.append(s) }
    if let a = audioDir {
        let month = ((transcriptPath as NSString).deletingLastPathComponent as NSString).lastPathComponent
        for ext in ["wav", "m4a"] { files.append(a + "/" + month + "/" + stem + "." + ext) }
    }
    guard cleanExtractedTitle(title) != nil,
          let plan = titleRenamePlan(files: files, stem: stem, slug: slug,
                                     exists: { fm.fileExists(atPath: $0) }) else { return nil }
    var done: [(from: String, to: String)] = []
    for step in plan {
        do {
            try fm.moveItem(atPath: step.from, toPath: step.to)
            done.append(step)
        } catch {
            for undo in done.reversed() { try? fm.moveItem(atPath: undo.to, toPath: undo.from) }
            elog("title: rename failed for \(step.from) — \(error); rolled back")
            return nil
        }
    }
    let newStem = stem + "-" + slug
    // In-file fixups, mtime-preserving so the retention clock doesn't reset.
    func rewrite(_ path: String, _ pairs: [(String, String)]) {
        guard var text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let before = text
        for (from, to) in pairs { text = text.replacingOccurrences(of: from, with: to) }
        guard text != before else { return }
        let mdate = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        if let mdate { try? fm.setAttributes([.modificationDate: mdate], ofItemAtPath: path) }
    }
    let newTranscript = plan.first { $0.from == transcriptPath }!.to
    rewrite(newTranscript, [("\(stem).wav", "\(newStem).wav"), ("\(stem).m4a", "\(newStem).m4a")])
    let newSummary = summaryPath.flatMap { s in plan.first { $0.from == s }?.to }
    if let s = newSummary { rewrite(s, [("# \(stem)", "# \(newStem)")]) }
    elog("title: \(stem) → \(newStem)")
    return (newTranscript, newSummary)
}
