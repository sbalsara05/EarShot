import Foundation
import XCTest
@testable import EarshotCore

enum TestEnv {
    static let repoRoot: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let dict: EMSDictionary = try! EMSDictionary(directory: repoRoot.appendingPathComponent("shared"))
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let clock = CallClock(iso: "2026-11-15T14:00:00-05:00")!
}

func seg(_ text: String, id: String = "s1", start: Int64 = 0, end: Int64 = 4000) -> RawSegment {
    RawSegment(id: id, startMs: start, endMs: end, text: text)
}

func extract(_ text: String) -> [Finding] {
    let c = Cleanup(dict: TestEnv.dict).clean(seg(text)).0
    return RulesExtractor(dict: TestEnv.dict).extract(c)
}

/// Scripted ASR for pipeline tests: returns canned text for each chunk in order.
final class ScriptedTranscriber: Transcriber {
    var lines: [String]
    let modelName = "scripted"
    init(_ lines: [String]) { self.lines = lines }
    func transcribe(_ pcm: [Float], prompt: String?) throws -> [ASRPiece] {
        guard !lines.isEmpty else { return [] }
        return [ASRPiece(startMs: 0, endMs: Int64(pcm.count / 16), text: lines.removeFirst())]
    }
}

/// Synthetic "speech": tone bursts at given seconds (VAD sees them as speech).
func burstPCM(seconds: Double, bursts: [(Double, Double)]) -> [Int16] {
    var pcm = [Int16](repeating: 0, count: Int(seconds * 16000))
    var seed: UInt32 = 1
    for i in pcm.indices { seed = seed &* 1664525 &+ 1013904223; pcm[i] = Int16(Int(seed >> 24) - 128) }
    for (a, b) in bursts {
        for i in Int(a * 16000)..<min(pcm.count, Int(b * 16000)) {
            pcm[i] = Int16(8000 * sin(Double(i) * 2 * .pi * 220 / 16000))
        }
    }
    return pcm
}
