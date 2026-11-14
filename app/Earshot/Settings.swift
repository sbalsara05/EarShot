import SwiftUI

/// One choice in a fixed NEMSIS code list: the code that goes in the file, and the official wording a person reads.
struct Coded: Hashable {
    let code: String, name: String
    init(_ code: String, _ name: String) { self.code = code; self.name = name }
}

/// The values that repeat on every call for one crew and truck, so they are typed once and stamped on every report.
/// Each is named for the NEMSIS 3.5.0 box it fills. An empty string means "not set": nothing is assumed for the medic.
/// ponytail: one crew member and one usual hospital. Add a list of each when a truck has rotating crews or several hospitals.
struct Standing: Codable, Equatable {
    // Agency
    var agencyNumber = ""    // eResponse.01, mandatory
    var agencyName = ""      // eResponse.02
    var agencyStateID = ""   // dAgency.01, mandatory
    var agencyState = ""     // dAgency.04, mandatory
    // Unit
    var unitNumber = ""      // eResponse.13, mandatory
    var callSign = ""        // eResponse.14, mandatory
    var capability = ""      // eResponse.07, mandatory, coded
    var serviceType = ""     // eResponse.05, mandatory, coded
    var responseMode = ""    // eResponse.23, mandatory, coded
    // Crew
    var crewName = ""        // not a NEMSIS box: the name on the sign-off
    var crewID = ""          // eCrew.01
    var crewLevel = ""       // eCrew.02, coded
    var crewRole = ""        // eCrew.03, coded
    // Usual area
    var state = ""           // eScene.18 and eDisposition.05
    var county = ""          // eScene.21
    var hospital = ""        // eDisposition.01
    var hospitalCode = ""    // eDisposition.02

    /// The mandatory ones still empty. A report cannot be complete while any are.
    var missing: Int {
        [agencyNumber, agencyStateID, agencyState, unitNumber, callSign, capability, serviceType, responseMode].filter(\.isEmpty).count
    }
    static let mandatoryCount = 8

    static func load() -> Standing {
        guard let data = UserDefaults.standard.data(forKey: "standing"), let saved = try? JSONDecoder().decode(Standing.self, from: data) else { return Standing() }
        return saved
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "standing") }
    }

    // The code lists, copied from the NEMSIS 3.5.0 data dictionary. The "not recorded" style values are left out:
    // an unset choice says that already.

    static let capabilities = [   // eResponse.07
        Coded("2207015", "Ground Transport (ALS Equipped)"),
        Coded("2207017", "Ground Transport (BLS Equipped)"),
        Coded("2207019", "Ground Transport (Critical Care Equipped)"),
        Coded("2207021", "Non-Transport-Medical Treatment (ALS Equipped)"),
        Coded("2207023", "Non-Transport-Medical Treatment (BLS Equipped)"),
        Coded("2207011", "Air Transport-Helicopter"),
        Coded("2207013", "Air Transport-Fixed Wing"),
        Coded("2207025", "Wheel Chair Van/Ambulette"),
        Coded("2207027", "Non-Transport-No Medical Equipment"),
    ]

    static let serviceTypes = [   // eResponse.05
        Coded("2205001", "Emergency Response (Primary Response Area)"),
        Coded("2205003", "Emergency Response (Intercept)"),
        Coded("2205009", "Emergency Response (Mutual Aid)"),
        Coded("2205005", "Hospital-to-Hospital Transfer"),
        Coded("2205015", "Hospital to Non-Hospital Facility Transfer"),
        Coded("2205017", "Non-Hospital Facility to Non-Hospital Facility Transfer"),
        Coded("2205019", "Non-Hospital Facility to Hospital Transfer"),
        Coded("2205007", "Other Routine Medical Transport"),
        Coded("2205011", "Public Assistance"),
        Coded("2205013", "Standby"),
        Coded("2205021", "Support Services"),
        Coded("2205023", "Non-Patient Care Rescue/Extrication"),
        Coded("2205025", "Crew Transport Only"),
        Coded("2205027", "Transport of Organs or Body Parts"),
        Coded("2205029", "Mortuary Services"),
        Coded("2205031", "Mobile Integrated Health Care Encounter"),
        Coded("2205033", "Evaluation for Special Referral/Intake Programs"),
        Coded("2205035", "Administrative Operations"),
    ]

    static let responseModes = [   // eResponse.23
        Coded("2223001", "Emergent (Immediate Response)"),
        Coded("2223003", "Emergent Downgraded to Non-Emergent"),
        Coded("2223005", "Non-Emergent"),
        Coded("2223007", "Non-Emergent Upgraded to Emergent"),
    ]

    static let crewLevels = [   // eCrew.02
        Coded("9925003", "Emergency Medical Responder (EMR)"),
        Coded("9925005", "Emergency Medical Technician (EMT)"),
        Coded("9925002", "Emergency Medical Technician - Intermediate"),
        Coded("9925001", "Advanced Emergency Medical Technician (AEMT)"),
        Coded("9925007", "Paramedic"),
        Coded("9925033", "Critical Care Paramedic"),
        Coded("9925035", "Community Paramedicine"),
        Coded("9925043", "Registered Nurse"),
        Coded("9925041", "Licensed Practical Nurse (LPN)"),
        Coded("9925037", "Nurse Practitioner"),
        Coded("9925039", "Physician Assistant"),
        Coded("9925027", "Physician"),
        Coded("9925029", "Respiratory Therapist"),
        Coded("9925031", "Student"),
        Coded("9925023", "Other Healthcare Professional"),
        Coded("9925025", "Other Non-Healthcare Professional"),
    ]

    static let crewRoles = [   // eCrew.03
        Coded("2403011", "Primary Patient Caregiver-At Scene"),
        Coded("2403013", "Primary Patient Caregiver-Transport"),
        Coded("2403007", "Other Patient Caregiver-At Scene"),
        Coded("2403009", "Other Patient Caregiver-Transport"),
        Coded("2403001", "Driver/Pilot-Response"),
        Coded("2403003", "Driver/Pilot-Transport"),
        Coded("2403005", "Other"),
    ]
}

// MARK: Settings

struct SettingsScreen: View {
    @Environment(Model.self) private var model

    var body: some View {
        if phone {
            ScrollView { VStack(spacing: 16) { audio; values } }.scrollIndicators(.hidden)
        } else {
            HStack(spacing: 32) { audio; values }
        }
    }

    // MARK: Audio source

    private var audio: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings").font(doto(fit(46, 34)))
            Text("Audio from").font(geist(17, 500)).foregroundStyle(Color.dim).padding(.top, 28).padding(.bottom, 12)
            HStack(spacing: 4) {
                choice("\(deviceName) mic", standIn: true)
                choice("Clip", standIn: false)
            }
            .padding(4)
            .background(Color.bg, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.line))
            Text(note).font(geist(17)).lineSpacing(4).foregroundStyle(noteColor).padding(.top, 18)
            Text("Either way the audio is transcribed and drafted the same. The clip's button and marks work with both.")
                .font(geist(17)).lineSpacing(4).foregroundStyle(Color.dim).padding(.top, 10)
            Text("Transcript by").font(geist(17, 500)).foregroundStyle(Color.dim).padding(.top, 28).padding(.bottom, 8)
            Text(model.recordBy.map { "Whisper \($0)" } ?? "This \(deviceName) only").font(geist(19, 600))
            Text(model.recordBy != nil
                 ? "Words show at once as this \(deviceName) hears them, then Whisper's more careful reading takes their place. Lighter lines are ones to read with care."
                 : "The Whisper model is not in this build, so the transcript is this \(deviceName)'s own. Run transcribe/fetch.sh and build again.")
                .font(geist(17)).lineSpacing(4).foregroundStyle(Color.dim).padding(.top, 8)
            Text("Location").font(geist(17, 500)).foregroundStyle(Color.dim).padding(.top, 28).padding(.bottom, 8)
            HStack(spacing: 10) {
                Circle().fill(model.location == .always ? Color.green : .yellow).frame(width: 10, height: 10)
                Text(locationStatus)
            }
            .font(geist(19, 600)).foregroundStyle(model.location == .always ? Color.green : .yellow)
            Text(locationNote).font(geist(17)).lineSpacing(4).foregroundStyle(Color.dim).padding(.top, 8)
            if model.location == .whileUsing || model.location == .refused {
                Button("Open \(deviceName) Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(Pill(fill: nil, height: 56, size: 17, grow: true)).padding(.top, 14)
            }
            Text("This build").font(geist(17, 500)).foregroundStyle(Color.dim).padding(.top, 28).padding(.bottom, 8)
            Text(Bundle.main.object(forInfoDictionaryKey: "GitBranch") as? String ?? "Unknown branch").font(geist(19, 600))
            Text("Commit \(Bundle.main.object(forInfoDictionaryKey: "GitCommit") as? String ?? "unknown")")
                .font(geist(17)).lineSpacing(4).foregroundStyle(Color.dim).padding(.top, 8)
            Spacer(minLength: 0)
        }
        .padding(fit(36, 24))
        .side()
        .frame(maxHeight: phone ? nil : .infinity, alignment: .topLeading)
        .panel()
    }

    private func choice(_ name: String, standIn: Bool) -> some View {
        let on = model.micStandIn == standIn
        return Button { model.micStandIn = standIn } label: {
            Text(name).font(geist(17, 600)).foregroundStyle(on ? Color.bg : .dim)
                .frame(maxWidth: .infinity).frame(height: 56)
                .background(on ? Color.ink : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// What the choice means right now. It names the microphone that will really be used, not the one asked for.
    private var note: String {
        if model.live == .listening {
            return "This recording is on: \(model.audioLabel). A change applies once it is paused and resumed."
        }
        if !model.micStandIn && !model.clip {
            return "No clip is connected, so the next recording will use the \(deviceName) mic. It switches to the clip's audio once one connects."
        }
        return model.micStandIn
            ? "The next recording will use the \(deviceName) mic."
            : "The next recording will use the audio sent by \(model.clipTitle)."
    }

    private var locationStatus: String {
        switch model.location {
        case .always: "Always allowed"
        case .whileUsing: "Only while the app is open"
        case .refused: "Not allowed"
        case .unasked: "Not asked yet"
        }
    }

    /// What the current permission really means for a call, and how to change it.
    private var locationNote: String {
        switch model.location {
        case .always:
            "During a recording the \(deviceName)'s place is checked once a minute, on screen or off, and added to the transcript when it has moved \(Int(Locator.moved)) metres or more."
        case .whileUsing:
            "Places may stop being logged when the app is off screen or the \(deviceName) is locked. In Settings, tap Location, then Always."
        case .refused:
            "Calls record without places. In Settings, tap Location, then Always."
        case .unasked:
            "The \(deviceName) will ask when the app is next opened."
        }
    }

    private var noteColor: Color { !model.micStandIn && !model.clip && model.live != .listening ? .yellow : .ink }

    // MARK: Standing values

    private var values: some View {
        @Bindable var model = model
        let s = $model.standing
        return VStack(alignment: .leading, spacing: 0) {
            Text("On every report").font(doto(fit(34, 28)))
            Text("Set these once. They are the same on every call, and nobody says them out loud.")
                .font(geist(17)).foregroundStyle(Color.dim).padding(.top, 6)
            HStack(spacing: 10) {
                Circle().fill(model.standing.missing == 0 ? Color.green : .yellow).frame(width: 10, height: 10)
                Text(model.standing.missing == 0
                     ? "All \(Standing.mandatoryCount) values a report must have are set"
                     : "\(model.standing.missing) of the \(Standing.mandatoryCount) values a report must have are not set")
            }
            .font(geist(17, 600)).foregroundStyle(model.standing.missing == 0 ? Color.green : .yellow).padding(.top, 14).padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    heading("Agency")
                    text("Agency number", "eResponse.01", s.agencyNumber, must: true)
                    text("Agency name", "eResponse.02", s.agencyName)
                    text("State ID of the agency", "dAgency.01", s.agencyStateID, must: true)
                    text("State", "dAgency.04", s.agencyState, must: true, hint: "MA")

                    heading("Unit")
                    text("Unit number", "eResponse.13", s.unitNumber, must: true)
                    text("Call sign", "eResponse.14", s.callSign, must: true)
                    pick("Equipped as", "eResponse.07", s.capability, from: Standing.capabilities, must: true)
                    pick("Usual service", "eResponse.05", s.serviceType, from: Standing.serviceTypes, must: true)
                    pick("Usual response", "eResponse.23", s.responseMode, from: Standing.responseModes, must: true)

                    heading("You")
                    text("Name", "sign-off", s.crewName)
                    text("Licence number", "eCrew.01", s.crewID)
                    pick("Level", "eCrew.02", s.crewLevel, from: Standing.crewLevels)
                    pick("Usual role", "eCrew.03", s.crewRole, from: Standing.crewRoles)

                    heading("Usual area")
                    text("State", "eScene.18", s.state, hint: "MA")
                    text("County", "eScene.21", s.county)
                    text("Usual hospital", "eDisposition.01", s.hospital)
                    text("Hospital code", "eDisposition.02", s.hospitalCode)

                    heading("Filled in by the app")
                    fixed("Software", "eRecord.02-04", "Earshot \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    fixed("Report number", "eRecord.01", "New for each call")
                }
                // Room to scroll the last rows up above the keyboard, which covers the lower half of the screen.
                .padding(.bottom, phone ? 320 : 440)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .padding(.top, fit(36, 24)).padding(.horizontal, fit(32, 20)).padding(.bottom, fit(20, 16))
        .frame(maxWidth: .infinity, maxHeight: phone ? nil : .infinity, alignment: .topLeading)
        .panel()
    }

    private func heading(_ name: String) -> some View {
        Text(name).font(geist(15, 600)).foregroundStyle(Color.dim).textCase(.uppercase).kerning(1.2).padding(.top, 26).padding(.bottom, 8)
    }

    /// The left of a row: what the value is, the NEMSIS box it fills, and a yellow dot while a mandatory one is empty.
    private func label(_ name: String, _ box: String, unset: Bool) -> some View {
        HStack(spacing: 10) {
            Circle().fill(unset ? Color.yellow : .clear).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(geist(17, 500))
                Text(box).font(.system(size: 13, design: .monospaced)).foregroundStyle(Color.dim)
            }
        }
        .frame(width: fit(250, 150), alignment: .leading)
    }

    private func row(_ name: String, _ box: String, unset: Bool, @ViewBuilder value: () -> some View) -> some View {
        VStack(spacing: 0) {
            Color.line.frame(height: 1)
            HStack(spacing: 14) {
                label(name, box, unset: unset)
                value().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(minHeight: 60)
        }
    }

    private func text(_ name: String, _ box: String, _ value: Binding<String>, must: Bool = false, hint: String = "Not set") -> some View {
        row(name, box, unset: must && value.wrappedValue.isEmpty) {
            TextField(hint, text: value)
                .font(geist(19, 600)).multilineTextAlignment(.trailing)
                .autocorrectionDisabled().submitLabel(.done)
                .accessibilityLabel(name)
        }
    }

    private func pick(_ name: String, _ box: String, _ value: Binding<String>, from list: [Coded], must: Bool = false) -> some View {
        let chosen = list.first { $0.code == value.wrappedValue }
        return row(name, box, unset: must && chosen == nil) {
            Menu {
                ForEach(list, id: \.self) { item in Button(item.name) { value.wrappedValue = item.code } }
                if chosen != nil { Button("Not set", role: .destructive) { value.wrappedValue = "" } }
            } label: {
                HStack(spacing: 8) {
                    Text(chosen?.name ?? "Not set").font(geist(19, 600)).foregroundStyle(chosen == nil ? Color.dim : .ink)
                        .multilineTextAlignment(.trailing).lineLimit(2)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.dim)
                }
                .frame(maxWidth: .infinity, alignment: .trailing).contentShape(Rectangle())
            }
            .accessibilityLabel(name)
        }
    }

    private func fixed(_ name: String, _ box: String, _ value: String) -> some View {
        row(name, box, unset: false) { Text(value).font(geist(19, 600)).foregroundStyle(Color.dim) }
    }
}
