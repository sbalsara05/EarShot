import Foundation

/// A clock time said aloud about something that was done ("aspirin given at 1410").
///
/// The rules attach it to the medication, vital signs or procedure it belongs to as the field
/// `time_said` ("14:10"). `apply` then makes it the event's time, because the chart should say when
/// the thing was done, not when the medic got round to saying it. When the words were spoken is
/// kept in `heard_at`, the same field a button press uses.
public enum SaidTime {
    public static let field = "time_said"
    /// A dictated time may be this far after the moment it was said (clocks differ a little).
    static let aheadMs: Int64 = 2 * 60_000
    /// ...and at most this far before it. Further back is more likely a misheard number.
    static let backMs: Int64 = 6 * 3_600_000

    /// The call time (ms since the call began) of "HH:MM" said at `heardAt`: the nearest moment with
    /// that clock reading that is not in the future. `guessedHalf` is true when the time was read as
    /// the afternoon although an hour of 12 or less was said ("two ten" heard at 14:25 is 14:10).
    /// Nil when no such moment is within reach; the event then keeps the time it was heard.
    public static func resolve(_ hhmm: String, heardAt: Int64, clock: CallClock) -> (tMs: Int64, guessedHalf: Bool)? {
        let p = hhmm.split(separator: ":")
        guard p.count == 2, let h = Int64(p[0]), let m = Int64(p[1]), (0...23).contains(h), (0...59).contains(m) else { return nil }
        let day: Int64 = 86_400_000
        let local = clock.startEpochMs + heardAt + Int64(clock.tzOffsetSeconds) * 1000
        let midnight = local - ((local % day) + day) % day
        let said = midnight + h * 3_600_000 + m * 60_000
        // The same reading yesterday and tomorrow (a call can cross midnight), and twelve hours on
        // for an hour that could be either half of the day.
        var options: [(at: Int64, guessed: Bool)] = [-day, 0, day].map { (said + $0, false) }
        if h <= 12 { options += [-day, 0, day].map { (said + $0 + (h == 12 ? -12 : 12) * 3_600_000, true) } }
        let ok = options.filter { $0.at - local <= aheadMs && local - $0.at <= backMs }
        guard let best = ok.min(by: { (abs($0.at - local), $0.guessed ? 1 : 0) < (abs($1.at - local), $1.guessed ? 1 : 0) }) else { return nil }
        return (heardAt + (best.at - local), best.guessed)
    }

    /// Moves each heard event that carries a dictated time to that time, and puts the events back
    /// in time order (events at the same time keep the order they had). An event labelled by a
    /// button press keeps the press as its time. A dictated time that cannot be placed, or whose
    /// half of the day was guessed, marks the event "please confirm".
    public static func apply(_ events: [EarshotEvent], clock: CallClock) -> [EarshotEvent] {
        var out = events
        var moved = false
        for i in out.indices {
            guard out[i].source == .heard, let said = out[i].fields[field] else { continue }
            var confirm = true
            if let r = resolve(said, heardAt: out[i].tMs, clock: clock) {
                out[i].fields["heard_at"] = clock.clock(out[i].tMs)
                out[i].tMs = r.tMs
                out[i].time = clock.iso(r.tMs)
                confirm = r.guessedHalf
                moved = true
            }
            if confirm, !(out[i].flags ?? []).contains("confirm") { out[i].flags = (out[i].flags ?? []) + ["confirm"] }
        }
        guard moved else { return out }
        return out.enumerated().sorted { ($0.element.tMs, $0.offset) < ($1.element.tMs, $1.offset) }.map(\.element)
    }
}
