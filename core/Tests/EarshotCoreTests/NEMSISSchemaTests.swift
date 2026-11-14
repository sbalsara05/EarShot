import XCTest
@testable import EarshotCore

/// H1: every nemsis.xml we emit must pass the NEMSIS v3.5.1 XSD (vendored in
/// Fixtures/nemsis_xsd). Uses xmllint when present; skips otherwise.
final class NEMSISSchemaTests: XCTestCase {
    func validate(_ xml: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let lint = ["/usr/bin/xmllint", "/opt/homebrew/bin/xmllint", "/usr/local/bin/xmllint"].first { FileManager.default.fileExists(atPath: $0) }
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

    func run(_ lines: [String], taps: [TapInput] = []) throws -> String {
        let raw = RawTranscript(callId: "c1", asrModel: "t", segments: lines.enumerated().map {
            RawSegment(id: "s\($0 + 1)", startMs: Int64($0) * 5000, endMs: Int64($0) * 5000 + 4000, text: $1) })
        var cfg = PipelineConfig(); cfg.startTime = "2026-11-15T14:00:00-05:00"
        return try EarshotPipeline(dict: TestEnv.dict, config: cfg, transcriber: nil).run(.transcript(raw, taps: taps)).docs.last!.text
    }

    func testEmptyCallValidates() throws { try validate(try run([])) }

    func testRichCallValidates() throws {
        try validate(try run([
            "We got called for a fall, it turned out to be chest pain.", "She is an 18 month old female.",
            "BP 90 by palp, pulse 120, sats 91, resps 28, GCS 14, sugar 54, temp 101.2, pain 7 out of 10.",
            "Gave 324 of aspirin, chewed. 4 milligrams zofran IV. Nitro 0.4 milligrams sublingual.",
            "18 gauge in the left AC. 12 lead done.", "Transporting to Mass General, lights and sirens.", "Arrived at Mass General.",
        ], taps: [TapInput(clipMs: 40000, source: "tablet", gesture: "handoff")]))
    }

    func testDemoGoldenValidates() throws {
        try validate(try String(contentsOf: TestEnv.fixtures.appendingPathComponent("golden/nemsis.xml"), encoding: .utf8))
    }
}
