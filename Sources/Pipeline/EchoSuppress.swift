import AppKit
import AVFoundation
import Compression
import EventKit
import Foundation

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
