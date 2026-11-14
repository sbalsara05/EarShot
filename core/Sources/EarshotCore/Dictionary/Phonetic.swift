import Foundation

/// Metaphone-style phonetic key. Must stay identical to
/// core/tools/phonetic.py (the dictionary builder uses it too).
public enum Phonetic {
    static let vowels: Set<Character> = ["A", "E", "I", "O", "U"]

    public static func key(_ word: String) -> String {
        var w = Array(word.uppercased().filter { $0.isLetter && $0.isASCII })
        if w.isEmpty { return "" }
        for (pre, rep) in [("AE", "E"), ("GN", "N"), ("KN", "N"), ("PN", "N"), ("WR", "R")] where String(w.prefix(2)) == pre {
            w = Array(rep) + Array(w.dropFirst(2)); break
        }
        if w.first == "X" { w[0] = "S" }
        if String(w.prefix(2)) == "WH" { w = ["W"] + Array(w.dropFirst(2)) }
        var out = ""
        let n = w.count
        var i = 0
        func at(_ k: Int) -> Character? { k >= 0 && k < n ? w[k] : nil }
        while i < n {
            let c = w[i]
            let prev = at(i - 1), nxt = at(i + 1), nxt2 = at(i + 2)
            if c == prev && c != "C" { i += 1; continue }
            if vowels.contains(c) {
                if i == 0 { out.append(c) }
            } else {
                switch c {
                case "B":
                    if !(prev == "M" && i == n - 1) { out.append("B") }
                case "C":
                    if nxt == "I" && nxt2 == "A" { out.append("X") }
                    else if nxt == "H" { out.append(prev != "S" ? "X" : "K"); i += 1 }
                    else if nxt == "I" || nxt == "E" || nxt == "Y" { if prev != "S" { out.append("S") } }
                    else { out.append("K") }
                case "D":
                    if nxt == "G", let n2 = nxt2, "EYI".contains(n2) { out.append("J"); i += 1 } else { out.append("T") }
                case "G":
                    if nxt == "H" && !(i + 2 < n && !vowels.contains(w[i + 2])) {
                        i += 1
                        out.append(i + 1 >= n ? "F" : "K")
                    } else if nxt == "N" && (i + 2 == n || (nxt2 == "E" && at(i + 3) == "D")) {
                        // silent
                    } else if let x = nxt, "IEY".contains(x), prev != "G" { out.append("J") }
                    else { out.append("K") }
                case "H":
                    if let x = nxt, vowels.contains(x), !(prev.map { "CSPTG".contains($0) } ?? false) { out.append("H") }
                case "K":
                    if prev != "C" { out.append("K") }
                case "P":
                    if nxt == "H" { out.append("F"); i += 1 } else { out.append("P") }
                case "Q": out.append("K")
                case "S":
                    if nxt == "H" { out.append("X"); i += 1 }
                    else if nxt == "I", let x = nxt2, x == "O" || x == "A" { out.append("X") }
                    else { out.append("S") }
                case "T":
                    if nxt == "I", let x = nxt2, x == "O" || x == "A" { out.append("X") }
                    else if nxt == "H" { out.append("0"); i += 1 }
                    else if !(nxt == "C" && nxt2 == "H") { out.append("T") }
                case "V": out.append("F")
                case "W": if let x = nxt, vowels.contains(x) { out.append("W") }
                case "X": out.append("KS")
                case "Y": if let x = nxt, vowels.contains(x) { out.append("Y") }
                case "Z": out.append("S")
                default: out.append(c)
                }
            }
            i += 1
        }
        return out
    }
}
