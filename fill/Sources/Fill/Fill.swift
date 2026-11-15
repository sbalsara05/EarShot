import Foundation

/// One line of a transcript, as the filling step sees it.
public struct Heard {
    public var text: String
    public var clock: String     // when it was said, like "14:03:22"
    public var seconds: Double   // the same moment as a number, to tell how far apart two lines are
    public var unsure: Bool      // the recogniser doubted this line
    public init(_ text: String, clock: String, seconds: Double, unsure: Bool = false) {
        self.text = text; self.clock = clock; self.seconds = seconds; self.unsure = unsure
    }
}

/// One answer in the report, and where it came from.
public struct Answer: Codable, Equatable {
    public var value: String
    public var line: Int?      // which transcript line it came from, counting from 1
    public var check = false   // the medic should look at this one: a doubted line, a conclusion, or two answers that disagreed
    public var other: String?  // the answer that lost, when two disagreed
}

/// What one run of the filling step produced.
public struct Filled {
    public var answers: [String: Answer] = [:]   // by element, like "eVitals.06#2"
    public var dropped: [String] = []            // what the model proposed and the checks threw out, and why
    public var seconds = 0.0
}

/// Fills a NEMSIS report from a transcript.
///
///                  ┌─ who      patient + history
///   transcript ────┼─ what     situation + scene + disposition + times
///                  ├─ vitals      every reading heard
///                  ├─ medicines   what the crew gave
///                  └─ procedures  what the crew did
///                           │
///                    check each item      (was it really said, on the line cited?)
///                           │
///                    merge + de-dupe ──► answers ──► narrative written from them
///
/// The model only proposes. Every item names the line it came from, and code keeps it only if that line bears
/// it out: a number must have been said there, a drug named there, a choice be one allowed. What fails is left
/// empty for the medic, because a wrong value in a patient record is worse than a missing one.
public final class Filler {
    private let engine: Engine
    public init(_ engine: Engine) { self.engine = engine }

    static let system = """
    You read the transcript of an ambulance call and pull out facts for the patient care report. \
    The transcript was written by speech recognition: some words are misheard. \
    Report only what was said. Never guess, and never fill in a typical value. \
    Every item must give the number of the transcript line it came from. If something was not said, leave it out. \
    Answer with JSON only.
    """

    /// How much transcript one question holds, in characters (about 4,500 tokens). A longer call is read in
    /// overlapping stretches and the answers merged.
    static let window = 14_000, overlap = 6

    /// - progress: (step, of), called before each question to the model.
    public func fill(_ lines: [Heard], progress: (Int, Int) -> Void = { _, _ in }) throws -> Filled {
        let began = Date()
        var out = Filled(), items: [Item] = []
        let stretches = Self.stretches(lines)
        let steps = stretches.count * Pass.all.count + 1
        var step = 0
        for stretch in stretches {
            let transcript = "TRANSCRIPT\n" + stretch.map { "L\($0 + 1) [\(lines[$0].clock)] \(Words.digits(lines[$0].text))" }.joined(separator: "\n") + "\nEND OF TRANSCRIPT\n\n"
            for pass in Pass.all {
                step += 1
                progress(step, steps)
                let reply = try engine.complete(system: Self.system, user: transcript + pass.task, grammar: pass.grammar, maxTokens: pass.most)
                if ProcessInfo.processInfo.environment["FILL_SHOW"] != nil { FileHandle.standardError.write(Data("\(pass.name): \(reply)\n".utf8)) }
                for raw in Self.objects(in: reply) where raw["items"] == nil {
                    switch Check.item(raw, from: pass, lines) {
                    case .keep(let item): items.append(item)
                    case .drop(let why): out.dropped.append("\(pass.name): \(why)")
                    }
                }
            }
        }
        out.answers = Merge.answers(from: items, lines, dropped: &out.dropped)
        progress(steps, steps)
        if let narrative = try narrative(lines, out.answers, dropped: &out.dropped) { out.answers["eNarrative.01"] = narrative }
        out.seconds = Date().timeIntervalSince(began)
        return out
    }

    /// Line indexes, cut into stretches that each fit one question.
    static func stretches(_ lines: [Heard]) -> [[Int]] {
        var out: [[Int]] = [], now: [Int] = [], size = 0
        for (i, line) in lines.enumerated() {
            if size + line.text.count + 20 > window, now.count > overlap {
                out.append(now)
                now = Array(now.suffix(overlap))
                size = now.reduce(0) { $0 + lines[$1].text.count + 20 }
            }
            now.append(i)
            size += line.text.count + 20
        }
        if !now.isEmpty { out.append(now) }
        return out
    }

    /// The flat JSON objects in a reply. Reading them one by one means an answer cut off part way still gives
    /// every item that was finished.
    static func objects(in reply: String) -> [[String: Any]] {
        guard let pattern = try? NSRegularExpression(pattern: #"\{[^{}]*\}"#) else { return [] }
        return pattern.matches(in: reply, range: NSRange(reply.startIndex..., in: reply)).compactMap {
            guard let range = Range($0.range, in: reply) else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(reply[range].utf8))) as? [String: Any]
        }
    }

    // MARK: Narrative

    /// The narrative, written last from the answers already settled, so it cannot disagree with them. A sentence
    /// holding a number that is neither in the transcript nor in the answers is cut. Always marked to be checked.
    private func narrative(_ lines: [Heard], _ answers: [String: Answer], dropped: inout [String]) throws -> Answer? {
        guard !answers.isEmpty else { return nil }
        let facts = Nemsis.sections.flatMap { section in
            (1...Nemsis.sets(of: section, in: answers.mapValues(\.value))).flatMap { set in
                section.fields.compactMap { field in answers[Nemsis.element(field.id, set: set)].map { "\(section.title)\(set > 1 ? " \(set)" : ""), \(field.label): \($0.value)" } }
            }
        }
        let stretch = Self.stretches(lines).last ?? []
        let transcript = "TRANSCRIPT\n" + stretch.map { "L\($0 + 1) [\(lines[$0].clock)] \(Words.digits(lines[$0].text))" }.joined(separator: "\n") + "\nEND OF TRANSCRIPT\n\n"
        let task = """
        TASK: Write the narrative for the patient care report, three to six plain sentences in the past tense: \
        who the patient is and the complaint, what was found, what was done, and where the patient was taken. \
        Use only the facts listed below and what the transcript says. Do not add anything that was not said.

        FACTS
        \(facts.joined(separator: "\n"))

        Answer as {"narrative":"..."}.
        """
        let grammar = #"""
        root ::= "{\"narrative\":\"" char{40,900} "\"}"
        char ::= [^"\\\x7F\x00-\x1F]
        """#
        let reply = try engine.complete(system: Self.system, user: transcript + task, grammar: grammar, maxTokens: 400)
        guard let text = Self.objects(in: reply).first?["narrative"] as? String else {
            dropped.append("narrative: the answer was cut off")
            return nil
        }
        let known = lines.reduce(into: Set<Double>()) { $0.formUnion(Words.numbers(in: $1.text)) }
            .union(answers.values.reduce(into: Set<Double>()) { $0.formUnion(Words.numbers(in: $1.value)) })
        let kept = text.split(separator: ".", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }.filter { sentence in
            let ok = Words.numbers(in: sentence).isSubset(of: known)
            if !ok { dropped.append("narrative: a sentence had a number that was never said: \"\(sentence)\"") }
            return ok && !sentence.isEmpty
        }
        // Decimal points were split as sentence ends; a number like "0.4" is put back together.
        let joined = kept.reduce("") { text, part in
            text.isEmpty ? part : (text.last?.isNumber == true && part.first?.isNumber == true) ? text + "." + part : text + ". " + part
        }
        return joined.isEmpty ? nil : Answer(value: joined + ".", line: nil, check: true)
    }
}

/// One thing the model proposed that passed its check.
struct Item {
    enum What { case field(String), reading(String), medication(drug: String, dose: String?, units: String?, route: String?), procedure(String) }
    var what: What
    var value = ""
    var line: Int      // counting from 1
    var check: Bool
}

// MARK: The four questions

/// One targeted question to the model: a short list of things to find, the shape the answer must take, and a
/// worked example.
struct Pass {
    let name: String
    let fields: [Nemsis.Field]
    let task: String
    let grammar: String
    let most: Int   // tokens the answer may run to

    static let all = [who, what, vitals, medicines, procedures]

    private static func field(_ ids: [String]) -> [Nemsis.Field] { ids.compactMap { Nemsis.fields[$0] } }

    static let shared = #"""
    line ::= [1-9] [0-9]{0,3}
    num ::= [0-9]{1,4} ("." [0-9]{1,3})?
    str ::= "\"" char{1,120} "\""
    char ::= [^"\\\x7F\x00-\x1F]
    """#

    static func oneOf(_ values: [String]) -> String { "(" + values.map { "\"\\\"\($0)\\\"\"" }.joined(separator: " | ") + ")" }

    /// The grammar for a question answered as {"items":[{"line":N,"field":"…","value":…}]}: each field may only
    /// take a value of its own kind.
    private static func grammar(_ fields: [Nemsis.Field], limit: Int) -> String {
        var rules = ["root ::= \"{\\\"items\\\":[\" (item (\",\" item){0,\(limit - 1)})? \"]}\""]
        rules.append("item ::= " + fields.indices.map { "f\($0)" }.joined(separator: " | "))
        for (i, field) in fields.enumerated() {
            let head = "\"{\\\"line\\\":\" line \",\\\"field\\\":\\\"\(field.key ?? "")\\\""
            switch field.kind {
            case .time: rules.append("f\(i) ::= \(head)}\"")
            case .number: rules.append("f\(i) ::= \(head),\\\"value\\\":\" num \"}\"")
            case .choice(let values): rules.append("f\(i) ::= \(head),\\\"value\\\":\" \(oneOf(values)) \"}\"")
            case .text, .judged, .drug: rules.append("f\(i) ::= \(head),\\\"value\\\":\" str \"}\"")
            }
        }
        return (rules + [shared]).joined(separator: "\n")
    }

    private static func list(_ fields: [Nemsis.Field]) -> String {
        fields.map { field in
            var line = "- \(field.key ?? ""): \(field.hint)"
            if case .choice(let values) = field.kind { line += ". One of: " + values.joined(separator: ", ") }
            if case .time = field.kind { line += " (give the line only)" }
            return line
        }.joined(separator: "\n")
    }

    private static func task(_ title: String, _ rules: String, _ fields: [Nemsis.Field], lines: String, answer: String) -> String {
        """
        TASK: \(title)
        \(rules)
        \(fields.isEmpty ? "" : "Fields:\n" + list(fields) + "\n")
        Example
        \(lines)
        Answer: \(answer)

        Now answer for the transcript above. Use its own line numbers.
        """
    }

    static let who: Pass = {
        let fields = field(["ePatient.03", "ePatient.02", "ePatient.15", "ePatient.16", "ePatient.25", "eHistory.06", "eHistory.12", "eHistory.08"])
        return Pass(name: "who", fields: fields, task: task(
            "Who the patient is, and their history.",
            "List one item for each fact that was said. Write numbers as digits. Leave out anything not said. Home medicines are what the patient already takes, not what the crew gives.",
            fields,
            lines: "L1 [09:10:02] This is Dana, 34 year old male, short of breath since this morning.\nL2 [09:10:15] He has asthma, takes albuterol, no known allergies.",
            answer: #"{"items":[{"line":1,"field":"first_name","value":"Dana"},{"line":1,"field":"age","value":34},{"line":1,"field":"age_units","value":"Years"},{"line":1,"field":"sex","value":"Male"},{"line":2,"field":"history","value":"asthma"},{"line":2,"field":"home_medications","value":"albuterol"},{"line":2,"field":"allergies","value":"none"}]}"#),
            grammar: grammar(fields, limit: 14), most: 500)
    }()

    static let what: Pass = {
        let fields = field(["eSituation.04", "eSituation.05", "eSituation.06", "eSituation.09", "eSituation.07", "eSituation.11", "eScene.09", "eDisposition.01", "eDisposition.17",
                            "eTimes.05", "eTimes.06", "eTimes.09", "eTimes.11"])
        return Pass(name: "what", fields: fields, task: task(
            "What is wrong, where, and where the patient is going.",
            "List one item for each fact that was said. Write numbers as digits. Leave out anything not said. For a time, give only the line where the crew says it.",
            fields,
            lines: "L1 [09:02:10] Medic 4 is en route.\nL2 [09:09:40] We're on scene at the house.\nL3 [09:10:02] 34 year old male, short of breath for 2 hours, chest feels tight.\nL4 [09:21:30] Looks like an asthma attack. Taking him to Saint Mary's, no lights.",
            answer: #"{"items":[{"line":1,"field":"en_route"},{"line":2,"field":"on_scene"},{"line":2,"field":"location_type","value":"Home"},{"line":3,"field":"complaint","value":"short of breath"},{"line":3,"field":"duration","value":2},{"line":3,"field":"duration_units","value":"Hours"},{"line":3,"field":"symptom","value":"chest feels tight"},{"line":3,"field":"body_area","value":"Chest"},{"line":4,"field":"impression","value":"asthma attack"},{"line":4,"field":"destination","value":"Saint Mary's"},{"line":4,"field":"transport_mode","value":"Non-emergent"},{"line":4,"field":"left_scene"}]}"#),
            grammar: grammar(fields, limit: 16), most: 600)
    }()

    static let vitals: Pass = {
        let fields = field(["eVitals.06", "eVitals.07", "eVitals.10", "eVitals.14", "eVitals.12", "eVitals.18", "eVitals.24", "eVitals.23", "eVitals.27"])
        return Pass(name: "vitals", fields: fields, task: task(
            "Vital signs.",
            "List one item for every reading that was said, each time it was taken, in the order said. Leave out anything not said. A dose of medicine is not a vital sign.",
            fields,
            lines: "L5 [09:12:00] B P 140 over 90, pulse 102, sats 89 percent.\nL6 [09:12:20] Resps 28, sugar is 110.\nL9 [09:20:00] Repeat pressure 132 over 84.",
            answer: #"{"items":[{"line":5,"field":"bp_systolic","value":140},{"line":5,"field":"bp_diastolic","value":90},{"line":5,"field":"heart_rate","value":102},{"line":5,"field":"spo2","value":89},{"line":6,"field":"resp_rate","value":28},{"line":6,"field":"glucose","value":110},{"line":9,"field":"bp_systolic","value":132},{"line":9,"field":"bp_diastolic","value":84}]}"#),
            grammar: grammar(fields, limit: 40), most: 1000)
    }()

    static let medicines: Pass = {
        let grammar = """
        root ::= "{\\"items\\":[" (item ("," item){0,11})? "]}"
        item ::= "{\\"line\\":" line ",\\"drug\\":" str ",\\"dose\\":" (num | "null") ",\\"units\\":" (\(oneOf(Nemsis.doseUnits)) | "null") ",\\"route\\":" (\(oneOf(Nemsis.routes)) | "null") "}"
        \(shared)
        """
        return Pass(name: "medicines", fields: [], task: task(
            "Medicines the crew gave on this call.",
            """
            List one item for each medicine the crew gave. Do not list medicines the patient takes at home, or ones only asked about.
            Write the drug name as it was said. Use null for a dose, unit or route that was not said: do not fill in the usual one.
            Units, one of: \(Nemsis.doseUnits.joined(separator: ", ")). Route, one of: \(Nemsis.routes.joined(separator: ", ")).
            """,
            [],
            lines: "L7 [09:13:05] Albuterol 2.5 milligrams by nebulizer.\nL10 [09:16:00] 125 of solu medrol I V.\nL12 [09:18:30] He took his own inhaler before we got here.",
            answer: #"{"items":[{"line":7,"drug":"albuterol","dose":2.5,"units":"mg","route":"Nebulizer"},{"line":10,"drug":"solu medrol","dose":125,"units":null,"route":"IV"}]}"#),
            grammar: grammar, most: 600)
    }()

    static let procedures: Pass = {
        let grammar = """
        root ::= "{\\"items\\":[" (item ("," item){0,11})? "]}"
        item ::= "{\\"line\\":" line ",\\"name\\":" str "}"
        \(shared)
        """
        return Pass(name: "procedures", fields: [], task: task(
            "Procedures the crew did on this call.",
            "List one item for each procedure the crew did: starting an IV (often said as a needle gauge and a place, like \"18 gauge in the left AC\"), a 12-lead ECG, oxygen, a breathing treatment set up, splinting, bandaging, CPR, and so on. Name it plainly with the details said. Giving a medicine is not a procedure. Do not list anything that was only talked about.",
            [],
            lines: "L8 [09:14:40] 20 gauge I V in the right hand.\nL9 [09:15:10] 12 lead shows sinus tach.\nL11 [09:17:00] Put him on 4 liters by nasal cannula.",
            answer: #"{"items":[{"line":8,"name":"IV, 20 gauge, right hand"},{"line":9,"name":"12 lead ECG"},{"line":11,"name":"oxygen, 4 liters, nasal cannula"}]}"#),
            grammar: grammar, most: 500)
    }()
}

// MARK: Checking what the model proposed

enum Check {
    enum Verdict { case keep(Item), drop(String) }

    /// Words that show a line really says what a time or a choice claims.
    private static let signs: [String: [String]] = [
        "en_route": ["route", "enroute", "responding", "way"], "on_scene": ["scene", "arrived", "arriving", "arrive"],
        "left_scene": ["transporting", "transport", "leaving", "rolling", "departing", "taking", "route"],
        "at_destination": ["hospital", "ed", "er", "emergency", "arrived", "destination"],
        "Female": ["female", "woman", "she", "her", "lady", "girl"], "Male": ["male", "man", "he", "his", "him", "gentleman", "boy"],
        "Emergent": ["lights", "sirens", "emergent", "code", "priority"], "Non-emergent": ["nonemergent", "routine", "non"],
        "Chest": ["chest"], "Abdomen": ["abdomen", "abdominal", "belly", "stomach"], "Back": ["back"], "Head": ["head"], "Neck": ["neck"],
        "Extremity-Lower": ["leg", "knee", "ankle", "foot", "hip", "thigh"], "Extremity-Upper": ["arm", "shoulder", "wrist", "hand", "elbow"],
        "Genitalia": ["groin", "genital", "genitals"], "General/Global": ["all", "everywhere", "whole"],
        "Home": ["home", "house", "apartment", "residence", "bedroom", "kitchen", "bathroom"], "Street or highway": ["street", "highway", "road", "intersection", "car", "vehicle"],
        "Business": ["store", "office", "restaurant", "work", "shop"], "Healthcare facility": ["clinic", "nursing", "facility", "doctor"], "School": ["school"],
        "Public place": ["park", "mall", "gym", "church", "station"], "Other": [],
        // A reading is only a reading if the line says what was measured: "97 on 2 liters" is not a breathing rate.
        "bp_systolic": ["bp", "pressure", "over", "systolic"], "bp_diastolic": ["bp", "pressure", "over", "diastolic"],
        "heart_rate": ["heart", "pulse", "rate", "hr", "tach", "tachy", "bpm"], "resp_rate": ["resps", "resp", "respirations", "respiratory", "breathing", "breaths", "rr"],
        "spo2": ["sats", "sat", "sat's", "saturation", "ox", "oxygen", "spo2", "o2", "percent"], "glucose": ["sugar", "glucose", "bgl", "glucometer"],
        "temperature": ["temp", "temperature", "fever"], "gcs": ["gcs", "glasgow"], "pain": ["pain"],
    ]
    /// Answers that mean "nothing was said". Only an allergy may be "none".
    private static let empty: Set<String> = ["none", "n/a", "na", "unknown", "not stated", "not said", "nil", "null", "no"]

    static func item(_ raw: [String: Any], from pass: Pass, _ lines: [Heard]) -> Verdict {
        guard let line = (raw["line"] as? NSNumber)?.intValue, (1...lines.count).contains(line) else { return .drop("no such line: \(raw)") }
        // What was said on the line cited and the ones either side: a sentence often runs over a pause.
        let near = ((line - 2)...line).filter { lines.indices.contains($0) }.map { lines[$0].text }.joined(separator: " ")
        let unsure = lines[line - 1].unsure

        if pass.name == "medicines" || pass.name == "procedures" {
            if pass.name == "procedures" {
                guard let name = (raw["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return .drop("a procedure with no name") }
                // A procedure is often named by what was done ("eighteen gauge in the left AC"), so its name is a
                // conclusion: kept, and marked to be checked unless the words themselves were said.
                return .keep(Item(what: .procedure(name), line: line, check: unsure || !Words.found(name, in: near)))
            }
            guard let drug = (raw["drug"] as? String)?.trimmingCharacters(in: .whitespaces), !drug.isEmpty else { return .drop("a medication with no name") }
            guard Words.drugSaid(drug, in: near) else { return .drop("\"\(drug)\" was not said on line \(line)") }
            var check = unsure, dose: String?
            // A misheard name is put right when one known drug is plainly meant, and marked to be checked.
            let name = Words.corrected(drug, in: near) ?? drug
            if name != drug { check = true }
            if let number = raw["dose"] as? NSNumber {
                if Words.numbers(in: near).contains(number.doubleValue) { dose = text(number) } else { check = true }   // the drug stands; the dose is left for the medic
            }
            // A unit or a route is kept only if it was said. A crew says "324 of aspirin"; the medic adds the unit.
            let words = Words.of(near)
            func said(_ value: Any?) -> String? { (value as? String).flatMap { name in Words.said[name]?.contains(where: { words.contains($0) }) == true ? name : nil } }
            return .keep(Item(what: .medication(drug: name, dose: dose, units: dose == nil ? nil : said(raw["units"]), route: said(raw["route"])), line: line, check: check))
        }

        guard let key = raw["field"] as? String, let field = pass.fields.first(where: { $0.key == key }) else { return .drop("no such field: \(raw)") }
        let what: Item.What = pass.name == "vitals" ? .reading(field.id) : .field(field.id)
        let words = Words.of(near)
        switch field.kind {
        case .time:
            // A time is the clock of one line, so that line itself must say it; the line beside it will not do.
            let own = Words.of(lines[line - 1].text)
            guard signs[key]?.contains(where: { own.contains($0) }) == true else { return .drop("\(key): line \(line) does not say so") }
            return .keep(Item(what: what, value: lines[line - 1].clock, line: line, check: unsure))
        case .number(let range):
            guard let number = raw["value"] as? NSNumber else { return .drop("\(key) is not a number") }
            guard range.contains(number.doubleValue) else { return .drop("\(key) \(number) is outside \(range)") }
            guard Words.numbers(in: near).contains(number.doubleValue) else { return .drop("\(key) \(number) was not said on line \(line)") }
            if let needed = signs[key], !needed.contains(where: { words.contains($0) }) { return .drop("\(key) \(number): line \(line) does not say what was measured") }
            return .keep(Item(what: what, value: text(number), line: line, check: unsure))
        case .choice(let values):
            guard let value = raw["value"] as? String, values.contains(value) else { return .drop("\(key) is not one of its choices") }
            // A choice is kept only when the line bears it out; a choice the model reasoned its way to is dropped.
            guard signs[value].map({ $0.contains { words.contains($0) } }) ?? Words.found(value, in: near) else { return .drop("\(key) \(value) was not said on line \(line)") }
            return .keep(Item(what: what, value: value, line: line, check: unsure))
        case .judged:
            guard let value = (raw["value"] as? String)?.trimmingCharacters(in: .whitespaces), !value.isEmpty, !empty.contains(value.lowercased()) else { return .drop("\(key) is empty") }
            return .keep(Item(what: what, value: value, line: line, check: unsure || !Words.found(value, in: near)))
        case .text, .drug:
            guard let value = (raw["value"] as? String)?.trimmingCharacters(in: .whitespaces), !value.isEmpty, key == "allergies" || !empty.contains(value.lowercased()) else { return .drop("\(key) is empty") }
            guard Words.found(value, in: near) else { return .drop("\(key) \"\(value)\" was not said on line \(line)") }
            return .keep(Item(what: what, value: value, line: line, check: unsure))
        }
    }

    static func text(_ number: NSNumber) -> String {
        let value = number.doubleValue
        return value == value.rounded() ? String(Int(value)) : String(value)
    }
}

// MARK: Merging and de-duping

/// Turns everything the four questions found into one final set of answers.
enum Merge {
    static func answers(from items: [Item], _ lines: [Heard], dropped: inout [String]) -> [String: Answer] {
        var out: [String: Answer] = [:]
        func time(_ line: Int) -> Double { lines[line - 1].seconds }

        // One answer for each single field. Where items disagree, the one from a line the recogniser trusted
        // wins (then the earliest), it is marked to be checked, and the loser is kept beside it.
        var single: [String: [Item]] = [:]
        for item in items { if case .field(let id) = item.what { single[id, default: []].append(item) } }
        // What today's call is about, to tell it from the patient's past.
        let today = items.compactMap { item -> String? in
            if case .field(let id) = item.what, id == "eSituation.04" || id == "eSituation.09" { return item.value } else { return nil }
        }
        for (id, found) in single {
            // History, allergies and home medicines are lists: what was said in different places is joined, not
            // chosen between. Today's complaint is not history.
            if ["eHistory.06", "eHistory.08", "eHistory.12"].contains(id) {
                var parts: [Item] = []
                for item in found.sorted(by: { $0.line < $1.line }) {
                    if id == "eHistory.08", today.contains(where: { Words.found(item.value, in: $0) || Words.found($0, in: item.value) }) {
                        dropped.append("history \"\(item.value)\" is today's complaint")
                        continue
                    }
                    if !parts.contains(where: { Words.found(item.value, in: $0.value) }) { parts.append(item) }
                }
                guard let first = parts.first else { continue }
                let kept = parts.prefix(4)
                out[id] = Answer(value: kept.map(\.value).joined(separator: ", "), line: first.line, check: kept.contains { $0.check } || Set(kept.map(\.line)).count > 1)
                continue
            }
            let ranked = found.sorted { ($0.check ? 1 : 0, $0.line) < ($1.check ? 1 : 0, $1.line) }
            let best = ranked[0]
            let rival = ranked.first { $0.value.lowercased() != best.value.lowercased() }
            out[id] = Answer(value: best.value, line: best.line, check: best.check || rival != nil, other: rival?.value)
        }
        // "69 years young" is an age, not how long the complaint has lasted.
        if let age = out["ePatient.15"], let lasted = out["eSituation.05"], age.line == lasted.line, age.value == lasted.value {
            out["eSituation.05"] = nil
            dropped.append("duration \(lasted.value) is the patient's age")
        }
        // A unit means nothing without its number.
        for (unit, number) in [("ePatient.16", "ePatient.15"), ("eSituation.06", "eSituation.05")] where out[number] == nil { out[unit] = nil }

        // Readings become sets of vitals. A reading said twice over (the same value again within a minute) is
        // one reading. A new set starts when a kind of reading comes round again, or two minutes have passed.
        var sets: [[Item]] = []
        var seen: [(id: String, value: String, at: Double)] = []
        for item in items.sorted(by: { $0.line < $1.line }) {
            guard case .reading(let id) = item.what else { continue }
            if seen.contains(where: { $0.id == id && $0.value == item.value && abs($0.at - time(item.line)) <= 60 }) { continue }
            seen.append((id, item.value, time(item.line)))
            let repeats = sets.last?.contains { if case .reading(id) = $0.what { return true } else { return false } } ?? true
            if repeats || time(item.line) - time(sets[sets.count - 1][0].line) > 120 { sets.append([]) }
            sets[sets.count - 1].append(item)
        }
        for (n, set) in sets.enumerated() {
            out[Nemsis.element("eVitals.01", set: n + 1)] = Answer(value: lines[set[0].line - 1].clock, line: set[0].line, check: false)
            for item in set { if case .reading(let id) = item.what { out[Nemsis.element(id, set: n + 1)] = Answer(value: item.value, line: item.line, check: item.check) } }
        }

        // Medications. The same drug and dose named again is one entry; if the two were more than two minutes
        // apart it may have been given twice, so that entry is marked to be checked.
        var given: [(item: Item, drug: String, dose: String?, units: String?, route: String?)] = []
        for item in items.sorted(by: { $0.line < $1.line }) {
            guard case .medication(let drug, let dose, let units, let route) = item.what else { continue }
            if let i = given.firstIndex(where: { Words.drug($0.drug) == Words.drug(drug) && ($0.dose == dose || $0.dose == nil || dose == nil) }) {
                if time(item.line) - time(given[i].item.line) > 120 { given[i].item.check = true }
                given[i].dose = given[i].dose ?? dose; given[i].units = given[i].units ?? units; given[i].route = given[i].route ?? route
                continue
            }
            given.append((item, drug, dose, units, route))
        }
        for (n, one) in given.enumerated() {
            func put(_ id: String, _ value: String?) { if let value { out[Nemsis.element(id, set: n + 1)] = Answer(value: value, line: one.item.line, check: one.item.check) } }
            put("eMedications.03", one.drug); put("eMedications.05", one.dose); put("eMedications.06", one.units); put("eMedications.04", one.route)
            put("eMedications.01", lines[one.item.line - 1].clock)
        }

        // Procedures. The same one named again on the same or the next line is one entry.
        var done: [(item: Item, name: String)] = []
        for item in items.sorted(by: { $0.line < $1.line }) {
            guard case .procedure(let name) = item.what else { continue }
            // Giving a medicine is not a procedure: one that names a drug already listed is left out.
            if given.contains(where: { Words.drugSaid($0.drug, in: name) }) || Words.of(name).contains(where: { Words.alias[$0] != nil || Words.drugs.contains($0) }) {
                dropped.append("procedure \"\(name)\" is a medicine")
                continue
            }
            if done.contains(where: { abs($0.item.line - item.line) <= 1 && (Words.found(name, in: $0.name) || Words.found($0.name, in: name)) }) { continue }
            done.append((item, name))
        }
        for (n, one) in done.enumerated() {
            out[Nemsis.element("eProcedures.03", set: n + 1)] = Answer(value: one.name, line: one.item.line, check: one.item.check)
            out[Nemsis.element("eProcedures.01", set: n + 1)] = Answer(value: lines[one.item.line - 1].clock, line: one.item.line, check: one.item.check)
        }
        return out
    }
}
