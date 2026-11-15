import Foundation
import Fill

/// Where one answer in a call's report came from, when the transcript filled it in. An answer the medic typed
/// has none.
struct Evidence: Codable, Equatable {
    var line: Item.ID?     // the transcript row it was read from. Nil for the narrative, which is written from the answers
    var check = false      // the medic should look at this one
    var other: String?     // a second answer the transcript also gave
}

/// How far along the filling of one call's report is.
struct Filling: Equatable {
    var step = 0, of = 0   // which question the model is on. 0: the model is still being loaded
    var text: String { step == 0 ? "Getting ready" : "Question \(step) of \(of)" }
    /// The share done, 0 to 1. Loading the model counts as a first small step, so the bar is never empty.
    var done: Double { of == 0 ? 0.04 : 0.04 + 0.96 * Double(step - 1) / Double(of) }
}

/// Fills a call's NEMSIS report from its transcript, with a language model on this device (see the `Fill` package).
///
///   transcript ─► five short questions to the model ─► each answer checked against the line it cites ─► report
///
/// The model is 2.7 GB in memory, so it is loaded for one call, used, and let go again.
final class Reporter {
    /// The models to look for, best first, each in the app's Documents folder (copied in with Finder) and then
    /// in the app itself.
    static let models = ["Qwen3.5-4B-Q4_K_M"]

    var file: URL? {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return Self.models.flatMap { [documents.appending(path: "\($0).gguf"), Bundle.main.url(forResource: $0, withExtension: "gguf")] }
            .compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
    /// The model that fills reports on this device, like "Qwen3.5-4B-Q4_K_M". Nil: there is none, and reports are filled by hand.
    var name: String? { file?.deletingPathExtension().lastPathComponent }

    private let queue = DispatchQueue(label: "earshot.reporter", qos: .userInitiated)   // one call at a time

    /// - progress: (question, of), on the main queue.
    func fill(_ lines: [Heard], progress: @escaping (Int, Int) -> Void) async throws -> Filled {
        guard let file else { throw Problem("The language model is not on this \(deviceName), so the report was not filled in.") }
        return try await withCheckedThrowingContinuation { done in
            queue.async {
                do {
                    #if targetEnvironment(simulator)
                    let model = try Llama(file.path, gpu: false)   // the simulator's graphics chip is not a real one
                    #else
                    let model = try Llama(file.path)
                    #endif
                    let filled = try Filler(model).fill(lines) { step, of in DispatchQueue.main.async { progress(step, of) } }
                    #if DEBUG
                    print(String(format: "report: filled in %.0f s; read %d tokens in %.0f s, wrote %d in %.0f s; %d dropped", filled.seconds, model.promptTokens, model.promptSeconds, model.madeTokens, model.makeSeconds, filled.dropped.count))
                    for line in filled.dropped { print("report: dropped \(line)") }
                    #endif
                    done.resume(returning: filled)
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }
}

extension Call {
    /// The rows of the transcript that were spoken, in order: what the model is given, a line each.
    var spoken: [Item] { recordings.flatMap(\.items).filter { !$0.text.isEmpty } }

    /// Puts what the transcript gave into the report. Answers the model gave before are replaced; answers the
    /// medic typed are left alone.
    mutating func take(_ filled: Filled, from lines: [Item], by model: String?) {
        var report = self.report ?? [:], evidence = self.evidence ?? [:]
        for element in evidence.keys { report[element] = nil }
        evidence = [:]
        for (element, answer) in filled.answers where report[element] == nil {
            report[element] = answer.value
            evidence[element] = Evidence(line: answer.line.flatMap { lines.indices.contains($0 - 1) ? lines[$0 - 1].id : nil }, check: answer.check, other: answer.other)
        }
        // The scene's address is not something said: it is where the device was when the call began.
        if let row = recordings.flatMap(\.items).first(where: { $0.place?.street != nil }), let place = row.place {
            for (element, value) in [("eScene.15", place.street), ("eScene.17", place.city), ("eScene.18", place.state), ("eScene.19", place.zip)] where report[element] == nil {
                guard let value, !value.isEmpty else { continue }
                report[element] = value
                evidence[element] = Evidence(line: row.id)
            }
        }
        self.report = report
        self.evidence = evidence
        filledBy = model
        fillNote = nil
    }
}

extension Call {
    /// The call's report as a NEMSIS 3.5.1 XML file, ready to share. Nil if the file could not be written.
    func xml(_ standing: Standing) -> URL? {
        var agency = NemsisXML.Agency()
        agency.number = standing.agencyNumber; agency.stateID = standing.agencyStateID; agency.state = standing.agencyState
        agency.unit = standing.unitNumber; agency.callSign = standing.callSign
        agency.capability = standing.capability; agency.serviceType = standing.serviceType; agency.responseMode = standing.responseMode
        // A time the transcript gave is the moment its line was said, to the second and with its date.
        let rows = Dictionary(uniqueKeysWithValues: recordings.flatMap(\.items).map { ($0.id, $0) })
        var times: [String: Date] = [:]
        for (element, from) in evidence ?? [:] {
            guard case .time = Nemsis.fields[String(element.split(separator: "#")[0])]?.kind, let row = from.line.flatMap({ rows[$0] }) else { continue }
            times[element] = row.time
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let text = NemsisXML.write(report ?? [:], id: id, start: start, end: recordings.last?.end ?? signedAt ?? start, times: times, agency: agency, version: version)
        let name = "Earshot " + stamp(start).replacingOccurrences(of: ":", with: "") + " " + id.uuidString.prefix(8).lowercased() + ".xml"
        let file = FileManager.default.temporaryDirectory.appending(path: name)
        // The file holds patient information: it is encrypted while the device is locked, like the calls themselves.
        guard (try? Data(text.utf8).write(to: file, options: [.atomic, .completeFileProtection])) != nil else { return nil }
        return file
    }
}

/// A clock time with seconds, like "14:03:22": how a line's moment is written in the report.
func stamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
}
