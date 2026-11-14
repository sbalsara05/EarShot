import XCTest
@testable import EarshotCore

/// One golden file per renderer, from the fixed demo call transcript + taps.
/// Regenerate after an intended change: UPDATE_GOLDEN=1 swift test --filter GoldenTests
final class GoldenTests: XCTestCase {
    func testDemoCallGolden() throws {
        let demo = TestEnv.repoRoot.appendingPathComponent("mocks/demo_call")
        struct S: Codable { var id: String; var start_ms: Int64; var end_ms: Int64; var text: String }
        let segs = try JSONDecoder().decode([S].self, from: Data(contentsOf: demo.appendingPathComponent("transcript.truth.json")))
        let raw = RawTranscript(callId: "c1", asrModel: "ground truth", segments: segs.map { RawSegment(id: $0.id, startMs: $0.start_ms, endMs: $0.end_ms, text: $0.text) })
        let taps = try JSONDecoder().decode([TapInput].self, from: Data(contentsOf: demo.appendingPathComponent("taps.json")))
        var cfg = PipelineConfig(); cfg.startTime = "2026-11-15T14:00:00-05:00"
        let r = try EarshotPipeline(dict: TestEnv.dict, config: cfg, transcriber: nil).run(.transcript(raw, taps: taps))
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var files = Dictionary(uniqueKeysWithValues: r.docs.map { ($0.name, $0.text) })
        files["events.json"] = String(data: try enc.encode(r.events), encoding: .utf8)! + "\n"
        let dir = TestEnv.fixtures.appendingPathComponent("golden")
        for (name, text) in files.sorted(by: { $0.key < $1.key }) {
            let url = dir.appendingPathComponent(name)
            if ProcessInfo.processInfo.environment["UPDATE_GOLDEN"] == "1" {
                try text.write(to: url, atomically: true, encoding: .utf8); continue
            }
            let expected = try String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(text, expected, "\(name) differs from golden; run UPDATE_GOLDEN=1 swift test --filter GoldenTests if intended")
        }
        // determinism: a second run is identical
        let r2 = try EarshotPipeline(dict: TestEnv.dict, config: cfg, transcriber: nil).run(.transcript(raw, taps: taps))
        XCTAssertEqual(r.events, r2.events)
        // principle checks on every output
        for d in r.docs where d.name.hasSuffix(".md") {
            XCTAssertFalse(d.text.lowercased().contains("diagnos") && !d.text.contains("does not diagnose"), d.name)
        }
        XCTAssertTrue(r.docs.last!.text.contains("Schema-checked against NEMSIS v3.5.1 XSD"))
        XCTAssertTrue(r.docs.last!.text.contains("<eTimes.11>2026-11-15T14:02:40-05:00</eTimes.11>"))
        XCTAssertTrue(r.docs.last!.text.contains("<eTimes.12>2026-11-15T14:22:40-05:00</eTimes.12>"))
    }
}
