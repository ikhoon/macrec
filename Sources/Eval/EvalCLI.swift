import AVFoundation
import Foundation

// MARK: - `macrec eval` shell layer (the pure core lives in EvalRunner.swift)

// Quality is priority zero, and vendor benchmarks don't transfer — engines are scored on OUR
// audio. The corpus is a plain directory: <id>.<ko|ja>.wav (16 kHz mono) plus an optional
// <id>.<lang>.txt ground truth. Clips without a reference are still transcribed — every engine's
// hypothesis lands in <dir>/out/, and correcting one into <id>.<lang>.txt makes it ground truth
// for the next run. Engines are shell templates so ANY CLI can compete without a code change.

func runEvalSubcommand(_ args: [String]) {
    var dir: String?
    var engines: [(name: String, template: String)] = []
    var i = 0
    while i < args.count {
        let a = args[i]
        if a == "--engine", i + 1 < args.count {
            guard let spec = parseEngineSpec(args[i + 1]) else {
                print("eval: bad --engine spec '\(args[i + 1])' — need name=cmd containing {wav}")
                exit(2)
            }
            engines.append(spec)
            i += 2
        } else if dir == nil, !a.hasPrefix("-") {
            dir = (a as NSString).expandingTildeInPath
            i += 1
        } else {
            print("eval: unexpected argument '\(a)'")
            exit(2)
        }
    }
    guard let dir, !engines.isEmpty else {
        print("""
        usage: macrec eval <corpusDir> --engine 'name=cmd … {wav} …' [--engine 'name2=…']
          corpus:  <id>.<ko|ja>.wav (16 kHz mono) + optional <id>.<lang>.txt ground truth
          engines: shell commands that print the transcript to stdout;
                   {wav} → clip path (quoted), {lang} → the clip's language code
          output:  CER table over clips WITH references, wall-time/RTF table, and every
                   hypothesis in <corpusDir>/out/ (correct one into <id>.<lang>.txt → rerun)
        """)
        exit(2)
    }
    let fm = FileManager.default
    let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
    let clips = evalCorpus(names: names) { try? String(contentsOfFile: dir + "/" + $0, encoding: .utf8) }
    guard !clips.isEmpty else {
        print("eval: no <id>.<ko|ja>.wav clips in \(dir)")
        exit(2)
    }
    let outDir = dir + "/out"
    try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

    // A clip AVAudioFile can't open would silently poison the RTF denominator as "0 s of audio"
    // while its wall time still counted (review finding) — exclude it from the RUN, loudly.
    var clipSecs: [String: Double] = [:]
    let runnable = clips.filter { c in
        guard let f = try? AVAudioFile(forReading: URL(fileURLWithPath: dir + "/" + c.wav)),
              f.length > 0 else {
            print("eval: SKIPPING \(c.wav) — unreadable as audio (fix or remove it)")
            return false
        }
        clipSecs[c.wav] = Double(f.length) / f.processingFormat.sampleRate
        return true
    }
    guard !runnable.isEmpty else {
        print("eval: no readable clips")
        exit(2)
    }
    let audioSecs = clipSecs.values.reduce(0, +)
    print("eval: \(runnable.count) clips (\(Int(audioSecs)) s), \(engines.count) engines\n")

    // Ctrl-C must not orphan a running engine: track the in-flight child for the SIGINT handler.
    evalInFlightChild.withLock { $0 = nil }
    signal(SIGINT) { _ in
        evalInFlightChild.withLock { $0?.terminate() }
        exit(130)
    }

    var hyps: [String: String] = [:] // "engine\u{1}id.lang" → hypothesis
    var times: [(engine: String, seconds: Double, audioSeconds: Double)] = []
    var usableHyps = 0
    for e in engines {
        let t0 = Date()
        for (i, c) in runnable.enumerated() {
            let cmd = evalCommand(template: e.template, wav: dir + "/" + c.wav, lang: c.language)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            // -c, not -lc: a login shell's ~/.zprofile stdout would be captured INTO the
            // hypothesis (review finding); PATH is provided explicitly below instead.
            p.arguments = ["-c", cmd]
            var env = ProcessInfo.processInfo.environment
            let home = fm.homeDirectoryForCurrentUser.path
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch {
                print("eval: could not launch \(e.name) — \(error.localizedDescription)")
                exit(1)
            }
            evalInFlightChild.withLock { $0 = p }
            // Watchdog (like every other runner here): one hung engine must not wedge the whole
            // eval. Generous bound — big models on long clips are slow, not stuck.
            let killer = DispatchWorkItem { [weak p] in
                guard let p, p.isRunning else { return }
                print("eval: \(e.name) timed out on \(c.wav) after 300 s — terminating")
                p.terminate()
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 300, execute: killer)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()   // EOF first — no pipe deadlock
            p.waitUntilExit()
            killer.cancel()
            evalInFlightChild.withLock { $0 = nil }
            let hyp = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !hyp.isEmpty { usableHyps += 1 }
            hyps["\(e.name)\u{1}\(c.id).\(c.language)"] = hyp
            try? hyp.write(toFile: "\(outDir)/\(c.id).\(c.language).\(e.name).txt",
                           atomically: true, encoding: .utf8)
            if p.terminationStatus != 0 {
                print("eval: \(e.name) exited \(p.terminationStatus) on \(c.wav) — hypothesis may be empty")
            }
            print(String(format: "  %@: %d/%d %@.%@ (%.1fs)", e.name, i + 1, runnable.count,
                         c.id, c.language, Date().timeIntervalSince(t0)))
        }
        times.append((e.name, Date().timeIntervalSince(t0), audioSecs))
    }
    print("")
    let scored = runnable.compactMap { c in
        c.reference.map { EvalSample(id: "\(c.id).\(c.language)", language: c.language, reference: $0) }
    }
    if scored.isEmpty {
        print("(no ground-truth .txt yet — correct a hypothesis from out/ into <id>.<lang>.txt and rerun for CER)")
    } else {
        print(evalReport(runEval(samples: scored, engines: engines.map(\.name)) { s, engine in
            hyps["\(engine)\u{1}\(s.id)"] ?? ""
        }))
    }
    print("")
    print(evalTimingReport(times))
    print("\nhypotheses → \(outDir)")
    // Every hypothesis empty = the run measured nothing — that must not read as success in a
    // script (review finding: eval always exited 0).
    if usableHyps == 0 {
        print("eval: FAILED — every engine produced an empty hypothesis")
        exit(1)
    }
    exit(0)
}

/// The child the SIGINT handler must reap — a C signal handler can't capture context, so the
/// in-flight Process lives in a lock-guarded global. nil outside an engine invocation.
let evalInFlightChild = NSLockedBox<Process?>(nil)

/// Minimal lock-guarded box (Foundation's Mutex needs newer toolchains than the swiftc build).
final class NSLockedBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
