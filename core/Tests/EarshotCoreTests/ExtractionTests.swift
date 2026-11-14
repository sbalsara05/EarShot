import XCTest
@testable import EarshotCore

final class ExtractionTests: XCTestCase {
    func med(_ text: String) -> Finding? { extract(text).first { $0.type == .medication } }
    func vit(_ text: String) -> [String: String] { extract(text).first { $0.type == .vitals }?.fields ?? [:] }

    func testVitalsDigitsAndWords() {
        let v = vit("BP 158 over 92, heart rate 110, sats 94% on room air, resps 22.")
        XCTAssertEqual(v["bp_systolic"], "158"); XCTAssertEqual(v["bp_diastolic"], "92")
        XCTAssertEqual(v["heart_rate"], "110"); XCTAssertEqual(v["spo2"], "94"); XCTAssertEqual(v["resp_rate"], "22")
        XCTAssertEqual(v["o2_on"], "room air")
        let w = vit("B P one thirty eight over eighty four, pulse ninety six")
        XCTAssertEqual(w["bp_systolic"], "138"); XCTAssertEqual(w["bp_diastolic"], "84"); XCTAssertEqual(w["heart_rate"], "96")
    }

    func testVitalsMisrecognizedASR() {
        XCTAssertEqual(vit("s p o two ninety one")["spo2"], "91")
        XCTAssertEqual(vit("g c s fifteen, a and o times four, pearl")["gcs"], "15")
        XCTAssertEqual(vit("g c s fifteen, a and o times four, pearl")["mental_status"], "A&O×4")
        XCTAssertEqual(vit("g c s fifteen, a and o times four, pearl")["pupils"], "PERRL")
        XCTAssertEqual(vit("sugar is 54")["glucose"], "54")
        XCTAssertEqual(vit("e t c o 2 is 38")["etco2"], "38")
        XCTAssertEqual(vit("pressure 90 by palp")["bp_systolic"], "90")
    }

    func testImplausibleVitalsRejected() {
        XCTAssertNil(vit("heart rate 900")["heart_rate"])
        XCTAssertNil(vit("gcs 22")["gcs"])
    }

    func testDrugMisspellingsAndSlang() {
        XCTAssertEqual(med("gave 4 of so fran IV")?.fields["drug"], "ondansetron")
        XCTAssertEqual(med("4 milligrams zofren IV")?.fields["drug"], "ondansetron")
        XCTAssertEqual(med("4 milligrams of narcan intranasal")?.fields["drug"], "naloxone")
        XCTAssertEqual(med("pushed 1 milligram epi")?.fields["drug"], "epinephrine")
        XCTAssertEqual(med("amiodaron 300 milligrams IV push")?.fields["drug"], "amiodarone")
    }

    func testDoseUnitRouteParsing() {
        let m = med("Nitro point four milligrams sublingual")!
        XCTAssertEqual(m.fields["dose"], "0.4"); XCTAssertEqual(m.fields["unit"], "mg"); XCTAssertEqual(m.fields["route"], "SL")
        let f = med("fentanyl 50 mics IV")!
        XCTAssertEqual(f.fields["dose"], "50"); XCTAssertEqual(f.fields["unit"], "mcg"); XCTAssertEqual(f.fields["route"], "IV")
        let a = med("324 of aspirin, chewed")!
        XCTAssertEqual(a.fields["dose"], "324"); XCTAssertEqual(a.fields["route"], "PO")
        XCTAssertNil(a.fields["unit"], "unit was not spoken; must stay blank")
        XCTAssertEqual(a.fields["unit_suggested"], "mg")
        let d = med("D10 250 ml IV")!
        XCTAssertEqual(d.fields["drug"], "dextrose"); XCTAssertEqual(d.fields["dose"], "250"); XCTAssertEqual(d.fields["unit"], "ml")
    }

    func testEveryFieldHasReceipt() {
        let m = med("gave 4 milligrams of zofran IV")!
        for k in ["drug", "dose", "unit", "route"] {
            XCTAssertNotNil(m.receipts[k], k)
            XCTAssertTrue("gave 4 milligrams of zofran IV".contains(m.receipts[k]!.quote), "quote must be raw text")
        }
    }

    func testHomeMedsAllergiesNegationNotGiven() {
        let h = extract("She takes metoprolol daily").first { $0.fields["drug"] == "metoprolol" }!
        XCTAssertEqual(h.type, .status); XCTAssertEqual(h.fields["kind"], "home_med")
        let al = extract("allergic to morphine").first { $0.fields["kind"] == "allergy" }!
        XCTAssertEqual(al.fields["allergy"], "morphine")
        let n = extract("no nitro, he took viagra").first { $0.fields["drug"] == "nitroglycerin" }!
        XCTAssertEqual(n.fields["kind"], "med_not_given")
        XCTAssertNil(med("any questions about aspirin"), "a bare mention is not an administration")
    }

    func testContextRequiredAliases() {
        XCTAssertNil(med("she said her sugar was fine"))
        XCTAssertNil(med("that's epic"))
        XCTAssertEqual(med("give epi 0.3 IM")?.fields["drug"], "epinephrine")
    }

    func testProceduresStatusDispatchTransport() {
        let p = extract("18 gauge in the left A C").first { $0.type == .procedure }!
        XCTAssertEqual(p.fields["gauge"], "18"); XCTAssertEqual(p.fields["site"], "left AC")
        let s = extract("she's compensating").first { $0.type == .status }!
        XCTAssertEqual(s.fields["condition"], "compensating")
        let d = extract("We got called for a fall, but it turned out to be chest pain.").filter { $0.type == .dispatch }
        XCTAssertEqual(d.compactMap { $0.fields["dispatch_reason"] }, ["fall"])
        XCTAssertEqual(d.compactMap { $0.fields["found"] }, ["chest pain"])
        let t = extract("Transporting to Mass General, lights and sirens, E T A twelve minutes.").first { $0.type == .transport }!
        XCTAssertEqual(t.fields["destination"], "Mass General"); XCTAssertEqual(t.fields["eta_min"], "12")
    }

    func testCleanupCorrectionsLinkToRaw() {
        let (c, corr) = Cleanup(dict: TestEnv.dict).clean(seg("gave 4 mg of so fran [beep] IV"))
        XCTAssertTrue(c.text.contains("ondansetron"))
        XCTAssertFalse(c.text.contains("beep"))
        for k in corr { XCTAssertEqual(k.rawSpan, "s1"); XCTAssertEqual(Array("gave 4 mg of so fran [beep] IV")[k.rawRange[0]..<k.rawRange[1]].count, k.original.count) }
        XCTAssertTrue(corr.contains { $0.rule == "asr:non_speech_tag" })
    }

    func testPhoneticMatchesPythonBuilder() {
        // keys produced by core/tools/phonetic.py
        XCTAssertEqual(Phonetic.key("amiodarone"), "AMTRN")
        XCTAssertEqual(Phonetic.key("ondansetron"), "ONTNSTRN")
        XCTAssertEqual(Phonetic.key("zofran"), "SFRN")
        XCTAssertEqual(Phonetic.key("nitroglycerin"), "NTRKLSRN")
        XCTAssertEqual(Phonetic.key("thiamine"), "0MN")
    }

    func testPIIScrub() {
        let p = PIIScrubber()
        p.learn("Her name is Maria Lopez, date of birth March 3, 1957, lives at 42 Elm Street.")
        let s = p.scrub("Maria said she lives at 42 Elm Street")
        XCTAssertFalse(s.contains("Maria")); XCTAssertFalse(s.contains("Elm"))
        XCTAssertEqual(p.vault.count, 3)
        XCTAssertEqual(p.scrub("chest pain"), "chest pain")
    }
}
