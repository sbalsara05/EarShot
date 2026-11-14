import XCTest
@testable import EarshotCore

/// Scripted language model: returns canned replies in order and records what it was asked.
final class StubLLM: LLMEngine {
    let modelName = "phi-3.5-mini-q4"
    var replies: [String]
    var prompts: [(system: String, user: String, grammar: String)] = []
    init(_ replies: [String]) { self.replies = replies }
    func complete(system: String, user: String, grammar: String, maxTokens: Int) throws -> String {
        prompts.append((system, user, grammar))
        return replies.isEmpty ? #"{"items":[]}"# : replies.removeFirst()
    }
}

/// The optional Phi passes. The model only proposes; these check that code decides.
final class LLMTests: XCTestCase {
    let dict = TestEnv.dict
    lazy var verifier = RecoveryVerifier(dict: dict, model: "phi-3.5-mini-q4")

    let segs: [String: RawSegment] = [
        "s1": seg("Pressure came back one fifty eight over ninety two, heart's going about one ten.", id: "s1"),
        "s2": seg("Pulse ox says ninety seven on two liters.", id: "s2", start: 5000, end: 9000),
        "s3": seg("Gave her three twenty four of aspirin, chewed.", id: "s3", start: 10_000, end: 14_000),
        "s4": seg("Twelve lead shows S T elevation, call a STEMI alert.", id: "s4", start: 15_000, end: 19_000),
    ]

    func item(_ type: String, _ field: String, _ value: String, _ span: String, _ quote: String) -> RecoveryItem {
        RecoveryItem(type: type, field: field, value: value, span: span, quote: quote)
    }

    // MARK: recovery verifier

    func testAcceptsValidItems() {
        let items = [
            item("vitals", "heart_rate", "110", "s1", "heart's going about one ten"),
            item("vitals", "spo2", "97", "s2", "Pulse ox says ninety seven"),
            item("medication", "drug", "aspirin", "s3", "three twenty four of aspirin"),
            item("medication", "dose", "324", "s3", "three twenty four of aspirin"),
        ]
        for it in items { XCTAssertNil(verifier.rejection(it, segments: segs), "\(it)") }
        let (found, decisions) = verifier.verify(items, window: 1, segments: segs, existing: [])
        XCTAssertEqual(decisions.filter { $0.outcome == .accepted }.count, 4)
        let hr = found.first { $0.fields["heart_rate"] != nil }
        XCTAssertEqual(hr?.fields["heart_rate"], "110")
        XCTAssertEqual(hr?.type, .vitals)
        XCTAssertEqual(hr?.extractor, "phi-3.5-mini-q4 (verified)")
        XCTAssertTrue(hr?.flags.contains("llm") ?? false)
        XCTAssertFalse(hr?.flags.contains("confirm") ?? true)
        XCTAssertEqual(hr?.receipts["heart_rate"]?.quote, "heart's going about one ten")
        XCTAssertEqual(hr?.receipts["heart_rate"]?.rawSpan, "s1")
        let med = found.first { $0.type == .medication }
        XCTAssertEqual(med?.fields["drug"], "aspirin")
        XCTAssertEqual(med?.fields["dose"], "324")
        XCTAssertNil(med?.fields["unit"], "a unit that was not said is never filled")
    }

    func testRejectsValueNotInQuote() {
        XCTAssertEqual(verifier.rejection(item("vitals", "heart_rate", "120", "s1", "heart's going about one ten"), segments: segs), "value is not in the quote")
        XCTAssertEqual(verifier.rejection(item("medication", "route", "IV", "s3", "three twenty four of aspirin, chewed"), segments: segs), "route is not in the quote")
    }

    func testRejectsQuoteNotInSpan() {
        XCTAssertEqual(verifier.rejection(item("vitals", "spo2", "97", "s1", "Pulse ox says ninety seven"), segments: segs), "quote is not in s1")
        // verbatim means verbatim: a paraphrase of the segment is not a quote
        XCTAssertEqual(verifier.rejection(item("vitals", "spo2", "97", "s2", "pulse ox said ninety seven"), segments: segs), "quote is not in s2")
    }

    func testRejectsUnknownSpan() {
        XCTAssertEqual(verifier.rejection(item("vitals", "spo2", "97", "s9", "Pulse ox says ninety seven"), segments: segs), "unknown span s9")
    }

    func testRejectsUnknownDrug() {
        let s: [String: RawSegment] = ["s1": seg("Gave her ten of flurbozine IV.")]
        XCTAssertEqual(verifier.rejection(item("medication", "drug", "flurbozine", "s1", "ten of flurbozine"), segments: s), "drug not in formulary")
        // a real drug that is not in the quote
        XCTAssertEqual(verifier.rejection(item("medication", "drug", "ondansetron", "s3", "three twenty four of aspirin"), segments: segs), "drug is not in the quote")
    }

    func testRejectsOutOfRange() {
        let s: [String: RawSegment] = ["s1": seg("Heart rate four hundred, sats one twenty.")]
        XCTAssertEqual(verifier.rejection(item("vitals", "heart_rate", "400", "s1", "Heart rate four hundred"), segments: s), "value out of range for heart_rate")
        XCTAssertEqual(verifier.rejection(item("vitals", "spo2", "120", "s1", "sats one twenty"), segments: s), "value out of range for spo2")
    }

    func testRejectsDiagnosisText() {
        XCTAssertEqual(verifier.rejection(item("finding", "term", "ST elevation", "s4", "S T elevation, call a STEMI alert"), segments: segs), "diagnosis text")
        XCTAssertEqual(verifier.rejection(item("procedure", "procedure", "STEMI alert", "s4", "call a STEMI alert"), segments: segs), "diagnosis text")
        // diagnosis text is dropped, never shown for confirmation
        let (found, d) = verifier.verify([item("finding", "term", "STEMI", "s4", "call a STEMI alert")], window: 1, segments: segs, existing: [])
        XCTAssertTrue(found.isEmpty)
        XCTAssertEqual(d.first?.outcome, .dropped)
    }

    func testRejectsUnknownFieldAndPlaceholder() {
        XCTAssertNotNil(verifier.rejection(item("vitals", "weight", "70", "s1", "one fifty eight"), segments: segs))
        let (found, d) = verifier.verify([item("vitals", "temp", "not specified", "s1", "heart's going about one ten")], window: 1, segments: segs, existing: [])
        XCTAssertTrue(found.isEmpty, "a placeholder value is only logged")
        XCTAssertEqual(d.first?.outcome, .dropped)
    }

    func testRejectedItemsGoToConfirmWithReason() {
        let wrong = item("vitals", "heart_rate", "10", "s1", "heart's going about one ten")
        let (found, decisions) = verifier.verify([wrong], window: 1, segments: segs, existing: [])
        XCTAssertEqual(decisions.first?.outcome, .confirm)
        XCTAssertEqual(decisions.first?.reason, "value out of range for heart_rate")
        XCTAssertEqual(found.count, 1)
        let f = found[0]
        XCTAssertEqual(f.type, .status)
        XCTAssertEqual(f.fields["kind"], "llm_unverified")
        XCTAssertEqual(f.fields["heard_as"], "heart's going about one ten")
        XCTAssertTrue(f.fields["note"]?.contains("value out of range") ?? false)
        XCTAssertTrue(f.flags.contains("confirm"))
        // the model's value never lands in a field, not even the note
        XCTAssertFalse(f.fields.values.contains("10"))
        XCTAssertNil(f.fields["heart_rate"])
    }

    func testDoseWithoutVerifiedDrugIsConfirm() {
        let (found, d) = verifier.verify([item("medication", "dose", "324", "s3", "three twenty four of aspirin")], window: 1, segments: segs, existing: [])
        XCTAssertEqual(d.first?.outcome, .confirm)
        XCTAssertFalse(found.contains { $0.type == .medication })
    }

    func testDuplicateOfRulesIsNotAdded() {
        let rules = extract("BP one fifty eight over ninety two")
        var existing = rules
        for i in existing.indices { existing[i].rawSpan = "s1" }
        let (found, d) = verifier.verify([item("vitals", "bp_systolic", "158", "s1", "one fifty eight over ninety two")], window: 1, segments: segs, existing: existing)
        XCTAssertTrue(found.isEmpty)
        XCTAssertEqual(d.first?.outcome, .duplicate)
    }

    // MARK: recovery pass in the pipeline

    func runPipeline(_ lines: [String], llm: LLMEngine?, passes: [String] = ["recover", "narrative"]) throws -> PipelineResult {
        let raw = RawTranscript(callId: "c1", asrModel: "t", segments: lines.enumerated().map {
            RawSegment(id: "s\($0 + 1)", startMs: Int64($0) * 5000, endMs: Int64($0) * 5000 + 4000, text: $1) })
        var cfg = PipelineConfig()
        cfg.startTime = "2026-11-15T14:00:00-05:00"
        cfg.llm.model = llm == nil ? nil : "stub"
        cfg.llm.passes = passes
        return try EarshotPipeline(dict: dict, config: cfg, transcriber: nil, llm: llm).run(.transcript(raw, taps: []))
    }

    func testRecoveredEventProvenance() throws {
        let stub = StubLLM([#"{"items":[{"type":"vitals","field":"heart_rate","value":"110","span":"s1","quote":"heart's going about one ten"}]}"#])
        let r = try runPipeline(["Pressure came back, heart's going about one ten."], llm: stub, passes: ["recover"])
        let e = try XCTUnwrap(r.events.first { $0.fields["heart_rate"] == "110" })
        XCTAssertEqual(e.source, .heard)
        XCTAssertEqual(e.models.extract, "phi-3.5-mini-q4 (verified)")
        XCTAssertTrue(e.flags?.contains("llm") ?? false)
        XCTAssertEqual(e.receipts?["heart_rate"]?.quote, "heart's going about one ten")
        XCTAssertEqual(r.llm?.recovery?.accepted, 1)
        // the model saw the segment and was constrained to its span ids
        XCTAssertTrue(stub.prompts[0].user.contains("heart's going about one ten"))
        XCTAssertTrue(stub.prompts[0].grammar.contains(#"\"s1\""#))
    }

    func testRecoveryWindowsOfEight() throws {
        let stub = StubLLM([])
        _ = try runPipeline((1...17).map { "Line \($0)." }, llm: stub, passes: ["recover"])
        XCTAssertEqual(stub.prompts.count, 3)   // 8 + 8 + 1
    }

    func testRulesOnlyIsUnchangedWithoutModel() throws {
        let lines = ["B P one fifty eight over ninety two, heart rate one ten.", "Gave three twenty four of aspirin, chewed."]
        let a = try runPipeline(lines, llm: nil)
        XCTAssertNil(a.llm)
        let b = try runPipeline(lines, llm: StubLLM([#"{"items":[]}"#, #"not json"#]))
        XCTAssertEqual(a.events, b.events, "a model that finds nothing changes nothing")
        XCTAssertEqual(a.docs.map(\.text), b.docs.map(\.text), "a narrative that fails falls back to the same template")
    }

    func testBadReplyIsLoggedNotFatal() throws {
        let r = try runPipeline(["Heart rate one ten."], llm: StubLLM(["the model rambled"]), passes: ["recover"])
        XCTAssertEqual(r.llm?.recovery?.errors.count, 1)
        XCTAssertEqual(r.events.filter { $0.type == .vitals }.count, 1)
    }

    // MARK: narrative checker

    let lines = ["B P one fifty eight over ninety two, heart rate one ten.", "Gave four milligrams of Zofran I V."]
    func checkerEvents() throws -> [EarshotEvent] { try runPipeline(lines, llm: nil).events }

    func ids(_ events: [EarshotEvent]) -> (vitals: String, med: String) {
        (events.first { $0.type == .vitals }!.id, events.first { $0.type == .medication }!.id)
    }

    func testNarrativeCheckerAcceptsGroundedSentences() throws {
        let ev = try checkerEvents(); let (v, m) = ids(ev)
        let s = [NarrativeSentence(text: "Blood pressure was 158/92 with a heart rate of 110.", events: [v]),
                 NarrativeSentence(text: "Ondansetron 4 mg was given IV.", events: [m])]
        XCTAssertEqual(NarrativeChecker(dict: dict).failures(s, events: ev, clock: TestEnv.clock), [])
    }

    func testNarrativeCheckerRejectsInventedNumber() throws {
        let ev = try checkerEvents(); let (v, m) = ids(ev)
        let f = NarrativeChecker(dict: dict).failures([NarrativeSentence(text: "Heart rate was 120.", events: [v]),
                                                        NarrativeSentence(text: "Ondansetron 4 mg IV.", events: [m])], events: ev, clock: TestEnv.clock)
        XCTAssertTrue(f.contains { $0.contains("number 120") }, "\(f)")
        // a swapped blood pressure has both numbers but is not the reading
        let g = NarrativeChecker(dict: dict).failures([NarrativeSentence(text: "BP 92/158.", events: [v]),
                                                        NarrativeSentence(text: "Ondansetron 4 mg IV.", events: [m])], events: ev, clock: TestEnv.clock)
        XCTAssertTrue(g.contains { $0.contains("blood pressure 92/158") }, "\(g)")
    }

    func testNarrativeCheckerRejectsInventedDrug() throws {
        let ev = try checkerEvents(); let (_, m) = ids(ev)
        let f = NarrativeChecker(dict: dict).failures([NarrativeSentence(text: "Ondansetron and aspirin were given IV.", events: [m])], events: ev, clock: TestEnv.clock)
        XCTAssertTrue(f.contains { $0.contains("drug aspirin") }, "\(f)")
    }

    func testNarrativeCheckerRejectsUncitedOrUnknownCitation() throws {
        let ev = try checkerEvents(); let (_, m) = ids(ev)
        let c = NarrativeChecker(dict: dict)
        XCTAssertTrue(c.failures([NarrativeSentence(text: "The patient was moved.", events: []),
                                  NarrativeSentence(text: "Ondansetron 4 mg IV.", events: [m])], events: ev, clock: TestEnv.clock)
            .contains { $0.contains("cites no event") })
        XCTAssertTrue(c.failures([NarrativeSentence(text: "Ondansetron 4 mg IV.", events: ["e99", m])], events: ev, clock: TestEnv.clock)
            .contains { $0.contains("does not exist") })
    }

    func testNarrativeCheckerRejectsDiagnosisAdviceUnheardUnitAndOmission() throws {
        let ev = try checkerEvents(); let (v, m) = ids(ev)
        let c = NarrativeChecker(dict: dict)
        XCTAssertTrue(c.failures([NarrativeSentence(text: "Findings consistent with a STEMI.", events: [v]),
                                  NarrativeSentence(text: "Ondansetron 4 mg IV.", events: [m])], events: ev, clock: TestEnv.clock).contains { $0.contains("diagnosis") })
        XCTAssertTrue(c.failures([NarrativeSentence(text: "The crew should consider aspirin.", events: [v]),
                                  NarrativeSentence(text: "Ondansetron 4 mg IV.", events: [m])], events: ev, clock: TestEnv.clock).contains { $0.contains("advice") })
        // leaving out a medication is a failure: the narrative replaces the template
        XCTAssertTrue(c.failures([NarrativeSentence(text: "BP 158/92.", events: [v])], events: ev, clock: TestEnv.clock).contains { $0.contains("leaves out") })
        // "mg" when no unit was spoken (only the protocol's suggestion) is a filled unit
        let ev2 = try runPipeline(["Gave three twenty four of aspirin, chewed."], llm: nil).events
        let asp = try XCTUnwrap(ev2.first { $0.type == .medication })
        XCTAssertEqual(asp.fields["unit_suggested"], "mg")
        XCTAssertTrue(c.failures([NarrativeSentence(text: "Aspirin 324 mg was given PO.", events: [asp.id])], events: ev2, clock: TestEnv.clock)
            .contains { $0.contains("unit mg") })
    }

    func testFailedNarrativeFallsBackToTemplate() throws {
        let rules = try runPipeline(lines, llm: nil)
        let (v, m) = ids(rules.events)
        let bad = #"{"sentences":[{"text":"Heart rate was 120.","events":["\#(v)"]},{"text":"Ondansetron 4 mg IV.","events":["\#(m)"]}]}"#
        let r = try runPipeline(lines, llm: StubLLM([bad]), passes: ["narrative"])
        XCTAssertEqual(r.llm?.narrative?.used, false)
        XCTAssertEqual(r.llm?.narrative?.fallbackReason, "checker failed")
        XCTAssertEqual(r.docs.map(\.text), rules.docs.map(\.text))
        XCTAssertFalse(r.docs.first { $0.name == "chart.md" }!.text.contains("Heart rate was 120"))
    }

    func testCheckedNarrativeGoesToChartAndNEMSIS() throws {
        let rules = try runPipeline(lines, llm: nil)
        let (v, m) = ids(rules.events)
        let good = #"{"sentences":[{"text":"BP was 158/92 & heart rate 110 <checked>.","events":["\#(v)"]},{"text":"Ondansetron 4 mg was given IV.","events":["\#(m)"]}]}"#
        let r = try runPipeline(lines, llm: StubLLM([good]), passes: ["narrative"])
        XCTAssertEqual(r.llm?.narrative?.used, true)
        let chart = r.docs.first { $0.name == "chart.md" }!.text
        XCTAssertTrue(chart.contains("Ondansetron 4 mg was given IV. [\(m)]"), chart)
        let xml = r.docs.first { $0.name == "nemsis.xml" }!.text
        XCTAssertTrue(xml.contains("<eNarrative.01>BP was 158/92 &amp; heart rate 110 &lt;checked&gt;. Ondansetron 4 mg was given IV.</eNarrative.01>"), "the model's text is escaped like any value")
        try validateNEMSIS(xml)
    }

    func testGrammarsListOnlyKnownSpansAndEvents() {
        let g = RecoveryPass.grammar(spans: ["s3", "s4"])
        XCTAssertTrue(g.contains(#""\"s3\"" | "\"s4\"""#))
        XCTAssertTrue(g.contains("root ::="))
        XCTAssertTrue(NarrativePass.grammar(ids: ["e1", "e2"]).contains(#""\"e1\"" | "\"e2\"""#))
    }

    func testConfigParses() throws {
        let c = try JSONDecoder().decode(PipelineConfig.self, from: Data(#"{"llm":{"model":"models/phi.gguf","passes":["recover"],"threads":2}}"#.utf8))
        XCTAssertTrue(c.llm.enabled)
        XCTAssertEqual(c.llm.passes, ["recover"])
        XCTAssertEqual(c.llm.threads, 2)
        XCTAssertFalse(PipelineConfig().llm.enabled, "off by default")
        XCTAssertFalse(try JSONDecoder().decode(PipelineConfig.self, from: Data(#"{"llm":{"model":"none"}}"#.utf8)).llm.enabled)
    }
}

/// NEMSIS v3.5.1 XSD check with xmllint (skips when it is not installed).
func validateNEMSIS(_ xml: String, file: StaticString = #filePath, line: UInt = #line) throws {
    let lint = ["/usr/bin/xmllint", "/opt/homebrew/bin/xmllint", "/usr/local/bin/xmllint", "/opt/anaconda3/bin/xmllint"].first { FileManager.default.fileExists(atPath: $0) }
    guard let xmllint = lint else { throw XCTSkip("xmllint not installed") }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nemsis-\(UUID().uuidString).xml")
    try xml.write(to: tmp, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: xmllint)
    p.arguments = ["--noout", "--schema", TestEnv.fixtures.appendingPathComponent("nemsis_xsd/EMSDataSet_v3.xsd").path, tmp.path]
    let pipe = Pipe(); p.standardError = pipe; p.standardOutput = pipe
    try p.run(); p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    XCTAssertEqual(p.terminationStatus, 0, out, file: file, line: line)
}

/// The app's live path runs the same passes after Whisper is done.
final class LiveSessionLLMTests: XCTestCase {
    func testRunLLMAddsVerifiedFindingsAndNarrative() throws {
        let s = LiveSession(dict: TestEnv.dict, config: PipelineConfig(), callId: "c1", startEpochMs: TestEnv.clock.startEpochMs,
                            tzOffsetSeconds: TestEnv.clock.tzOffsetSeconds, transcriber: ScriptedTranscriber(["Heart's going about one ten."]))
        s.callbackQueue = DispatchQueue(label: "t")
        s.handle(.consent(granted: true, source: "button", clipMs: 0), decoder: PCMFrameDecoder())
        let pcm = burstPCM(seconds: 4, bursts: [(0.5, 2.5)])
        var seq: UInt32 = 0
        for i in stride(from: 0, to: pcm.count, by: 320) {
            s.handleDecodedAudio(seq: seq, clipMs: seq * 20, pcm: Array(pcm[i..<min(pcm.count, i + 320)])); seq += 1
        }
        s.endCapture(); s.drain()
        let id = try XCTUnwrap(s.rawSegments.first?.id)
        XCTAssertFalse(s.events.contains { $0.fields["heart_rate"] != nil }, "the rules miss this phrasing")
        let stub = StubLLM([#"{"items":[{"type":"vitals","field":"heart_rate","value":"110","span":"\#(id)","quote":"Heart's going about one ten"}]}"#])
        let report = s.runLLM(stub, passes: [.recover])
        XCTAssertEqual(report.recovery?.accepted, 1)
        let e = try XCTUnwrap(s.events.first { $0.fields["heart_rate"] == "110" })
        XCTAssertEqual(e.models.extract, "phi-3.5-mini-q4 (verified)")
        s.wipe(); s.drain()
        XCTAssertTrue(s.events.isEmpty)
    }
}
