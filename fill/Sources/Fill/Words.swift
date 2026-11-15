import Foundation

/// Reading a transcript line the way the checks need it: its words, the numbers in it however they were
/// said, and whether a word the model wrote was really there.
enum Words {
    /// Lower-case words. Letters spoken one at a time are joined: "B P" is "bp", "I V" is "iv".
    static func of(_ text: String) -> [String] {
        var out: [String] = [], letters = ""
        func flush() { if !letters.isEmpty { out.append(letters); letters = "" } }
        for word in text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == ".") }) {
            let word = word.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if word.isEmpty { continue }
            if word.count == 1, word.first!.isLetter, word != "a" { letters += word } else { flush(); out.append(word) }
        }
        flush()
        return out
    }

    private static let small: [String: Int] = [
        "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    /// A line with its spelled-out numbers written as digits, the way crews say them: "one fifty eight over
    /// ninety two" becomes "158 over 92", "one oh two" 102, "point four" 0.4, "a hundred and four" "a 104".
    /// Small models misread spoken numbers, so this is done by rule before the model sees the line.
    /// A lone "one" is left alone: it is usually not a number ("this one").
    static func digits(_ text: String) -> String {
        var out: [String] = [], run: [String] = [], tail = ""
        func core(_ word: Substring) -> String { word.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        func close() {
            defer { run = []; tail = "" }
            guard !run.isEmpty else { return }
            let words = run.map { core(Substring($0)) }
            if words == ["one"] || words == ["oh"] { out += run; return }
            guard let n = value(words.filter { $0 != "and" }) else { out += run; return }
            out.append((n == n.rounded() ? String(Int(n)) : String(n)) + tail)
        }
        let words = text.replacingOccurrences(of: #"(?i)\b(twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)-(one|two|three|four|five|six|seven|eight|nine)\b"#, with: "$1 $2", options: .regularExpression)
            .split(separator: " ", omittingEmptySubsequences: true)
        for (i, word) in words.enumerated() {
            let plain = core(word)
            let next = i + 1 < words.count ? core(words[i + 1]) : ""
            let joins = plain == "and" && run.last.map { core(Substring($0)) } == "hundred" && small[next] != nil
            if small[plain] != nil || plain == "hundred" || plain == "point" || joins {
                run.append(String(word))
                // Punctuation after a number word ends the number: "one ten, sats ninety four".
                if let last = word.last, last.isPunctuation {
                    tail = String(word.reversed().prefix { $0.isPunctuation }.reversed())
                    close()
                }
            } else {
                close()
                out.append(String(word))
            }
        }
        close()
        return out.joined(separator: " ")
    }

    private static let spans: Set<String> = ["second", "seconds", "minute", "minutes", "hour", "hours", "day", "days", "week", "weeks", "month", "months", "year", "years"]

    /// The numbers said in a line, in digits or in words. "An hour" counts as 1.
    static func numbers(in text: String) -> Set<Double> {
        var found: Set<Double> = []
        let words = digits(text).lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == ".") }).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.filter { !$0.isEmpty }
        for (i, word) in words.enumerated() {
            if let n = Double(word) { found.insert(n) }
            else if word == "one" || ((word == "a" || word == "an") && i + 1 < words.count && spans.contains(words[i + 1])) { found.insert(1) }
        }
        return found
    }

    /// The number a run of number words means, or nil when it is not one ("point" alone).
    private static func value(_ run: [String]) -> Double? {
        if let dot = run.firstIndex(of: "point") {
            let whole = dot == 0 ? 0 : value(Array(run[..<dot]))
            let digits = run[(dot + 1)...].compactMap { small[$0] }
            guard let whole, !digits.isEmpty, digits.count == run.count - dot - 1, digits.allSatisfy({ $0 < 10 }) else { return nil }
            return whole + (Double("0." + digits.map(String.init).joined()) ?? 0)
        }
        var total = 0, last = -1, any = false, hundreds = false
        for word in run {
            if word == "hundred" {
                total = any ? total * 100 : 100   // "a hundred and fifty"
                any = true; hundreds = true; last = -1
            } else if let n = small[word] {
                if !any { total = n }
                else if (last >= 20 && last % 10 == 0 && (1...9).contains(n)) || (hundreds && last == -1) { total += n }   // "fifty eight", "one hundred ten"
                else { total = total * (n >= 10 ? 100 : 10) + n }                                                          // "one fifty", "one oh two"
                last = n; any = true
            }
        }
        return any ? Double(total) : nil
    }

    /// The words that show a route or a dose unit was really said.
    static let said: [String: [String]] = [
        "IV": ["iv", "intravenous", "intravenously"], "IO": ["io", "intraosseous"], "IM": ["im", "intramuscular"],
        "Intranasal": ["intranasal", "nasal", "nasally", "nose"], "Oral": ["oral", "orally", "po", "chewed", "chew", "chewable", "swallowed", "mouth", "tablet"],
        "Sublingual": ["sublingual", "sl", "tongue"], "Subcutaneous": ["subcutaneous", "subq", "sq"], "Nebulizer": ["neb", "nebulizer", "nebulized", "nebuliser"],
        "Inhalation": ["inhaled", "inhaler", "puff", "puffs"], "Nasal cannula": ["cannula", "nc"], "Non-rebreather mask": ["rebreather", "nonrebreather", "nrb", "mask"],
        "mg": ["mg", "milligram", "milligrams", "mig", "migs"], "mcg": ["mcg", "microgram", "micrograms", "mics", "mikes"], "g": ["g", "gram", "grams"],
        "mL": ["ml", "milliliter", "milliliters", "cc", "ccs", "mil", "mils"], "L": ["liter", "liters", "litre", "litres"], "L/min": ["liters", "liter", "lpm", "litres"],
        "units": ["unit", "units"], "puffs": ["puff", "puffs"],
    ]

    private static let filler: Set<String> = ["the", "and", "for", "with", "has", "had", "was", "are", "his", "her", "she", "him", "that", "this", "from", "not", "but", "you", "your", "have", "been", "about", "some", "none", "known", "left", "right"]

    /// Two words that are the same word once spelling and endings are allowed for.
    static func near(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let short = min(a.count, b.count)
        if short >= 4, a.hasPrefix(b) || b.hasPrefix(a) { return true }
        if short >= 5, a.commonPrefix(with: b).count >= 5 { return true }
        return short >= 5 && distance(a, b) <= (short >= 8 ? 2 : 1)
    }

    /// Whether most of what the model wrote can be found in the lines it pointed at.
    static func found(_ value: String, in text: String) -> Bool {
        let said = of(text)
        let wanted = of(value).filter { $0.count >= 3 && !filler.contains($0) }
        guard !wanted.isEmpty else { return of(value).contains { said.contains($0) } }
        let hits = wanted.filter { word in said.contains { near(word, $0) } }.count
        return hits * 2 >= wanted.count
    }

    /// Brand names and crew shorthand, and the drug each one is.
    static let alias: [String: String] = [
        "zofran": "ondansetron", "narcan": "naloxone", "gravol": "dimenhydrinate", "benadryl": "diphenhydramine", "tylenol": "acetaminophen",
        "advil": "ibuprofen", "versed": "midazolam", "ativan": "lorazepam", "valium": "diazepam", "epi": "epinephrine", "adrenaline": "epinephrine",
        "nitro": "nitroglycerin", "asa": "aspirin", "lasix": "furosemide", "ventolin": "albuterol", "salbutamol": "albuterol", "toradol": "ketorolac",
        "d50": "dextrose", "d10": "dextrose", "glucose": "dextrose", "solumedrol": "methylprednisolone", "atrovent": "ipratropium", "o2": "oxygen",
    ]

    /// A drug name, as one word to compare by: "Nitro" and "nitroglycerin" are the same drug.
    static func drug(_ name: String) -> String {
        let joined = of(name).joined()
        if let known = alias[joined] { return known }
        let first = of(name).first ?? joined
        return alias[first] ?? first
    }

    /// Drug names crews use: the same list Whisper leans toward (a copy of transcribe's drugs.txt).
    static let drugs: [String] = {
        guard let url = Bundle.module.url(forResource: "drugs", withExtension: "txt"), let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }()

    /// The real drug a misheard name most likely is: "a spurin" is aspirin, "so fran" is Zofran. The word said
    /// just before it is tried as part of the name too, since a drug is often heard as two words. Nil when the
    /// name is already a known drug, or no single known drug is close enough to say.
    static func corrected(_ name: String, in text: String = "") -> String? {
        let joined = of(name).joined()
        guard joined.count >= 5, !drugs.contains(joined), !drugs.contains(name.lowercased()), alias[joined] == nil else { return nil }
        let said = of(text)
        let before = (of(name).first.flatMap { said.firstIndex(of: $0) }).flatMap { $0 > 0 ? said[$0 - 1] : nil }
        let known = Set(drugs + Array(alias.keys)).filter { !$0.contains(" ") }
        var close: [(String, Int)] = []
        for form in [joined] + (before.map { [$0 + joined] } ?? []) {
            close += known.filter { abs($0.count - form.count) <= 2 }.map { ($0, distance($0, form)) }.filter { $0.1 <= 2 }
        }
        close.sort { $0.1 < $1.1 }
        guard let best = close.first, close.first(where: { $0.0 != best.0 })?.1 != best.1 else { return nil }   // two equally close: do not pick
        return best.0
    }

    /// Whether a drug the model named was said in the lines it pointed at, by its own name or one that means it.
    static func drugSaid(_ name: String, in text: String) -> Bool {
        let said = of(text), wanted = drug(name)
        let pairs = zip(said, said.dropFirst()).map { $0 + $1 }   // "solu medrol" said as two words
        return (said + pairs).contains { near(drug($0), wanted) || near($0, of(name).first ?? wanted) }
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var before = row[0]
            row[0] = i
            for j in 1...max(b.count, 1) where !b.isEmpty {
                let now = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, before + (a[i - 1] == b[j - 1] ? 0 : 1))
                before = now
            }
        }
        return row[b.count]
    }
}
