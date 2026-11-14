import XCTest
@testable import EarshotCore

/// Step 1 of smoothing (docs/HYBRID.md): fixes that need no guessing. Both bugs were found by
/// core/scripts/e2e_firmware.sh, playing the clip's built-in voice through the live path.
final class SmoothingTests: XCTestCase {
    func med(_ text: String) -> Finding? { extract(text).first { $0.type == .medication } }

    // MARK: a clock time is never a dose

    func testClockTimeAfterAtIsNotADose() {
        for t in ["Aspirin given at 1410.", "Aspirin given at fourteen ten.", "Aspirin given at 14:10.",
                  "Aspirin given at 1410 hours.", "Aspirin given at fourteen hundred."] {
            let m = med(t)
            XCTAssertEqual(m?.fields["drug"], "aspirin", t)
            XCTAssertNil(m?.fields["dose"], "\(t) -> dose \(m?.fields["dose"] ?? "")")
        }
    }

    func testRealDosesNextToATimeSurvive() {
        XCTAssertEqual(med("aspirin 324 at 1410")?.fields["dose"], "324")
        XCTAssertEqual(med("aspirin 324 milligrams chewed at fourteen ten")?.fields["dose"], "324")
        let z = med("gave 4 milligrams of zofran IV at fourteen ten")
        XCTAssertEqual(z?.fields["drug"], "ondansetron"); XCTAssertEqual(z?.fields["dose"], "4")
    }

    func testCleanupLogsTheTimeAgainstTheRawWords() {
        let (c, corr) = Cleanup(dict: TestEnv.dict).clean(seg("Aspirin given at fourteen ten."))
        XCTAssertTrue(c.text.hasSuffix("at 14:10"), c.text)
        let t = corr.first { $0.rule == "time:clock" }
        XCTAssertEqual(t?.original, "fourteen ten.")
        XCTAssertEqual(t?.replacement, "14:10")
    }

    func testNotATime() {
        // a unit follows: an amount, not a time
        XCTAssertFalse(Cleanup(dict: TestEnv.dict).clean(seg("normal saline at 1000 ml")).0.text.contains(":"))
        // impossible clock values stay numbers
        XCTAssertFalse(Cleanup(dict: TestEnv.dict).clean(seg("at 2575")).0.text.contains(":"))
        XCTAssertFalse(Cleanup(dict: TestEnv.dict).clean(seg("at 1410")).0.text.contains("14 10"))
    }

    func testTimeRulesStillReadNormalizedTimes() {
        let terms = extract("last known well at fourteen ten").compactMap { $0.fields["term"] }
        XCTAssertTrue(terms.contains("last known well 14:10"), "\(terms)")
        let tq = extract("tourniquet on at 1410").compactMap { $0.fields["term"] }
        XCTAssertTrue(tq.contains("tourniquet time 14:10"), "\(tq)")
    }

    // MARK: a reading split across Whisper segments

    /// What whisper.cpp base.en returned for the clip's test voice: one VAD chunk, two segments.
    let split = [ASRPiece(startMs: 0, endMs: 7260, text: " 68-year-old male with chest pain for 30 minutes, radiating to the left arm, blood pressure is 150 over",
                          tokens: [ASRToken(charOffset: 0, startMs: 0, endMs: 300), ASRToken(charOffset: 90, startMs: 6000, endMs: 6500)]),
                 ASRPiece(startMs: 7260, endMs: 11520, text: " 90, heart rate is 104, Aspirin given at 1410.",
                          tokens: [ASRToken(charOffset: 0, startMs: 7260, endMs: 7500), ASRToken(charOffset: 24, startMs: 9000, endMs: 9200)])]

    func testJoinUnfinishedKeepsWhispersTextAndTimes() {
        let j = ASRPiece.joinUnfinished(split)
        XCTAssertEqual(j.count, 1)
        XCTAssertEqual(j[0].text, split[0].text + split[1].text, "Whisper's words, unchanged and in order")
        XCTAssertEqual(j[0].startMs, 0); XCTAssertEqual(j[0].endMs, 11520)
        XCTAssertEqual(j[0].tokens.map(\.charOffset), [0, 90, split[0].text.count, split[0].text.count + 24])
        let seg = j[0].rawSegment(id: "s1", chunkStartMs: 1000, chunkEndMs: 13000)!
        XCTAssertEqual(seg.wordTimes?.last, [Int64(split[0].text.count + 24 - 1), 10_000])
    }

    func testJoinStopsAtSentenceEndsAndDropsHallucinations() {
        let a = ASRPiece(startMs: 0, endMs: 1000, text: " Pulse 88.")
        let b = ASRPiece(startMs: 1000, endMs: 2000, text: " ♪♪♪")
        let c = ASRPiece(startMs: 2000, endMs: 3000, text: " BP 120 over")
        let d = ASRPiece(startMs: 3000, endMs: 4000, text: " 80?")
        let e = ASRPiece(startMs: 4000, endMs: 5000, text: " Sats 98")
        XCTAssertEqual(ASRPiece.joinUnfinished([a, b, c, d, e]).map(\.text), [" Pulse 88.", " BP 120 over 80?", " Sats 98"])
    }

    func testSplitBloodPressureIsReadInTheLivePath() {
        let s = LiveSession(dict: TestEnv.dict, config: PipelineConfig(), callId: "c1", startEpochMs: 0, tzOffsetSeconds: 0,
                            transcriber: SplitTranscriber(split))
        s.callbackQueue = DispatchQueue(label: "cb")
        let dec = PCMFrameDecoder()
        s.handle(.consent(granted: true, source: "button", clipMs: 0), decoder: dec, receivedAt: Date(timeIntervalSince1970: 0))
        let pcm = burstPCM(seconds: 14, bursts: [(1, 12.5)])
        for i in 0..<(pcm.count / 320) {
            s.handleDecodedAudio(seq: UInt32(i), clipMs: UInt32(i * 20), pcm: Array(pcm[(i * 320)..<((i + 1) * 320)]))
        }
        s.handle(.consent(granted: false, source: "button", clipMs: 14_000), decoder: dec)
        s.drain()
        XCTAssertEqual(s.rawSegments.count, 1)
        let bp = s.events.first { $0.fields["bp_systolic"] != nil }
        XCTAssertEqual(bp?.fields["bp_systolic"], "150"); XCTAssertEqual(bp?.fields["bp_diastolic"], "90")
        XCTAssertTrue(s.events.contains { $0.fields["heart_rate"] == "104" })
        let asa = s.events.first { $0.type == .medication }
        XCTAssertEqual(asa?.fields["drug"], "aspirin"); XCTAssertNil(asa?.fields["dose"])
    }
}

/// Returns fixed pieces for the first chunk (as whisper.cpp did), nothing after.
final class SplitTranscriber: Transcriber {
    var pieces: [ASRPiece]?
    let modelName = "split"
    init(_ p: [ASRPiece]) { pieces = p }
    func transcribe(_ pcm: [Float], prompt: String?) throws -> [ASRPiece] { defer { pieces = nil }; return pieces ?? [] }
}
