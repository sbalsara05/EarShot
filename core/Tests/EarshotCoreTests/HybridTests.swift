import XCTest
@testable import EarshotCore

/// The hybrid: Apple's live text cross-checks Whisper, and the language model is held to the transcript.
final class HybridTests: XCTestCase {
    let cc = CrossCheck(dict: TestEnv.dict)
    let g = Grounding(dict: TestEnv.dict)
    let models = ModelInfo(asr: "t", extract: "t")

    func ev(_ type: EventType, _ fields: [String: String], at t: Int64 = 10_000) -> EarshotEvent {
        EarshotEvent(id: "e1", callId: "c", time: "", tMs: t, type: type, fields: fields, source: .heard, quote: "q", rawSpan: "s1",
                     confidence: 0.9, models: models)
    }

    // MARK: cross-check

    func testAgreementAcrossNumberStyles() {
        let out = cc.apply([ev(.vitals, ["bp_systolic": "120", "bp_diastolic": "80", "heart_rate": "88"])],
                           live: [LiveLine(id: "l1", startMs: 9_000, endMs: 12_000, text: "BP one twenty over eighty, pulse eighty eight")])
        XCTAssertEqual(out[0].crossCheck?.result, "agree")
        XCTAssertFalse(out[0].needsConfirm)
    }

    func testDoseDisagreementAsksToConfirm() {
        let out = cc.apply([ev(.medication, ["drug": "ondansetron", "dose": "4", "unit": "mg"])],
                           live: [LiveLine(id: "l1", startMs: 9_500, endMs: 11_000, text: "gave 40 milligrams of Zofran IV")])
        XCTAssertEqual(out[0].crossCheck?.result, "disagree")
        XCTAssertEqual(out[0].crossCheck?.mismatches, ["dose: 4 vs 40"])
        XCTAssertTrue(out[0].needsConfirm)
    }

    func testDrugDisagreementAsksToConfirm() {
        let out = cc.apply([ev(.medication, ["drug": "ondansetron", "dose": "4"])],
                           live: [LiveLine(id: "l1", startMs: 9_500, endMs: 11_000, text: "4 milligrams of naloxone")])
        XCTAssertEqual(out[0].crossCheck?.result, "disagree")
        XCTAssertTrue(out[0].crossCheck?.mismatches?.first?.hasPrefix("drug: ondansetron") ?? false)
    }

    func testBrandNameAgreesWithGeneric() {
        let out = cc.apply([ev(.medication, ["drug": "ondansetron", "dose": "4"])],
                           live: [LiveLine(id: "l1", startMs: 9_500, endMs: 11_000, text: "4 milligrams Zofran")])
        XCTAssertEqual(out[0].crossCheck?.result, "agree")
    }

    func testNoLiveTextNearbyIsNotAFlag() {
        let out = cc.apply([ev(.vitals, ["heart_rate": "88"])], live: [LiveLine(id: "l1", startMs: 60_000, endMs: 61_000, text: "pulse 120")])
        XCTAssertEqual(out[0].crossCheck?.result, "no_live_text")
        XCTAssertFalse(out[0].needsConfirm)
    }

    func testMedicEntriesAndOtherTypesAreLeftAlone() {
        var medic = ev(.vitals, ["heart_rate": "88"]); medic.source = .tablet; medic.enteredBy = "medic"
        let out = cc.apply([medic, ev(.procedure, ["procedure": "IV access"])], live: [LiveLine(id: "l1", startMs: 9_000, endMs: 11_000, text: "pulse 120")])
        XCTAssertNil(out[0].crossCheck); XCTAssertNil(out[1].crossCheck)
    }

    func testLiveSessionCrossChecksAndRenders() {
        let s = LiveSession(dict: TestEnv.dict, config: PipelineConfig(), callId: "c1", startEpochMs: 0, tzOffsetSeconds: 0,
                            transcriber: ScriptedTranscriber(["gave 4 milligrams zofran IV"]))
        s.callbackQueue = DispatchQueue(label: "cb")
        let dec = PCMFrameDecoder()
        s.handle(.consent(granted: true, source: "button", clipMs: 0), decoder: dec, receivedAt: Date(timeIntervalSince1970: 0))
        let pcm = burstPCM(seconds: 3, bursts: [(0.5, 2)])
        for i in 0..<(pcm.count / 320) {
            s.handle(.audio(ClipAudioFrame(seq: UInt32(i), clipMs: UInt32(i * 20), payload: PCMFrameDecoder.encode(Array(pcm[(i * 320)..<((i + 1) * 320)])))), decoder: dec)
        }
        s.handle(.consent(granted: false, source: "button", clipMs: 3_000), decoder: dec)
        s.liveLine(id: "L1", text: "gave 40 milligrams Zofran IV", start: Date(timeIntervalSince1970: 0.4), end: Date(timeIntervalSince1970: 2.1))
        s.drain()
        let med = s.events.first { $0.type == .medication }
        XCTAssertEqual(med?.crossCheck?.result, "disagree")
        XCTAssertTrue(med?.needsConfirm ?? false)
        XCTAssertTrue(s.render().contains { $0.text.lowercased().contains("confirm") })
        // the live line is display only: the record (raw transcript) is Whisper's
        XCTAssertEqual(s.rawSegments.map(\.text), ["gave 4 milligrams zofran IV"])
    }

    // MARK: grounding

    let transcript = [RawSegment(id: "s1", startMs: 0, endMs: 4000, text: "Resps are about twenty two and shallow."),
                      RawSegment(id: "s2", startMs: 5000, endMs: 9000, text: "She says she's allergic to penicillin.")]

    func testSuggestionWithRealQuoteIsAccepted() {
        let r = g.check(AISuggestion(field: "resp_rate", value: "22", quote: "resps are about twenty two"), transcript: transcript, events: [])
        XCTAssertTrue(r.accepted, r.reason ?? ""); XCTAssertEqual(r.segmentId, "s1")
        XCTAssertTrue(g.check(AISuggestion(field: "allergy", value: "penicillin", quote: "allergic to penicillin"), transcript: transcript, events: []).accepted)
    }

    func testInventedQuoteOrValueIsRejected() {
        XCTAssertEqual(g.check(AISuggestion(field: "resp_rate", value: "22", quote: "respiratory rate 22"), transcript: transcript, events: []).reason,
                       "quote is not in the transcript")
        XCTAssertEqual(g.check(AISuggestion(field: "resp_rate", value: "24", quote: "resps are about twenty two"), transcript: transcript, events: []).reason,
                       "24 is not in the quote")
        XCTAssertFalse(g.check(AISuggestion(field: "allergy", value: "sulfa", quote: "allergic to penicillin"), transcript: transcript, events: []).accepted)
        XCTAssertFalse(g.check(AISuggestion(field: "drug", value: "aspirin", quote: "allergic to penicillin"), transcript: transcript, events: []).accepted,
                       "medications are not suggestable")
    }

    func testSuggestionAlreadyInRecordIsRejected() {
        let r = g.check(AISuggestion(field: "resp_rate", value: "22", quote: "resps are about twenty two"), transcript: transcript,
                        events: [ev(.vitals, ["resp_rate": "22"])])
        XCTAssertEqual(r.reason, "already in the record")
    }

    func testNarrativeDropsSentencesWithUnheardNumbersOrDrugs() {
        let clock = CallClock(startEpochMs: 1_763_233_200_000, tzOffsetSeconds: 0)   // 19:00:00
        let events = [ev(.vitals, ["bp_systolic": "142", "bp_diastolic": "88"], at: 300_000),
                      ev(.medication, ["drug": "aspirin", "dose": "324", "unit": "mg"], at: 480_000)]
        let text = "Patient found sitting upright. BP 142/88 at 19:05. Aspirin 324 mg given at 19:08. Nitroglycerin 0.4 mg given. Heart rate 110."
        let (kept, dropped) = g.checkNarrative(text, events: events, clock: clock)
        XCTAssertEqual(kept, "Patient found sitting upright. BP 142/88 at 19:05. Aspirin 324 mg given at 19:08.")
        XCTAssertEqual(dropped, ["Nitroglycerin 0.4 mg given.", "Heart rate 110."])
    }

    func testLiveSessionAcceptsGroundedSuggestionsAsConfirm() {
        let s = LiveSession(dict: TestEnv.dict, config: PipelineConfig(), callId: "c1", startEpochMs: 0, tzOffsetSeconds: 0,
                            transcriber: ScriptedTranscriber(["Resps are about twenty two and shallow."]))
        s.callbackQueue = DispatchQueue(label: "cb")
        let dec = PCMFrameDecoder()
        s.handle(.consent(granted: true, source: "button", clipMs: 0), decoder: dec, receivedAt: Date(timeIntervalSince1970: 0))
        let pcm = burstPCM(seconds: 3, bursts: [(0.5, 2)])
        for i in 0..<(pcm.count / 320) {
            s.handle(.audio(ClipAudioFrame(seq: UInt32(i), clipMs: UInt32(i * 20), payload: PCMFrameDecoder.encode(Array(pcm[(i * 320)..<((i + 1) * 320)])))), decoder: dec)
        }
        s.handle(.consent(granted: false, source: "button", clipMs: 3_000), decoder: dec)
        s.drain()
        // "Resps are about ..." is a phrasing the rules miss today: the gap the model is there to fill
        XCTAssertNil(s.events.first { $0.fields["resp_rate"] != nil })
        let results = s.addSuggestions([AISuggestion(field: "resp_rate", value: "22", quote: "about twenty two"),
                                        AISuggestion(field: "heart_rate", value: "130", quote: "pulse 130")])
        s.drain()
        XCTAssertTrue(results[0].accepted, results[0].reason ?? "")
        let e = s.events.first { $0.flags?.contains("ai_suggested") ?? false }
        XCTAssertEqual(e?.fields["resp_rate"], "22"); XCTAssertTrue(e?.needsConfirm ?? false)
        XCTAssertFalse(results[1].accepted, "a value with no quote in the transcript never enters the record")
        XCTAssertEqual(s.addSuggestions([AISuggestion(field: "resp_rate", value: "22", quote: "about twenty two")]).first?.reason,
                       "already in the record")
    }
}
