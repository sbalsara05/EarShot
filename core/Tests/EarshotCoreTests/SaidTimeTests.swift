import XCTest
@testable import EarshotCore

/// A time said aloud about something done becomes that event's time.
final class SaidTimeTests: XCTestCase {
    private func found(_ text: String, _ type: EventType) -> [Finding] { extract(text).filter { $0.type == type } }

    // MARK: the rules give the time to the right thing

    func testTimeAfterAMedication() {
        for t in ["Aspirin given at 1410.", "Aspirin given at fourteen ten.", "aspirin 324 milligrams chewed at fourteen ten", "Aspirin given at 1410 hours."] {
            let m = found(t, .medication).first
            XCTAssertEqual(m?.fields["time_said"], "14:10", t)
            XCTAssertNotNil(m?.receipts["time_said"], t)
        }
        XCTAssertEqual(found("aspirin 324 at 1410", .medication).first?.fields["dose"], "324")
    }

    func testTimeBeforeTheThing() {
        XCTAssertEqual(found("At 1405, BP 150 over 90.", .vitals).first?.fields["time_said"], "14:05")
        XCTAssertEqual(found("At 1410 gave 324 of aspirin.", .medication).first?.fields["time_said"], "14:10")
    }

    func testVitalSignsReadTogetherShareTheTime() {
        let v = found("BP 150 over 90, heart rate 104, sats 94 at 1405.", .vitals)
        XCTAssertFalse(v.isEmpty)
        XCTAssertTrue(v.allSatisfy { $0.fields["time_said"] == "14:05" }, "\(v.map(\.fields))")
    }

    func testEachThingKeepsItsOwnTime() {
        let f = extract("BP 150 over 90 at 1405. Gave 324 of aspirin at 1410.")
        XCTAssertEqual(f.first { $0.type == .vitals }?.fields["time_said"], "14:05")
        XCTAssertEqual(f.first { $0.type == .medication }?.fields["time_said"], "14:10")
    }

    func testATimeThatBelongsToSomethingElseIsLeftAlone() {
        XCTAssertNil(found("Last known well at 1410, gave 324 of aspirin.", .medication).first?.fields["time_said"])
        XCTAssertNil(found("Gave 324 of aspirin. Arrived at 1410.", .medication).first?.fields["time_said"])
        XCTAssertNil(found("normal saline at 1000 ml", .medication).first?.fields["time_said"])
        XCTAssertNil(found("Gave 324 of aspirin.", .medication).first?.fields["time_said"])
    }

    // MARK: other ways a time is said

    private func said(_ text: String) -> (String?, String?, String?) {
        let m = found(text, .medication).first
        return (m?.fields["time_said"], m?.fields["time_half"], m?.fields["dose"])
    }

    func testAmAndPm() {
        for t in ["Aspirin given at two ten p.m.", "aspirin given at 2:10 pm", "aspirin given at 2:10 PM.", "aspirin given at 210 pm", "aspirin given 2:10 pm"] {
            let (time, half, dose) = said(t)
            XCTAssertEqual(time, "14:10", t); XCTAssertNil(half, t); XCTAssertNil(dose, "\(t) -> dose \(dose ?? "")")
        }
        XCTAssertEqual(said("aspirin given at 2 pm").0, "14:00")
        XCTAssertEqual(said("aspirin given at two ten a.m.").0, "02:10")
        XCTAssertEqual(said("aspirin given at 12:05 am").0, "00:05")
        XCTAssertEqual(said("aspirin given at 12:05 pm").0, "12:05")
        XCTAssertEqual(said("aspirin 324 at 2:10 pm").2, "324")
    }

    func testTheHalfOfTheDayIsMarkedWhenItWasNotSaid() {
        let spoken = said("Aspirin given at two ten.")          // Whisper writes the words as 210
        XCTAssertEqual(spoken.0, "02:10"); XCTAssertEqual(spoken.1, "unsaid"); XCTAssertNil(spoken.2)
        XCTAssertEqual(said("aspirin given at 2:10").1, "unsaid")
        XCTAssertNil(said("aspirin given at 1410").1)
        XCTAssertNil(said("aspirin given at 0210 hours").1)     // military: the morning was meant
        XCTAssertNil(said("aspirin given at fourteen ten").1)
    }

    func testHoursWithoutAt() {
        XCTAssertEqual(said("1410 hours, aspirin given.").0, "14:10")
        XCTAssertEqual(said("aspirin given 0210 hours").0, "02:10")
        XCTAssertEqual(said("aspirin given at about 1410").0, "14:10")
        XCTAssertNil(said("aspirin given at about 1410").2)
    }

    func testAmountsAreStillAmounts() {
        XCTAssertNil(said("aspirin 324").0)
        XCTAssertEqual(said("aspirin at 210").2, "210")                      // digits with no am or pm: an amount
        XCTAssertFalse(Cleanup(dict: TestEnv.dict).clean(seg("normal saline at 1000 ml")).0.text.contains(":"))
        XCTAssertFalse(Cleanup(dict: TestEnv.dict).clean(seg("on scene for 2 hours")).0.text.contains(":"))
        XCTAssertFalse(Cleanup(dict: TestEnv.dict).clean(seg("gave 2 of versed")).0.text.contains(":"))
        XCTAssertFalse(Cleanup(dict: TestEnv.dict).clean(seg("1000 of saline wide open")).0.text.contains(":"))
    }

    func testMinutesAgo() {
        XCTAssertEqual(said("gave aspirin five minutes ago").0, "5 min ago")
        XCTAssertEqual(said("aspirin given 20 mins ago").0, "20 min ago")
        XCTAssertEqual(said("gave aspirin about an hour ago.").0, "60 min ago")
        XCTAssertEqual(said("gave aspirin half an hour ago").0, "30 min ago")
        let m = said("aspirin 324 five minutes ago")
        XCTAssertEqual(m.0, "5 min ago"); XCTAssertEqual(m.2, "324")
        // about the complaint, not the drug
        XCTAssertNil(said("gave aspirin, pain started 20 minutes ago").0)
        XCTAssertNil(said("gave aspirin pain started 20 minutes ago").0)
        XCTAssertNil(said("Chest pain began 20 minutes ago, gave 324 of aspirin.").0)
        XCTAssertNil(said("gave aspirin 9 hours ago").0)                     // further back than a call reaches
    }

    // MARK: placing the time on the call's clock

    /// A call that began at 14:20 local time.
    private let clock = CallClock(iso: "2026-11-15T14:20:00-05:00")!
    private func at(_ said: String, heardMinutesIn: Int64) -> (String, Bool)? {
        SaidTime.resolve(said, heardAt: heardMinutesIn * 60_000, clock: clock).map { (String(clock.clock($0.tMs).prefix(5)), $0.guessedHalf) }
    }

    func testResolve() {
        XCTAssertEqual(at("14:22", heardMinutesIn: 5)?.0, "14:22")              // three minutes ago
        XCTAssertEqual(at("14:10", heardMinutesIn: 5)?.0, "14:10")              // before the call began
        XCTAssertEqual(at("14:26", heardMinutesIn: 5)?.0, "14:26")              // a minute ahead: clocks differ
        XCTAssertNil(at("15:30", heardMinutesIn: 5))                             // the future
        XCTAssertNil(at("03:00", heardMinutesIn: 5))                             // eleven hours back, or the future
        let pm = at("02:10", heardMinutesIn: 5)                                  // "two ten", said at 14:25
        XCTAssertEqual(pm?.0, "14:10"); XCTAssertEqual(pm?.1, true)
        XCTAssertEqual(at("14:10", heardMinutesIn: 5)?.1, false)
        XCTAssertNil(at("25:00", heardMinutesIn: 5)); XCTAssertNil(at("soon", heardMinutesIn: 5))
    }

    func testResolveAcrossMidnight() {
        let late = CallClock(iso: "2026-11-15T23:50:00-05:00")!
        let r = SaidTime.resolve("23:55", heardAt: 20 * 60_000, clock: late)    // said at 00:10 the next day
        XCTAssertEqual(r.map { late.iso($0.tMs) }, "2026-11-15T23:55:00-05:00")
    }

    // MARK: the whole way through

    private func events(_ lines: [String]) throws -> [EarshotEvent] {
        var cfg = PipelineConfig(); cfg.callId = "c1"; cfg.startTime = "2026-11-15T14:20:00-05:00"
        let raw = RawTranscript(callId: "c1", asrModel: "test", segments: lines.enumerated().map {
            seg($1, id: "s\($0 + 1)", start: Int64($0) * 300_000, end: Int64($0) * 300_000 + 4000)   // one line every five minutes
        })
        return try EarshotPipeline(dict: TestEnv.dict, config: cfg, transcriber: nil).run(.transcript(raw, taps: [])).events
    }

    func testTheEventTakesTheDictatedTime() throws {
        // said in order at 14:20, 14:25 and 14:30
        let ev = try events(["Gave 4 milligrams of zofran IV.", "BP 150 over 90.", "Aspirin 324 given at 1422."])
        let asa = try XCTUnwrap(ev.first { $0.fields["drug"] == "aspirin" })
        XCTAssertEqual(asa.time, "2026-11-15T14:22:00-05:00")
        XCTAssertEqual(asa.fields["heard_at"]?.prefix(5), "14:30")
        XCTAssertEqual(asa.fields["time_said"], "14:22")
        XCTAssertNotEqual(asa.flags?.contains("confirm"), true)
        // the chart reads in the order things were done: zofran 14:20, aspirin 14:22, BP 14:25
        let order = ev.filter { [.medication, .vitals].contains($0.type) }.map { $0.fields["drug"] ?? "vitals" }
        XCTAssertEqual(order, ["ondansetron", "aspirin", "vitals"])
        XCTAssertEqual(ev.map(\.tMs), ev.map(\.tMs).sorted())
    }

    func testMinutesAgoAndAfternoonTimesThroughThePipeline() throws {
        // said at 14:20, 14:25 and 14:30
        let ev = try events(["BP 150 over 90.", "Gave 4 milligrams of zofran IV five minutes ago.", "Aspirin 324 given at two ten.", "Nitro 0.4 sublingual at 2:28 pm."])
        let zofran = try XCTUnwrap(ev.first { $0.fields["drug"] == "ondansetron" })
        XCTAssertEqual(zofran.time.prefix(16), "2026-11-15T14:20")            // five minutes before it was said, a second into 14:25
        XCTAssertNotEqual(zofran.flags?.contains("confirm"), true)
        let asa = try XCTUnwrap(ev.first { $0.fields["drug"] == "aspirin" })
        XCTAssertEqual(asa.time, "2026-11-15T14:10:00-05:00")                 // "two ten" in the afternoon
        XCTAssertEqual(asa.flags?.contains("confirm"), true)                  // the afternoon was worked out, not said
        let nitro = try XCTUnwrap(ev.first { $0.type == .medication && $0.fields["time_said"] == "14:28" })
        XCTAssertEqual(nitro.time, "2026-11-15T14:28:00-05:00")
        XCTAssertNotEqual(nitro.flags?.contains("confirm"), true)
    }

    func testAMorningTimeSaidInTheAfternoonIsNotMoved() throws {
        let ev = try events(["Aspirin 324 given at 0210 hours."])            // the call is at 14:20: twelve hours back
        let asa = try XCTUnwrap(ev.first { $0.type == .medication })
        XCTAssertNil(asa.fields["heard_at"]); XCTAssertEqual(asa.flags?.contains("confirm"), true)
    }

    func testATimeThatCannotBePlacedAsksTheMedic() throws {
        let ev = try events(["Aspirin 324 given at 1900."])   // the call is at 14:20
        let asa = try XCTUnwrap(ev.first { $0.type == .medication })
        XCTAssertEqual(asa.time.prefix(16), "2026-11-15T14:20")
        XCTAssertNil(asa.fields["heard_at"])
        XCTAssertEqual(asa.flags?.contains("confirm"), true)
    }
}
