import XCTest
@testable import EarshotCore

/// One test per finding in docs/REVIEW.md (data agent), named by its id.
final class ReviewRegressionTests: XCTestCase {
    func meds(_ t: String) -> [Finding] { extract(t).filter { $0.type == .medication } }
    func all(_ t: String) -> [Finding] { extract(t) }

    func runDocs(_ lines: [String], taps: [TapInput] = []) throws -> PipelineResult {
        let raw = RawTranscript(callId: "c01", asrModel: "t", segments: lines.enumerated().map {
            RawSegment(id: "s\($0 + 1)", startMs: Int64($0) * 5000, endMs: Int64($0) * 5000 + 4000, text: $1) })
        var cfg = PipelineConfig(); cfg.startTime = "2026-11-15T14:00:00-05:00"; cfg.callId = "c01"
        return try EarshotPipeline(dict: TestEnv.dict, config: cfg, transcriber: nil).run(.transcript(raw, taps: taps))
    }

    func test_C1_spokenDiagnosisNeverBecomesAField() throws {
        let r = try runDocs(["Looks like a STEMI.", "This is actually a STEMI.", "It turned out to be anaphylaxis.",
                             "Call a stroke alert, cath lab activated.", "Twelve lead shows ST elevation."])
        for d in r.docs where d.name.hasSuffix(".md") {
            let body = d.text.components(separatedBy: "\n---")[0].lowercased()
            for w in ["stemi", "anaphylaxis", "stroke", "st elevation"] { XCTAssertFalse(body.contains(w), "\(d.name) contains \(w)") }
        }
        XCTAssertFalse(r.events.contains { $0.fields.values.contains { Diagnosis.contains($0) } })
    }

    func test_C2_wordsThatAreNotDrugs() {
        XCTAssertTrue(meds("Medic 14, respond priority one to 42 Elm Street").isEmpty)
        XCTAssertTrue(meds("Medic 14 on scene").isEmpty)
        XCTAssertTrue(meds("This sucks, give me 2 seconds").isEmpty)
        XCTAssertTrue(meds("the rhythm is morphing").isEmpty)
        let z = meds("gave 4 milligrams of so fran IV").first!
        XCTAssertEqual(z.fields["drug"], "ondansetron"); XCTAssertTrue(z.flags.contains("confirm")); XCTAssertNotNil(z.fields["drug_as_heard"])
    }

    func test_C3_vadKeepsSpeechInSteadyNoise() {
        // speech bursts 6 dB above loud steady noise: the adaptive floor must still split them
        var pcm = [Int16](repeating: 0, count: 16000 * 20)
        var seed: UInt32 = 3
        for i in pcm.indices { seed = seed &* 1664525 &+ 1013904223; pcm[i] = Int16(Int(seed >> 20) - 2048) }   // ~1200 rms noise
        for (a, b) in [(2.0, 4.0), (8.0, 10.5), (14.0, 15.5)] {
            for i in Int(a * 16000)..<Int(b * 16000) { pcm[i] = pcm[i] &+ Int16(4000 * sin(Double(i) * 2 * .pi * 180 / 16000)) }
        }
        let v = EnergyVAD(); let c = v.push(pcm) + v.finish()
        XCTAssertEqual(c.count, 3, "\(c.map { ($0.startMs, $0.endMs) })")
    }

    func test_C4_noAllergiesGaveAspirin() {
        let f = all("No allergies, gave aspirin 324.")
        XCTAssertFalse(f.contains { $0.fields["kind"] == "allergy" && $0.fields["allergy"] == "aspirin" })
        XCTAssertEqual(meds("No allergies, gave aspirin 324.").first?.fields["dose"], "324")
        XCTAssertEqual(all("allergic to aspirin").first { $0.fields["kind"] == "allergy" }?.fields["allergy"], "aspirin")
    }

    func test_C5_respRateIsNotHeartRate() {
        let v = all("Respiratory rate 24.").first { $0.type == .vitals }!
        XCTAssertEqual(v.fields["resp_rate"], "24"); XCTAssertNil(v.fields["heart_rate"])
        XCTAssertNil(all("drip rate of 125").first { $0.type == .vitals }?.fields["heart_rate"])
    }

    func test_C6_unspokenUnitStaysBlank() {
        let a = meds("Giving 324 of aspirin, chewed").first!
        XCTAssertNil(a.fields["unit"]); XCTAssertEqual(a.fields["unit_suggested"], "mg"); XCTAssertEqual(a.fields["route_as_heard"], "chewed")
    }

    func test_H2_commaIsAClauseBoundary() {
        let f = all("Denies nausea, has chest pain.")
        XCTAssertEqual(f.first { $0.fields["symptom"] == "chest pain" }?.fields["negated"], nil)
        XCTAssertEqual(f.first { $0.fields["symptom"] == "nausea" }?.fields["negated"], "true")
    }

    func test_H3_negationAfterTheDrug() {
        XCTAssertTrue(meds("Nitro 0.4 held, pressure 88/60").isEmpty)
        XCTAssertEqual(all("Nitro 0.4 held, pressure 88/60").first { $0.fields["drug"] == "nitroglycerin" }?.fields["kind"], "med_not_given")
        XCTAssertEqual(meds("Pain's not better, gave fentanyl 50").first?.fields["dose"], "50")
    }

    func test_H4_cueBoundToDrug() {
        XCTAssertEqual(meds("Took her pressure, gave nitro 0.4").count, 1)
    }

    func test_H5_tapLabelUsesWordTimeAndGlobalAssignment() {
        let merger = TapMerger(callId: "c", clock: TestEnv.clock, models: ModelInfo(asr: "t", extract: "r"))
        let s = seg("BP 158/94, pulse 104, sats 95. Gave aspirin 324 chewed.", start: 0, end: 10000)
        let f = RulesExtractor(dict: TestEnv.dict).extract(Cleanup(dict: TestEnv.dict).clean(s).0)
        let e = merger.merge(findings: f, segments: ["s1": (0, 10000)], taps: [PlacedTap(tMs: 500, source: "button", gesture: "mark", clipMs: 500)], gaps: [])
        XCTAssertEqual(e.first { $0.source == .tapHeard }?.type, .vitals)
    }

    func test_H6_radioDispatchAndArrival() throws {
        let r = try runDocs(["Medic 14, respond priority one to 42 Elm for a sixty two year old male, chest pain.", "Arrived at Mercy."])
        let m = ChartModel(events: r.events, callId: "c01", clock: TestEnv.clock)
        XCTAssertEqual(m.dispatch?.text, "chest pain")
        XCTAssertNotNil(m.arrival)
    }

    func test_H7_tagsStrippedNotWholeSegment() {
        XCTAssertFalse(ASRFilter.isHallucination("(siren) pressure is 158 over 94 (beeping)"))
        XCTAssertTrue(ASRFilter.isHallucination("[beep] [clap]"))
        let c = Cleanup(dict: TestEnv.dict).clean(seg("(siren) pressure is 158 over 94 (beeping)")).0
        XCTAssertFalse(c.text.contains("siren")); XCTAssertFalse(c.text.contains("beeping"))
    }

    func test_H8_M6_stopAndRefusalLimitCapture() throws {
        let lines = ["BP 120 over 80.", "gave 4 milligrams zofran IV.", "pulse 90."]
        let stop = try runDocs(lines, taps: [TapInput(clipMs: 0, source: "button", gesture: "yes"), TapInput(clipMs: 6000, source: "button", gesture: "stop")])
        XCTAssertEqual(stop.raw.segments.count, 2, "nothing after stop")
        let no = try runDocs(lines, taps: [TapInput(clipMs: 0, source: "button", gesture: "no")])
        XCTAssertTrue(no.raw.segments.isEmpty, "a refusal captures nothing")
        XCTAssertEqual(no.events.map(\.type), [.consent])
    }

    func test_H9_notDoneIsRendered() throws {
        let r = try runDocs(["No IV access."])
        XCTAssertTrue(r.docs[0].text.contains("Not done"))
    }

    func test_H10_historyNeedsACue() {
        XCTAssertFalse(all("Rule out CVA").contains { $0.fields["kind"] == "history" })
        XCTAssertEqual(all("History of CHF.").first { $0.fields["kind"] == "history" }?.fields["history"], "CHF")
    }

    func test_H11_gramsAreNotGauge() {
        XCTAssertFalse(all("D50 25 g IV").contains { $0.type == .procedure })
        XCTAssertEqual(all("20 gauge in the right hand").first { $0.type == .procedure }?.fields["gauge"], "20")
    }

    func test_M1_doseStaysInSentence() {
        XCTAssertNil(meds("Gave aspirin. She's 81 years old.").first?.fields["dose"])
        XCTAssertNil(meds("Gave nitro times 2").first?.fields["dose"])
    }

    func test_M2_M3_destinationAndArrivalMustBePlaces() {
        XCTAssertFalse(all("We're going to start a line").contains { $0.type == .transport })
        XCTAssertFalse(all("Sats, we're at 92").contains { $0.fields["kind"] == "arrived_heard" })
        XCTAssertEqual(all("Transporting to Mass General").first { $0.type == .transport }?.fields["destination"], "Mass General")
    }

    func test_M4_contractionsKept() {
        XCTAssertEqual(all("she's on metoprolol").first { $0.fields["drug"] == "metoprolol" }?.fields["kind"], "home_med")
        XCTAssertEqual(all("it's actually a fall").first { $0.type == .dispatch }?.fields["found"], "fall")
    }

    func test_M5_repeatedVitalsKept() {
        let v = all("BP 120/80, then repeat BP 110/70").filter { $0.type == .vitals }
        XCTAssertEqual(v.compactMap { $0.fields["bp_systolic"] }, ["120", "110"])
    }

    func test_M7_assumedClockIsFlagged() throws {
        let raw = RawTranscript(callId: "c", asrModel: "t", segments: [RawSegment(id: "s1", startMs: 0, endMs: 1000, text: "pulse 80")])
        let r = try EarshotPipeline(dict: TestEnv.dict, config: PipelineConfig(), transcriber: nil).run(.transcript(raw, taps: []))
        XCTAssertTrue(r.docs[0].text.hasPrefix("> Clock: no start time given"))
        XCTAssertTrue(r.notes.contains("clock: assumed"))
    }

    func test_M10_glucoseVitalIsNotADrug() {
        XCTAssertFalse(all("glucose is 54").contains { $0.fields["drug"] != nil })
    }

    func test_Low_aLiterAndMonths() {
        XCTAssertEqual(meds("hung a liter of saline").first?.fields["dose"], "1")
        XCTAssertEqual(all("18 month old").first { $0.fields["kind"] == "patient" }?.fields["age_units"], "months")
        XCTAssertNil(all("0 year old").first { $0.fields["kind"] == "patient" })
    }
}

final class FormularyAdditionsTests: XCTestCase {
    func testHomeMedsOnlyInContext() {
        XCTAssertEqual(extract("She takes lisinopril and Eliquis.").filter { $0.fields["kind"] == "home_med" }.compactMap { $0.fields["drug"] }, ["lisinopril", "eliquis"])
        XCTAssertTrue(extract("lisinopril").isEmpty)
    }
    func testRiskyObservedVariantsNotAdded() {
        let fent = TestEnv.dict.drug(named: "fentanyl")!
        XCTAssertFalse(fent.asr_variants.contains("now"))
        XCTAssertFalse(TestEnv.dict.drug(named: "metoprolol")!.asr_variants.contains("officer"))
        XCTAssertNotNil(TestEnv.dict.drug(named: "furosemide"))
    }
}

/// Round 2: misses found by scoring against the data agent's ground truth (test + dev calls).
final class GroundTruthRound2Tests: XCTestCase {
    func v(_ t: String) -> [String: String] { extract(t).filter { $0.type == .vitals }.reduce(into: [:]) { $0.merge($1.fields) { a, _ in a } } }
    func meds(_ t: String) -> [Finding] { extract(t).filter { $0.type == .medication } }
    func procs(_ t: String) -> [String] { extract(t).filter { $0.type == .procedure }.compactMap { $0.fields["procedure"] } }

    func testHeartRateForms() {
        XCTAssertEqual(v("Recheck, 104 over 66, rate 132.")["heart_rate"], "132")
        XCTAssertEqual(v("rate's 140")["heart_rate"], "140")
        XCTAssertEqual(v("Sat's coming up, 95.")["spo2"], "95")
        XCTAssertEqual(v("He's breathing, rate 14 now, sat 96.")["resp_rate"], "14")
        XCTAssertNil(v("drip rate of 125")["heart_rate"])
    }
    func testRoutes() {
        XCTAssertEqual(meds("Narcan 4 milligrams intranasal").first?.fields["route"], "IN")
        XCTAssertEqual(meds("0.3 ket through the line").first?.fields["route"], "IV")
        XCTAssertEqual(meds("Starting a DuoNeb, albuterol 2.5 and ipratropium 0.5 by nebulizer.").first { $0.fields["drug"] == "albuterol" }?.fields["route"], "NEB")
        XCTAssertEqual(meds("Second albuterol, 5 milligrams, neb.").first?.fields["route"], "NEB")
        let o2 = meds("Non-rebreather at 15 liters.").first!
        XCTAssertEqual(o2.fields["drug"], "oxygen"); XCTAssertEqual(o2.fields["route"], "NRB"); XCTAssertEqual(o2.fields["dose"], "15")
        XCTAssertEqual(meds("10 Valium rectal").first?.fields["dose"], "10")
    }
    func testProceduresAndFindings() {
        XCTAssertEqual(procs("Eighteen in the left AC."), ["IV access"])
        XCTAssertEqual(procs("Start bagging him."), ["BVM ventilation"])
        XCTAssertEqual(procs("Patient signed refusal against medical advice."), ["refusal"])
        XCTAssertEqual(procs("Traction splint, then load."), ["splinting"])
        XCTAssertEqual(procs("Tourniquet time oh two thirty four."), [])
        let f = extract("Tourniquet time oh two thirty four. Last known well sixteen fifteen. Pale, cool and diaphoretic.")
            .filter { $0.fields["kind"] == "finding" }.compactMap { $0.fields["term"] }
        XCTAssertEqual(Set(f), ["tourniquet time 02:34", "last known well 16:15", "pale, cool and diaphoretic"])
        XCTAssertFalse(procs("BE-FAST positive").joined().lowercased().contains("stroke"), "procedure names never carry a diagnosis word")
    }
    func testHeardTimesAtUtteranceStart() {
        let f = RulesExtractor(dict: TestEnv.dict).extract(Cleanup(dict: TestEnv.dict).clean(seg("Medic 14 on scene.", start: 9430, end: 10790)).0)
        XCTAssertEqual(f.first { $0.fields["kind"] == "on_scene" }?.tMs, 9430)
        XCTAssertNotNil(extract("We're here.").first { $0.fields["kind"] == "arrived_heard" })
        XCTAssertNotNil(extract("At the trauma center.").first { $0.fields["kind"] == "arrived_heard" })
        XCTAssertNotNil(extract("Transfer of care complete.").first { $0.fields["kind"] == "handoff_heard" })
    }
    func testRhythmNamesNotExtracted() {
        XCTAssertNil(v("Heart rate's 148 and irregular, afib with RVR")["ecg"])
        XCTAssertEqual(v("Heart rate's 148 and irregular")["heart_rate"], "148")
    }
}

/// Round 3 (data agent ran earshot-eval on audio).
final class Round3Tests: XCTestCase {
    func drugs(_ t: String) -> [String] { extract(t).compactMap { $0.fields["drug"] } }

    func test_R3_1_noDrugWithoutADrugWord() {
        XCTAssertEqual(drugs("Nitro 0.4 sublingual is pressure holds."), ["nitroglycerin"])
        XCTAssertEqual(drugs("Zofran 4 IV, DOT arrived at Memorial,"), ["ondansetron"])
        XCTAssertEqual(drugs("Morphine 4 IM left deltide."), ["morphine"])
        XCTAssertEqual(drugs("Medic 4 back in service."), [])
        XCTAssertEqual(drugs("Memorial,"), [])
    }

    func test_R3_3_respRateAsrForms() {
        func rr(_ t: String) -> String? { extract(t).first { $0.type == .vitals }?.fields["resp_rate"] }
        XCTAssertEqual(rr("Sat 94 on the neb, resps 24."), "24")
        XCTAssertEqual(rr("heart rate 124, ress 24."), "24")
        XCTAssertEqual(rr("respS32,"), "32")
    }

    func test_R3_2_tokenTimesDriveFindingTimes() {
        // chunk starts at 93.78 s but speech starts at 108.0 s: segment and finding take the token time
        let p = ASRPiece(startMs: 0, endMs: 16270, text: " Got an 18 in the left AC.",
                         tokens: [ASRToken(charOffset: 1, startMs: 14220, endMs: 14400), ASRToken(charOffset: 8, startMs: 14600, endMs: 14800),
                                  ASRToken(charOffset: 14, startMs: 15000, endMs: 15200)])
        let seg = p.rawSegment(id: "s15", chunkStartMs: 93780, chunkEndMs: 110050)!
        XCTAssertEqual(seg.startMs, 108000)
        let f = RulesExtractor(dict: TestEnv.dict).extract(Cleanup(dict: TestEnv.dict).clean(seg).0)
        let iv = f.first { $0.type == .procedure }!
        XCTAssertGreaterThanOrEqual(iv.tMs, 108000)
        // an unlabelled tap at 95.0 s must stay unlabelled (no speech within -3/+10 s)
        let e = TapMerger(callId: "c", clock: TestEnv.clock, models: ModelInfo(asr: "t", extract: "r"))
            .merge(findings: f, segments: ["s15": (seg.startMs, seg.endMs)], taps: [PlacedTap(tMs: 95000, source: "button", gesture: "mark", clipMs: 95000)], gaps: [])
        XCTAssertTrue(e.contains { $0.isUnlabeledTap })
    }

    /// Format-only prompt: if Whisper copied the prompt verbatim, no vital or dose could come out of it.
    func testPromptValuesCannotBecomeFields() {
        let f = extract(TestEnv.dict.initialPrompt())
        XCTAssertTrue(f.filter { $0.type == .vitals }.allSatisfy { v in !v.fields.keys.contains { ["bp_systolic", "heart_rate", "resp_rate", "spo2", "glucose", "etco2", "gcs"].contains($0) } },
                      "\(f.filter { $0.type == .vitals }.map(\.fields))")
        XCTAssertTrue(f.filter { $0.type == .medication }.allSatisfy { $0.fields["dose"] == nil })
    }

    func test_R3_5_sentencePromptIsDefault() {
        XCTAssertTrue(TestEnv.dict.initialPrompt().hasPrefix("EMS call."))
    }
}

/// Round 4 (data agent re-ran on audio @ 5f434ae).
final class Round4Tests: XCTestCase {
    func spo2(_ t: String) -> [String] { extract(t).filter { $0.type == .vitals }.compactMap { $0.fields["spo2"] } }

    func test_R4_1_setHeardForSat() {
        XCTAssertEqual(spo2("Set 96."), ["96"])
        XCTAssertEqual(spo2("heart rate 124, ress 24, set 97."), ["97"])
        XCTAssertEqual(spo2("SAC's coming up, 95."), ["95"])
        XCTAssertEqual(spo2("Pulse 104, set 95 when we're in air."), ["95"])
        XCTAssertEqual(spo2("We need to set 30 minutes aside."), [], "'set' only reads as sats where a sat reading belongs")
        XCTAssertEqual(spo2("I set 90 of them out."), [])
        XCTAssertTrue(TestEnv.dict.initialPrompt().contains("sats "))
    }

    func test_R4_2_musicNotesAreNotSpeech() {
        XCTAssertTrue(ASRFilter.isHallucination("♪♪♪♪"))
        XCTAssertTrue(ASRFilter.isHallucination(" 🎵 ♪ "))
        XCTAssertFalse(ASRFilter.isHallucination("♪ Second dose, 2 milligrams IV"))
        let c = Cleanup(dict: TestEnv.dict).clean(seg("♪ Second dose, 2 milligrams IV")).0
        XCTAssertFalse(c.text.contains("♪"))
    }

    func test_R4_3_spokenFormDrift() {
        let o2 = extract("Now we're breather at 15 liters.").first { $0.fields["drug"] == "oxygen" }
        XCTAssertEqual(o2?.fields["route"], "NRB"); XCTAssertEqual(o2?.fields["dose"], "15")
        XCTAssertEqual(extract("hung a leader of saline").first { $0.type == .medication }?.fields["dose"], "1")
        XCTAssertEqual(extract("oxygen 2 leaders nasal cannula").first { $0.fields["drug"] == "oxygen" }?.fields["dose"], "2")
    }
}

/// The Kaggle fine-tune trains with this exact prompt (read from shared/ems_terms.json on
/// this branch). Changing it breaks the train/inference match: coordinate with the data agent first.
final class PromptFreezeTests: XCTestCase {
    func testPromptIsFrozen() {
        XCTAssertEqual(TestEnv.dict.initialPrompt(), "EMS call. Patient A&O, GCS. BP 61/127, HR 913, resps 113, sats 113%, BGL 913, ETCO2 213. Aspirin mg PO, nitro mg SL, Narcan mg IN, D10, glucagon, albuterol, DuoNeb, epi mg IM, Benadryl, Solu-Medrol, Zofran mg IV, fentanyl mcg, Versed, Ativan, amiodarone, adenosine, TXA. 12-lead, STEMI, IV, IO, CPAP, BVM, c-collar.")
    }
}
