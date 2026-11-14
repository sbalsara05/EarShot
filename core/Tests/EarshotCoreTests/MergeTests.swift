import XCTest
@testable import EarshotCore

final class MergeTests: XCTestCase {
    let merger = TapMerger(callId: "c1", clock: TestEnv.clock, models: ModelInfo(asr: "t", extract: "rules-v1"))

    func run(_ segs: [RawSegment], _ taps: [PlacedTap]) -> [EarshotEvent] {
        let cl = Cleanup(dict: TestEnv.dict), rx = RulesExtractor(dict: TestEnv.dict)
        var f: [Finding] = []; var times: [String: (Int64, Int64)] = [:]
        for s in segs { f += rx.extract(cl.clean(s).0); times[s.id] = (s.startMs, s.endMs) }
        return merger.merge(findings: f, segments: times, taps: taps, gaps: [])
    }
    func tap(_ t: Int64) -> PlacedTap { PlacedTap(tMs: t, source: "button", gesture: "mark", clipMs: t) }

    func testTapPlusSpeechUsesTapTime() {
        let e = run([seg("324 of aspirin, chewed", start: 11000, end: 13000)], [tap(10000)])
        let m = e.first { $0.type == .medication }!
        XCTAssertEqual(m.source, .tapHeard); XCTAssertEqual(m.tMs, 10000); XCTAssertEqual(m.time, "2026-11-15T14:00:10-05:00")
        XCTAssertEqual(e.count, 1)
    }

    func testTapOnlyStaysUnlabeled() {
        let e = run([], [tap(5000)])
        XCTAssertEqual(e.count, 1); XCTAssertEqual(e[0].type, .tap); XCTAssertTrue(e[0].isUnlabeledTap)
    }

    func testSpeechOnlyIsHeard() {
        let e = run([seg("pushed 4 mg zofran IV", start: 20000, end: 22000)], [])
        XCTAssertEqual(e.first { $0.type == .medication }?.source, .heard)
    }

    func testTwoTapsCloseTogetherStaySeparate() {
        let e = run([seg("gave 4 mg zofran IV", start: 30000, end: 32000)], [tap(30000), tap(30500)])
        XCTAssertEqual(e.filter { $0.type == .medication }.count, 1)
        XCTAssertEqual(e.filter { $0.isUnlabeledTap }.count, 1, "second tap is never merged and never guessed")
    }

    func testExtendedWindowForward() {
        let e = run([seg("nitro 0.4 sublingual", start: 48000, end: 50000)], [tap(40000)])
        XCTAssertEqual(e.first { $0.type == .medication }?.source, .tapHeard)
        let far = run([seg("nitro 0.4 sublingual", start: 52000, end: 54000)], [tap(40000)])
        XCTAssertEqual(far.first { $0.type == .medication }?.source, .heard)
    }

    func testConsentArrivalHandoffWallTime() {
        let taps = [PlacedTap(tMs: 0, source: "button", gesture: "yes", clipMs: 0),
                    PlacedTap(tMs: 60000, source: "tablet", gesture: "arrival", clipMs: 60000),
                    PlacedTap(tMs: 60000 + 1_200_000, source: "tablet", gesture: "handoff", clipMs: 0)]
        let e = run([], taps)
        let m = ChartModel(events: e, callId: "c1", clock: TestEnv.clock)
        XCTAssertEqual(m.consent?.fields["consent"], "yes")
        XCTAssertEqual(m.wallTimeMs, 1_200_000)
    }

    func testPipelineOnPacketsWithGapAndScriptedASR() throws {
        let pcm = burstPCM(seconds: 8, bursts: [(1, 2.5), (5, 6.5)])
        var packets = ReplayFile.packets(fromPCM: pcm, taps: [TapInput(clipMs: 1000 + 5200, source: "button")], startClipMs: 1000)
        if let i = packets.firstIndex(where: { if case .audio(let h, _) = $0 { return h.seq == 300 }; return false }) { packets.remove(at: i) }
        let asr = ScriptedTranscriber(["BP 120 over 80, pulse 88.", "gave 4 milligrams zofran IV"])
        let r = try EarshotPipeline(dict: TestEnv.dict, config: PipelineConfig(), transcriber: asr).run(.packets(packets, extraTaps: []))
        XCTAssertEqual(r.raw.segments.count, 2)
        XCTAssertEqual(r.events.filter { $0.type == .audioGap }.count, 1)
        let med = r.events.first { $0.type == .medication }!
        XCTAssertEqual(med.source, .tapHeard); XCTAssertEqual(med.tapSource, "button")
        XCTAssertEqual(r.docs.map(\.name), ["soap.md", "chart.md", "imist_ambo.md", "nemsis.xml"])
    }
}
