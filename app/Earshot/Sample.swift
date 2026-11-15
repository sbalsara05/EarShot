#if DEBUG
import Foundation

/// A made-up call with everything a report needs said out loud, for trying the whole path from transcript to
/// XML without recording one: times, who the patient is, history, three sets of vitals, four medicines, two
/// procedures, and where the patient went. Debug builds only. It has no audio, so its lines cannot be played.
/// The same transcript is `fill/Truth/full.txt`.
extension Call {
    /// (seconds into the call, what was said)
    private static let said: [(Double, String)] = [
        (0, "Medic 4 is en route to 12 Oak Street for chest pain."),
        (395, "Medic 4 on scene."),
        (440, "Hi sir, I'm a paramedic. What's your name?"),
        (444, "Robert Hayes."),
        (450, "Okay Robert, how old are you?"),
        (453, "I'm 58."),
        (460, "We're at the patient's house. 58 year old male, found sitting in the kitchen."),
        (470, "What's going on today?"),
        (474, "I've got this crushing chest pain, it started about 30 minutes ago."),
        (485, "Does it go anywhere?"),
        (488, "Into my left arm and my jaw."),
        (495, "Any medical history?"),
        (498, "High blood pressure and high cholesterol. I had a stent put in 2 years ago."),
        (510, "Do you take any medications?"),
        (513, "Lisinopril and atorvastatin."),
        (520, "Any allergies to medications?"),
        (523, "Sulfa drugs."),
        (540, "On a scale of 0 to 10, how bad is the pain?"),
        (544, "It's an 8."),
        (560, "First set of vitals. BP 162 over 98, heart rate 108, respirations 22, sats 93 percent on room air."),
        (575, "Blood sugar is 124. Temp 98.4. GCS 15."),
        (600, "Giving 324 of aspirin, chewed."),
        (630, "12 lead shows ST elevation in the inferior leads. This looks like a STEMI."),
        (660, "18 gauge IV in the left AC."),
        (690, "Nitro 0.4 sublingual."),
        (720, "Putting him on oxygen, 4 liters by nasal cannula."),
        (840, "Robert, how's the pain now?"),
        (843, "Maybe a 5."),
        (860, "Second set. BP 144 over 88, heart rate 96, sats 97 percent, respirations 18."),
        (900, "4 milligrams of Zofran IV for the nausea."),
        (960, "Medic 4 is leaving the scene, transporting to Saint Vincent Hospital, lights and sirens."),
        (1260, "Third set of vitals. BP 138 over 84, pulse 90, sats 98 percent. Pain is a 3."),
        (1500, "Medic 4, we've arrived at the hospital."),
    ]

    /// The sample call, as if it ended a quarter of an hour ago and Complete has just been tapped.
    static func sample() -> Call {
        let start = Date().addingTimeInterval(-40 * 60)
        var items = [Item(time: start.addingTimeInterval(396), place: Place(latitude: 42.26260, longitude: -71.80230, accuracy: 8, street: "12 Oak Street", city: "Worcester", county: "Worcester", state: "MA", zip: "01608"))]
        items += said.map { Item(time: start.addingTimeInterval($0.0), text: $0.1, end: start.addingTimeInterval($0.0 + 3), source: .whisper, confidence: 0.93) }
        items.sort { $0.time < $1.time }
        var call = Call(start: start, recordings: [Recording(start: start, end: start.addingTimeInterval(1510), items: items)])
        call.whisper = true
        return call
    }
}

extension Model {
    /// Puts the sample call among the calls waiting for sign-off, once, and fills its report the way a completed
    /// call's is. Deleting it does not bring it back.
    func seedSample() {
        guard !UserDefaults.standard.bool(forKey: "sample-call-1") else { return }
        UserDefaults.standard.set(true, forKey: "sample-call-1")
        let call = Call.sample()
        review.insert(call, at: 0)
        save()
        finishUp(call.id)
    }
}
#endif
