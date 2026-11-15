import XCTest
@testable import Fill

/// A stand-in for the language model: answers each question from a script, by the question's title.
final class Script: Engine {
    let name = "script"
    var replies: [String: String]
    init(_ replies: [String: String]) { self.replies = replies }
    func complete(system: String, user: String, grammar: String, maxTokens: Int) throws -> String {
        replies.first { user.contains("TASK: " + $0.key) }?.value ?? #"{"items":[]}"#
    }
}

final class FillTests: XCTestCase {
    func heard(_ lines: [String]) -> [Heard] { lines.enumerated().map { Heard($1, clock: "10:00:\(String(format: "%02d", $0 * 10))", seconds: 36000 + Double($0) * 10) } }

    func testSpokenNumbersBecomeDigits() {
        XCTAssertEqual(Words.digits("B P one fifty eight over ninety two, heart rate one ten."), "B P 158 over 92, heart rate 110.")
        XCTAssertEqual(Words.digits("pulse one oh two"), "pulse 102")
        XCTAssertEqual(Words.digits("Nitro point four sublingual."), "Nitro 0.4 sublingual.")
        XCTAssertEqual(Words.digits("a hundred and fifty eight over ninety two"), "a 158 over 92")
        XCTAssertEqual(Words.digits("Three twenty four of aspirin"), "324 of aspirin")
        XCTAssertEqual(Words.digits("this one is fine"), "this one is fine")
        XCTAssertEqual(Words.numbers(in: "started an hour ago, sixty-seven year old"), [1, 67])
    }

    func testANumberMustBeSaidWhereTheModelPoints() throws {
        let lines = heard(["She is sixty seven.", "Heart rate one ten.", "Sats ninety seven on two liters."])
        let filled = try Filler(Script([
            "Who": #"{"items":[{"line":1,"field":"age","value":67},{"line":1,"field":"age_units","value":"Years"},{"line":1,"field":"sex","value":"Female"}]}"#,
            "Vital": #"{"items":[{"line":2,"field":"heart_rate","value":110},{"line":2,"field":"heart_rate","value":10},{"line":3,"field":"resp_rate","value":2},{"line":3,"field":"spo2","value":97},{"line":1,"field":"bp_systolic","value":120},{"line":9,"field":"pain","value":4}]}"#,
        ])).fill(lines)
        XCTAssertEqual(filled.answers["ePatient.15"]?.value, "67")
        XCTAssertNil(filled.answers["ePatient.16"], "\"Years\" was never said")
        XCTAssertEqual(filled.answers["ePatient.25"]?.value, "Female")
        XCTAssertEqual(filled.answers["eVitals.10"]?.value, "110")
        XCTAssertEqual(filled.answers["eVitals.12"]?.value, "97")
        XCTAssertNil(filled.answers["eVitals.14"], "2 liters is not a breathing rate")
        XCTAssertNil(filled.answers["eVitals.06"], "120 was never said")
        XCTAssertEqual(filled.answers["eVitals.01"]?.value, "10:00:10")
        XCTAssertEqual(filled.dropped.count, 6)   // five items, and the script writes no narrative
    }

    func testVitalsBecomeSetsAndRepeatsAreOne() throws {
        let lines = [Heard("BP 158 over 92, pulse 110.", clock: "10:00:00", seconds: 0), Heard("Again, pressure 158 over 92.", clock: "10:00:20", seconds: 20),
                     Heard("Pressure now 138 over 84.", clock: "10:05:00", seconds: 300)]
        let filled = try Filler(Script(["Vital": #"{"items":[{"line":1,"field":"bp_systolic","value":158},{"line":1,"field":"bp_diastolic","value":92},{"line":1,"field":"heart_rate","value":110},{"line":2,"field":"bp_systolic","value":158},{"line":2,"field":"bp_diastolic","value":92},{"line":3,"field":"bp_systolic","value":138},{"line":3,"field":"bp_diastolic","value":84}]}"#])).fill(lines)
        XCTAssertEqual(filled.answers["eVitals.06"]?.value, "158")
        XCTAssertEqual(filled.answers["eVitals.06#2"]?.value, "138")
        XCTAssertEqual(filled.answers["eVitals.01#2"]?.value, "10:05:00")
        XCTAssertNil(filled.answers["eVitals.06#3"])
    }

    func testMedicinesAreCheckedCorrectedAndNotProcedures() throws {
        let lines = heard(["Three twenty four of a spurin, chewed.", "Eighteen gauge in the left A C.", "Four milligrams of Zofran I V.", "He takes metoprolol at home."])
        let filled = try Filler(Script([
            "Medicines": #"{"items":[{"line":1,"drug":"spurin","dose":324,"units":"mg","route":"Sublingual"},{"line":3,"drug":"Zofran","dose":4,"units":"mg","route":"IV"},{"line":2,"drug":"fentanyl","dose":50,"units":"mcg","route":"IV"}]}"#,
            "Procedures": #"{"items":[{"line":2,"name":"IV, 18 gauge, left AC"},{"line":3,"name":"IV Zofran 4 milligrams"}]}"#,
        ])).fill(lines)
        XCTAssertEqual(filled.answers["eMedications.03"]?.value, "aspirin")
        XCTAssertEqual(filled.answers["eMedications.03"]?.check, true)
        XCTAssertEqual(filled.answers["eMedications.05"]?.value, "324")
        XCTAssertNil(filled.answers["eMedications.06"], "no unit was said")
        XCTAssertNil(filled.answers["eMedications.04"], "sublingual was not said")
        XCTAssertEqual(filled.answers["eMedications.04#2"]?.value, "IV")
        XCTAssertEqual(filled.answers["eMedications.06#2"]?.value, "mg")
        XCTAssertNil(filled.answers["eMedications.03#3"], "fentanyl was never said")
        XCTAssertEqual(filled.answers["eProcedures.03"]?.value, "IV, 18 gauge, left AC")
        XCTAssertNil(filled.answers["eProcedures.03#2"], "giving Zofran is not a procedure")
    }

    func testTheSameFactFromTwoPlaces() throws {
        let lines = heard(["Sixty seven year old female, chest pain for an hour.", "History of hypertension.", "Also diabetes. Sixty nine years old I think."])
        let filled = try Filler(Script([
            "Who": #"{"items":[{"line":1,"field":"age","value":67},{"line":3,"field":"age","value":69},{"line":2,"field":"history","value":"hypertension"},{"line":3,"field":"history","value":"diabetes"},{"line":1,"field":"history","value":"chest pain"}]}"#,
            "What": #"{"items":[{"line":1,"field":"complaint","value":"chest pain"},{"line":1,"field":"duration","value":67},{"line":1,"field":"impression","value":"none"}]}"#,
        ])).fill(lines)
        XCTAssertEqual(filled.answers["ePatient.15"], Answer(value: "67", line: 1, check: true, other: "69"))
        XCTAssertEqual(filled.answers["eHistory.08"]?.value, "hypertension, diabetes")
        XCTAssertNil(filled.answers["eSituation.05"], "67 is the age")
        XCTAssertNil(filled.answers["eSituation.11"])
    }

    func testEveryFieldTheModelIsAskedForHasAGrammarRule() {
        for pass in Pass.all {
            XCTAssertTrue(pass.grammar.contains("root ::="))
            for field in pass.fields { XCTAssertTrue(pass.grammar.contains("\\\"\(field.key!)\\\""), field.id) }
        }
        XCTAssertEqual(Set(Nemsis.sections.flatMap(\.fields).map(\.id)).count, Nemsis.fieldCount)
    }

    /// Runs the national schema over what the writer makes. Mac only: it needs xmllint.
    func valid(_ xml: String) throws -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("earshot-\(UUID().uuidString).xml")
        try xml.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let schema = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("nemsis_xsd/EMSDataSet_v3.xsd")
        let lint = Process(), pipe = Pipe()
        lint.executableURL = URL(fileURLWithPath: "/usr/bin/xmllint")
        lint.arguments = ["--noout", "--schema", schema.path, file.path]
        lint.standardError = pipe
        try lint.run()
        let said = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        lint.waitUntilExit()
        return lint.terminationStatus == 0 ? "" : said
    }

    func testTheXMLPassesTheNationalSchema() throws {
        #if os(macOS)
        var agency = NemsisXML.Agency()
        agency.number = "A123"; agency.stateID = "S-9"; agency.state = "MA"; agency.unit = "M4"; agency.callSign = "Medic 4"
        agency.capability = "2207015"; agency.serviceType = "2205001"; agency.responseMode = "2223001"
        let start = Date(timeIntervalSince1970: 1_794_000_000)
        let full: [String: String] = [
            "ePatient.03": "Dana", "ePatient.02": "Lee", "ePatient.15": "67", "ePatient.16": "Years", "ePatient.25": "Female",
            "eScene.15": "1 Main St & 2nd", "eScene.18": "MA", "eScene.19": "02115", "eScene.06": "Single",
            "eSituation.04": "chest pain", "eSituation.05": "1", "eSituation.06": "Hours", "eSituation.07": "Chest", "eSituation.11": "STEMI",
            "eHistory.08": "hypertension", "eTimes.09": "10:02:26", "eTimes.11": "10:02:38",
            "eVitals.01": "10:00:36", "eVitals.06": "158", "eVitals.07": "92", "eVitals.10": "110", "eVitals.12": "94", "eVitals.14": "22", "eVitals.27": "6", "eVitals.23": "15",
            "eVitals.01#2": "10:02:02", "eVitals.06#2": "138", "eVitals.10#2": "96", "eVitals.18#2": "110",
            "eMedications.03": "aspirin", "eMedications.05": "324", "eMedications.04": "Oral", "eMedications.01": "10:00:52",
            "eMedications.03#2": "Nitro", "eMedications.05#2": "0.4", "eMedications.04#2": "Sublingual", "eMedications.06#2": "mg", "eMedications.07#2": "Improved",
            "eMedications.03#3": "somethingnew", "eProcedures.03": "12 lead ECG", "eProcedures.01": "10:01:02", "eProcedures.05": "1", "eProcedures.06": "Yes",
            "eDisposition.01": "Mass General", "eDisposition.17": "Emergent", "eNarrative.01": "A 67 year old <female> with chest pain.",
        ]
        for report in [full, [:], ["ePatient.15": "sixty", "eVitals.07": "92", "eScene.19": "nope", "eSituation.05": "1"]] {
            let xml = NemsisXML.write(report, id: UUID(), start: start, end: start.addingTimeInterval(600), agency: agency, version: "1.0")
            XCTAssertEqual(try valid(xml), "")
        }
        let xml = NemsisXML.write(full, id: UUID(), start: start, end: start.addingTimeInterval(600), agency: agency, version: "1.0")
        XCTAssertTrue(xml.contains("<eMedications.03 CodeType=\"9924003\">4917</eMedications.03>"), "Nitro is nitroglycerin")
        XCTAssertTrue(xml.contains("<ePatient.25>9919001</ePatient.25>") && xml.contains("<eVitals.06>138</eVitals.06>") && xml.contains("<dAgency.04>25</dAgency.04>"))
        XCTAssertEqual(try valid(NemsisXML.write([:], id: UUID(), start: start, end: start, agency: NemsisXML.Agency(), version: "1.0")), "", "nothing set in Settings")
        #endif
    }
}
