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

    let audioSecs = clips.reduce(0.0) { acc, c in
        let f = try? AVAudioFile(forReading: URL(fileURLWithPath: dir + "/" + c.wav))
        return acc + (f.map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0)
    }
    print("eval: \(clips.count) clips (\(Int(audioSecs)) s), \(engines.count) engines\n")

    var hyps: [String: String] = [:] // "engine\u{1}id.lang" → hypothesis
    var times: [(engine: String, seconds: Double, audioSeconds: Double)] = []
    for e in engines {
        let t0 = Date()
        for c in clips {
            let cmd = evalCommand(template: e.template, wav: dir + "/" + c.wav, lang: c.language)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", cmd]
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
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let hyp = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            hyps["\(e.name)\u{1}\(c.id).\(c.language)"] = hyp
            try? hyp.write(toFile: "\(outDir)/\(c.id).\(c.language).\(e.name).txt",
                           atomically: true, encoding: .utf8)
            if p.terminationStatus != 0 {
                print("eval: \(e.name) exited \(p.terminationStatus) on \(c.wav) — hypothesis may be empty")
            }
        }
        times.append((e.name, Date().timeIntervalSince(t0), audioSecs))
        print("  \(e.name): done in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
    }
    print("")
    let scored = clips.compactMap { c in
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
}
