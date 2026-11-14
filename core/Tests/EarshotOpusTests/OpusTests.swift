import XCTest
import EarshotCore
@testable import EarshotOpus

final class OpusTests: XCTestCase {
    func testRoundTripKeepsTheSignal() throws {
        let enc = try LibOpusFrameEncoder(), dec = try LibOpusFrameDecoder()
        var inp: [Int16] = [], outp: [Int16] = []
        for f in 0..<50 {
            let frame = (0..<320).map { i in Int16(8000 * sin(Double(f * 320 + i) * 2 * .pi * 440 / 16000)) }
            inp += frame
            let pkt = try enc.encode(frame)
            XCTAssertLessThan(pkt.count, 160, "fits one Bluetooth packet")
            outp += try dec.decode(pkt)
        }
        XCTAssertEqual(outp.count, inp.count)
        // compare energy after the codec's start-up delay
        func rms(_ x: ArraySlice<Int16>) -> Double { (x.map { Double($0) * Double($0) }.reduce(0, +) / Double(x.count)).squareRoot() }
        XCTAssertEqual(rms(outp[3200...]), rms(inp[3200...]), accuracy: rms(inp[3200...]) * 0.2)
        dec.reset()
        XCTAssertEqual(try dec.decode(try enc.encode([Int16](repeating: 0, count: 320))).count, 320)
    }
}
