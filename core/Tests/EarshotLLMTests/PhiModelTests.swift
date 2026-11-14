import XCTest
import EarshotCore
import EarshotLLM

/// Phi-3.5-mini through llama.cpp. Skipped unless the model file is present:
/// models/phi-3.5-mini-instruct-Q4_K_M.gguf (core/scripts/fetch_phi.sh) or $EARSHOT_PHI_MODEL.
final class PhiModelTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let dict = try! EMSDictionary(directory: root.appendingPathComponent("shared"))

    func modelPath() throws -> String {
        let p = ProcessInfo.processInfo.environment["EARSHOT_PHI_MODEL"]
            ?? Self.root.appendingPathComponent("models/phi-3.5-mini-instruct-Q4_K_M.gguf").path
        guard FileManager.default.fileExists(atPath: p) else { throw XCTSkip("Phi model not present at \(p)") }
        return p
    }

    func transcript(_ name: String) throws -> RawTranscript {
        struct Seg: Decodable { var id: String; var start_ms: Int64; var end_ms: Int64; var text: String }
        let segs = try JSONDecoder().decode([Seg].self, from: Data(contentsOf: Self.root.appendingPathComponent("mocks/demo_call/\(name)")))
        return RawTranscript(callId: "demo", asrModel: "truth", segments: segs.map { RawSegment(id: $0.id, startMs: $0.start_ms, endMs: $0.end_ms, text: $0.text) })
    }

    func run(_ t: RawTranscript, llm: LLMEngine?, passes: [String]) throws -> PipelineResult {
        var cfg = PipelineConfig()
        cfg.startTime = "2026-11-15T14:00:00-05:00"
        cfg.callId = "demo"
        cfg.llm.model = llm == nil ? nil : "phi"
        cfg.llm.passes = passes
        return try EarshotPipeline(dict: Self.dict, config: cfg, transcriber: nil, llm: llm).run(.transcript(t, taps: []))
    }

    /// Same input, same threads, fresh engines: identical events, documents and llm.json decisions.
    func testDeterministic() throws {
        let path = try modelPath()
        let t = try transcript("transcript.garbled.json")
        let a = try run(t, llm: try LlamaEngine(modelPath: path, threads: 4), passes: ["recover", "narrative"])
        let b = try run(t, llm: try LlamaEngine(modelPath: path, threads: 4), passes: ["recover", "narrative"])
        XCTAssertEqual(a.events, b.events)
        XCTAssertEqual(a.docs.map(\.text), b.docs.map(\.text))
        XCTAssertEqual(a.llm?.recovery?.decisions, b.llm?.recovery?.decisions)
        XCTAssertEqual(a.llm?.narrative?.sentences, b.llm?.narrative?.sentences)
    }

    /// The hand-garbled demo: recovery adds at least one value the rules missed, and everything it
    /// adds is a value that was really said in that segment. The misheard drugs ("a spurin",
    /// "so fran") are never accepted as aspirin or ondansetron.
    func testRecoversMissedValuesAndAcceptsNothingWrong() throws {
        let path = try modelPath()
        let t = try transcript("transcript.garbled.json")
        let rules = try run(t, llm: nil, passes: [])
        let phi = try run(t, llm: try LlamaEngine(modelPath: path, threads: 4), passes: ["recover"])
        // what was really said, by segment (the truth transcript's values)
        let said: [String: [String: Set<String>]] = [
            "s5": ["bp_systolic": ["158"], "bp_diastolic": ["92"], "heart_rate": ["110"], "spo2": ["94"], "resp_rate": ["22"]],
            "s10": ["pain": ["6"], "gcs": ["15"]],
            "s11": ["bp_systolic": ["138"], "bp_diastolic": ["84"], "heart_rate": ["96"], "spo2": ["97"], "drug": ["oxygen"], "dose": ["15"], "route": ["NRB"]],
            "s9": ["drug": ["nitroglycerin"], "dose": ["0.4"], "route": ["SL"]],
            "s8": ["procedure": ["IV access"]],
        ]
        let accepted = phi.events.filter { $0.flags?.contains("llm") == true && !$0.needsConfirm }
        XCTAssertFalse(accepted.isEmpty, "recovery found nothing the rules missed: \(String(describing: phi.llm?.recovery?.decisions))")
        let ruleValues = Set(rules.events.flatMap { e in e.fields.map { "\(e.rawSpan ?? ""):\($0.key)=\($0.value)" } })
        var newValues = 0
        for e in accepted {
            XCTAssertEqual(e.models.extract, "phi-3.5-mini-q4 (verified)")
            for (k, v) in e.fields where k != "kind" {
                let span = e.rawSpan ?? ""
                if k == "term" { continue }   // findings are quoted words; checked by the verifier
                XCTAssertTrue(said[span]?[k]?.contains(v) ?? false, "accepted \(k)=\(v) in \(span), which was not said there")
                if !ruleValues.contains("\(span):\(k)=\(v)") { newValues += 1 }
            }
        }
        XCTAssertGreaterThan(newValues, 0)
        XCTAssertFalse(accepted.contains { ["aspirin", "ondansetron"].contains($0.fields["drug"] ?? "") }, "a misheard drug was accepted")
    }
}
