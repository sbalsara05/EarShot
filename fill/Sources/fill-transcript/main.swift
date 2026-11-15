import Foundation
import Fill

// Fills a NEMSIS report from a transcript file on a Mac, and scores it against the right answers.
//
//   fill-transcript <model.gguf> <transcript.txt> [--score answers.json] [--cpu] [--dropped]
//
// A transcript file has one line of speech per line: "[14:03:22] what was said". Start a line with "? " when
// the recogniser doubted it. The answers file is JSON: {"ePatient.15": "67", "eVitals.06#2": "138", ...}.

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool { if let i = args.firstIndex(of: name) { args.remove(at: i); return true } else { return false } }
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...i + 1) }
    return args[i + 1]
}
let cpu = flag("--cpu"), showDropped = flag("--dropped"), scoreFile = option("--score")
guard args.count == 2 else {
    print("usage: fill-transcript <model.gguf> <transcript.txt> [--score answers.json] [--cpu] [--dropped]")
    exit(2)
}

func lines(of path: String) throws -> [Heard] {
    try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").compactMap { raw in
        var line = raw.trimmingCharacters(in: .whitespaces)
        let unsure = line.hasPrefix("? ")
        if unsure { line.removeFirst(2) }
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let clock = String(line[line.index(after: line.startIndex)..<close])
        let parts = clock.split(separator: ":").compactMap { Double($0) }
        let seconds = parts.reduce(0) { $0 * 60 + $1 }
        return Heard(line[line.index(after: close)...].trimmingCharacters(in: .whitespaces), clock: clock, seconds: seconds, unsure: unsure)
    }
}

do {
    let heard = try lines(of: args[1])
    let loading = Date()
    let llama = try Llama(args[0], gpu: !cpu)
    FileHandle.standardError.write(Data("model \(llama.name) loaded in \(String(format: "%.1f", Date().timeIntervalSince(loading))) s; \(heard.count) lines\n".utf8))
    let filled = try Filler(llama).fill(heard) { step, of in FileHandle.standardError.write(Data("  question \(step) of \(of)\n".utf8)) }

    for (element, answer) in filled.answers.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) {
        let label = Nemsis.fields[String(element.split(separator: "#")[0])]?.label ?? ""
        print("\(element.padding(toLength: 18, withPad: " ", startingAt: 0)) \(label.padding(toLength: 26, withPad: " ", startingAt: 0)) \(answer.value)\(answer.check ? "   (check)" : "")\(answer.other.map { "   or: \($0)" } ?? "")\(answer.line.map { "   L\($0)" } ?? "")")
    }
    if showDropped { for line in filled.dropped { print("dropped  \(line)") } }
    FileHandle.standardError.write(Data(String(format: "%.1f s in all: read %d tokens in %.1f s, wrote %d in %.1f s; %d dropped by the checks\n",
                                               filled.seconds, llama.promptTokens, llama.promptSeconds, llama.madeTokens, llama.makeSeconds, filled.dropped.count).utf8))

    if let scoreFile {
        let want = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: scoreFile))) as? [String: String] ?? [:]
        func same(_ a: String, _ b: String) -> Bool {
            if let x = Double(a), let y = Double(b) { return x == y }
            let a = a.lowercased(), b = b.lowercased()
            return a == b || a.contains(b) || b.contains(a)
        }
        var right = 0, wrong: [String] = [], missing: [String] = [], extra: [String] = []
        for (element, value) in want.sorted(by: { $0.key < $1.key }) where element != "eNarrative.01" {
            guard let got = filled.answers[element] else { missing.append("\(element) (\(value))"); continue }
            if same(got.value, value) { right += 1 } else { wrong.append("\(element): got \"\(got.value)\", want \"\(value)\"") }
        }
        for (element, answer) in filled.answers.sorted(by: { $0.key < $1.key }) where want[element] == nil && element != "eNarrative.01" { extra.append("\(element): \"\(answer.value)\"\(answer.check ? " (check)" : "")") }
        print("\nSCORE  right \(right) of \(want.count)   wrong \(wrong.count)   missing \(missing.count)   not expected \(extra.count)")
        for line in wrong { print("  wrong         \(line)") }
        for line in missing { print("  missing       \(line)") }
        for line in extra { print("  not expected  \(line)") }
    }
} catch {
    print("failed: \(error.localizedDescription)")
    exit(1)
}
