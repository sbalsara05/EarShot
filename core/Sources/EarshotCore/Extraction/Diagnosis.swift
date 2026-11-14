import Foundation

/// Earshot documents; it never states a diagnosis. Free-text values (found,
/// chief complaint, dispatch reason, alert type, rhythm) that contain a
/// diagnostic term are not turned into fields. The words stay in the raw
/// transcript, which the medic can read.
public enum Diagnosis {
    static let terms: [String] = [
        "stemi", "nstemi", "st elevation", "st depression", "mi", "myocardial infarction", "heart attack", "acs", "acute coronary",
        "stroke", "cva", "tia", "brain bleed", "intracranial", "anaphylaxis", "anaphylactic", "sepsis", "septic", "overdose", "od",
        "pulmonary embolism", "pe", "pneumonia", "dka", "ketoacidosis", "aortic dissection", "dissection", "aaa", "appendicitis",
        "fracture", "broken", "concussion", "tbi", "pneumothorax", "tension pneumo", "chf exacerbation", "copd exacerbation",
        "asthma attack", "hypoglycemia", "hyperglycemia", "ectopic", "eclampsia", "preeclampsia", "status epilepticus",
        "cardiac arrest", "arrhythmia", "dvt", "gi bleed", "ich", "sah", "cardiac tamponade", "hypovolemic shock", "septic shock", "shock",
        "hemorrhagic shock", "exacerbation", "whiplash", "atrial fibrillation", "afib", "a fib", "rvr", "svt", "vtach", "v tach", "vfib", "v fib",
        "opioid overdose", "hypoglycemic", "hyperglycemic", "sprain", "dislocation", "seizure disorder", "epilepsy",
    ]
    static let rx: NSRegularExpression = {
        let alts = terms.sorted { $0.count > $1.count }.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        return try! NSRegularExpression(pattern: #"\b(?:"# + alts + #")\b"#, options: [.caseInsensitive])
    }()
    public static func contains(_ s: String) -> Bool {
        rx.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }
}
