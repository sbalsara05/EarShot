import Foundation
import Transcribe

// Transcribes a WAV file the way the app transcribes a call, and prints the lines.
//
//   swift run -c release transcribe-wav Models/ggml-small.en.bin call.wav [--beam 1] [--no-drugs] [--no-retries] [--no-level] [--cpu] [--json]

let arguments = CommandLine.arguments.dropFirst()
let paths = arguments.filter { !$0.hasPrefix("--") }
guard paths.count == 2 else {
    print("usage: transcribe-wav <model.bin> <audio.wav> [--beam N] [--no-drugs] [--no-retries] [--no-level] [--cpu] [--json]")
    exit(2)
}
func flag(_ name: String) -> Bool { arguments.contains(name) }

/// 16-bit WAV, any rate or channel count, as 16 kHz mono.
func wav(_ url: URL) throws -> [Int16] {
    let d = [UInt8](try Data(contentsOf: url))
    func u16(_ i: Int) -> Int { Int(d[i]) | Int(d[i + 1]) << 8 }
    func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
    guard d.count > 44, String(bytes: d[0..<4], encoding: .ascii) == "RIFF" else { throw NSError(domain: "wav", code: 1, userInfo: [NSLocalizedDescriptionKey: "not a WAV file"]) }
    var at = 12, channels = 1, rate = 16000
    var pcm: [Int16] = []
    while at + 8 <= d.count {
        let id = String(bytes: d[at..<(at + 4)], encoding: .ascii) ?? "", size = u32(at + 4), body = at + 8
        if id == "fmt " {
            guard u16(body) == 1, u16(body + 14) == 16 else { throw NSError(domain: "wav", code: 2, userInfo: [NSLocalizedDescriptionKey: "only 16-bit PCM WAV files are read"]) }
            channels = u16(body + 2); rate = u32(body + 4)
        } else if id == "data" {
            var i = body
            while i + 2 * channels <= min(d.count, body + size) {
                var sum = 0
                for c in 0..<channels { sum += Int(Int16(bitPattern: UInt16(u16(i + 2 * c)))) }
                pcm.append(Int16(sum / channels)); i += 2 * channels
            }
        }
        at = body + size + (size & 1)
    }
    guard rate != 16000, !pcm.isEmpty else { return pcm }
    let n = pcm.count * 16000 / rate
    return (0..<n).map { i in
        let x = Double(i) * Double(rate) / 16000, j = Int(x)
        let a = Double(pcm[min(j, pcm.count - 1)]), b = Double(pcm[min(j + 1, pcm.count - 1)])
        return Int16(a + (b - a) * (x - Double(j)))
    }
}

do {
    let audio = try wav(URL(fileURLWithPath: paths[1]))
    let loading = Date()
    let whisper = try Whisper(model: URL(fileURLWithPath: paths[0]), gpu: !flag("--cpu"))
    if let i = arguments.firstIndex(of: "--beam"), let n = Int32(arguments[arguments.index(after: i)]) { whisper.beam = n }
    whisper.retries = !flag("--no-retries")
    if !flag("--no-drugs") { whisper.lean(toward: Drugs.names) }
    let loaded = Date().timeIntervalSince(loading)

    let scribe = Scribe(whisper)
    scribe.queue = DispatchQueue(label: "out")
    scribe.levels = !flag("--no-level")
    var all: [Line] = [], spent = 0.0, slowest = 0.0
    scribe.onLines = { lines, _ in all += lines }
    scribe.onTimed = { length, took in spent += took; slowest = max(slowest, took / length) }
    let done = DispatchSemaphore(value: 0)
    var i = 0
    while i < audio.count { scribe.feed(Array(audio[i..<min(audio.count, i + 320)])); i += 320 }
    scribe.finish { done.signal() }
    done.wait()

    if flag("--json") {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(data: try encoder.encode(all), encoding: .utf8)!)
    } else {
        for l in all {
            let weak = l.words.enumerated().filter { $0.element.confidence < Lines.unsure }.map { w -> String in
                let rest = l.text.dropFirst(w.element.offset)
                return "\(rest.prefix { $0 != " " }) \(String(format: "%.2f", w.element.confidence))"
            }
            print(String(format: "%6.1fs  %.2f  %@%@", Double(l.startMs) / 1000, l.confidence, l.text, weak.isEmpty ? "" : "   [unsure: \(weak.joined(separator: ", "))]"))
        }
    }
    let length = Double(audio.count) / 16000
    FileHandle.standardError.write(Data(String(format: "\n%@: %.0f s of audio, %d lines. Model loaded in %.1f s. Whisper took %.1f s in all (%.1fx faster than speech); its slowest chunk ran at %.2f s per second of audio.\n",
                                               whisper.name, length, all.count, loaded, spent, length / max(spent, 0.001), slowest).utf8))
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
