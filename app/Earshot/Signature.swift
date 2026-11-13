import SwiftUI

/// How a call was signed: drawn with a finger, or a typed name.
enum Signature: Codable {
    case drawn([[CGPoint]])   // finger strokes, in the pad's own coordinates
    case typed(String)
}

/// Shows a signature inside whatever frame it is given. A drawn one is scaled to fit.
struct SignatureView: View {
    var signature: Signature?

    var body: some View {
        switch signature {
        case .typed(let name):
            Text(name).font(.system(size: 30, design: .serif).italic()).lineLimit(1).minimumScaleFactor(0.4)
                .accessibilityLabel("Signed \(name)")
        case .drawn(let strokes):
            Canvas { ctx, size in
                let points = strokes.flatMap { $0 }
                guard let left = points.map(\.x).min(), let right = points.map(\.x).max(),
                      let top = points.map(\.y).min(), let bottom = points.map(\.y).max() else { return }
                let scale = min((size.width - 4) / max(right - left, 1), (size.height - 4) / max(bottom - top, 1))
                for stroke in strokes {
                    var path = Path()
                    path.addLines(stroke.map { CGPoint(x: ($0.x - left) * scale + 2, y: ($0.y - top) * scale + 2) })
                    ctx.stroke(path, with: .color(.ink), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
            .accessibilityLabel("Handwritten signature")
        case nil:
            EmptyView()
        }
    }
}

/// A two-way switch in the app's pill style.
struct Choice: View {
    var first: String, second: String
    @Binding var isSecond: Bool
    var fill = Color.bg

    var body: some View {
        HStack(spacing: 4) {
            ForEach([false, true], id: \.self) { option in
                Button(option ? second : first) { isSecond = option }
                    .font(geist(16, 600))
                    .foregroundStyle(isSecond == option ? Color.bg : .dim)
                    .padding(.horizontal, 22).frame(height: 44)
                    .background(isSecond == option ? Color.ink : .clear, in: Capsule())
                    .accessibilityAddTraits(isSecond == option ? .isSelected : [])
            }
        }
        .buttonStyle(.plain)
        .padding(4)
        .background(fill, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.line))
        .fixedSize()
    }
}

/// The last step of a call. Nothing is signed until there is a drawn or typed signature.
struct SignatureSheet: View {
    var sign: (Signature) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var typing = false
    @State private var name = ""
    @State private var strokes: [[CGPoint]] = []
    @State private var drawing = false

    private var signature: Signature? {
        if typing {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .typed(trimmed)
        }
        return strokes.contains { $0.count > 1 } ? .drawn(strokes) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                Text("Sign off").font(doto(fit(40, 30)))
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(Pill(fill: nil, height: 44, size: 16))
            }
            Text("Sign with your finger, or type your name.").font(geist(fit(19, 17))).foregroundStyle(Color.dim)
            Choice(first: "Draw", second: "Type", isSecond: $typing, fill: .panel)

            if typing {
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Name", text: $name, prompt: Text("Your full name").foregroundColor(.dim))
                        .font(.system(size: fit(40, 32), design: .serif).italic())
                        .tint(.yellow).textInputAutocapitalization(.words).autocorrectionDisabled()
                        .frame(height: 72)
                    Color.ghost.frame(height: 1)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity).frame(height: fit(260, 200))
                .panel()
            } else {
                Canvas { ctx, _ in
                    for stroke in strokes {
                        var path = Path()
                        path.addLines(stroke)
                        ctx.stroke(path, with: .color(.ink), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    }
                }
                .frame(maxWidth: .infinity).frame(height: fit(260, 200))
                .overlay(alignment: .bottom) { DottedRule(color: .outline).padding(.horizontal, 24).padding(.bottom, 44) }
                .overlay(alignment: .topTrailing) {
                    if !strokes.isEmpty {
                        Button("Clear") { strokes = [] }.font(geist(15, 600)).foregroundStyle(Color.dim).padding(16)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { touch in
                    if !drawing {
                        drawing = true
                        strokes.append([])
                    }
                    strokes[strokes.count - 1].append(touch.location)
                }.onEnded { _ in drawing = false })
                .panel()
                .accessibilityLabel("Signature pad")
            }

            Spacer(minLength: 0)
            Button("Sign off") {
                guard let signature else { return }
                sign(signature)
                dismiss()
            }
            .buttonStyle(Pill(grow: true))
            .disabled(signature == nil)
            .opacity(signature == nil ? 0.35 : 1)
        }
        .padding(.horizontal, fit(40, 20)).padding(.top, fit(36, 28)).padding(.bottom, fit(32, 12))
        .font(geist(17))
        .foregroundStyle(Color.ink)
        .background(Color.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}
