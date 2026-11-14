import SwiftUI

// MARK: Colour and type (from the design's "Logo, colour and type" board)

extension Color {
    init(_ hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    static let bg = Color(0x0C0C0D), ink = Color(0xF1EFEA), dim = Color(0xA5A39E), panel = Color(0x151516)
    static let line = Color(0x2A2A2D), outline = Color(0x4A4A4F), off = Color(0x2B2B2F), mid = Color(0x6B6B70)
    static let ghost = Color(0x3A3A3E), red = Color(0xFF5D4D), green = Color(0x6FD39A), yellow = Color(0xF5C451)
}

/// Both fonts ship as variable files, so the weight is set on the `wght` axis.
private func variable(_ family: String, _ size: CGFloat, _ weight: CGFloat) -> Font {
    let wght = 2003265652 // 'wght'
    let d = UIFontDescriptor(fontAttributes: [
        .family: family,
        UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [wght: weight],
    ])
    return Font(UIFont(descriptor: d, size: size) as CTFont)
}
func doto(_ size: CGFloat) -> Font { variable("Doto", size, 900) }
func geist(_ size: CGFloat, _ weight: CGFloat = 400) -> Font { variable("Geist", size, weight) }

// MARK: iPad and iPhone

/// True on iPhone, which gets the same screens restacked into one portrait column.
let phone = UIDevice.current.userInterfaceIdiom == .phone
let deviceName = phone ? "iPhone" : "iPad"

/// Picks the iPad value or the iPhone value.
func fit<T>(_ pad: T, _ onPhone: T) -> T { phone ? onPhone : pad }

/// Two parts side by side on iPad, stacked on iPhone.
struct Split<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        let layout = phone ? AnyLayout(VStackLayout(spacing: 16)) : AnyLayout(HStackLayout(spacing: 32))
        layout { content }
    }
}

extension View {
    /// The narrow side panel: 420 points on iPad, full width on iPhone.
    func side() -> some View { frame(width: phone ? nil : 420).frame(maxWidth: phone ? .infinity : nil) }
}

// MARK: Dot matrix

/// A grid of dots. `color` returns nil for an empty cell; row 0 is the top.
struct Dots: View {
    var cols: Int, rows: Int, pitch: CGFloat, r: CGFloat
    var color: (_ col: Int, _ row: Int) -> Color?

    var body: some View {
        Canvas { ctx, _ in
            for y in 0..<rows {
                for x in 0..<cols {
                    guard let c = color(x, y) else { continue }
                    let cx = (CGFloat(x) + 0.5) * pitch, cy = (CGFloat(y) + 0.5) * pitch
                    ctx.fill(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)), with: .color(c))
                }
            }
        }
        .frame(width: CGFloat(cols) * pitch, height: CGFloat(rows) * pitch)
    }
}

extension Dots {
    /// Dots from a picture: one string per row, each character looked up in `palette`.
    init(_ art: [String], pitch: CGFloat, r: CGFloat, palette: [Character: Color]) {
        let grid = art.map(Array.init)
        self.init(cols: grid[0].count, rows: grid.count, pitch: pitch, r: r) { palette[grid[$1][$0]] }
    }

    /// A level meter: each column lit from the bottom up to `level(col)` rows.
    static func meter(cols: Int, rows: Int, lit: Color, level: @escaping (Int) -> Int) -> Dots {
        Dots(cols: cols, rows: rows, pitch: 12, r: 3.6) { x, y in rows - y <= level(x) ? lit : .off }
    }
}

/// The live meter's motion: four stepped loops, staggered across the columns.
func meterLevel(_ col: Int, at t: Double, max rows: Int) -> Int {
    let loops: [(Double, [Int])] = [(1.5, [5, 3, 6, 2, 4]), (0.9, [1, 3, 2, 4, 2]), (1.3, [4, 1, 3, 5, 4]), (1.1, [2, 5, 3, 6, 1])]
    let (duration, steps) = loops[col % 4]
    let phase = (t + (Double(col) * 0.37).truncatingRemainder(dividingBy: 1.4)).truncatingRemainder(dividingBy: duration) / duration
    return min(rows, steps[Int(phase * 5)])
}

let logoArt = ["...wwwww...", "..w.....w..", ".w.......w.", "w...www...w", "w..w...w..w", "w..w.r.w..w", "w..w......w", "w...w....w.", ".w...wwww.."]
let pageArt = ["bbbbbbbb...", "b......bb..", "b......b.b.", "b......bbbb"] + Array(repeating: "b.........b", count: 9) + ["bbbbbbbbbbb"]
let clipArt = [
    "....wwwww....", "....w...w....", "..wwwwwwwww..", ".w.........w.", "w...........w", "w..m.m.m.m..w", "w...........w",
    "w..m.m.m.m..w", "w...........w", "w..m.m.m.m..w", "w...........w", "w....www....w", "w...wmmmw...w", "w..wmmmmmw..w",
    "w...wmmmw...w", "w....www....w", "w...........w", "w.....g.....w", "w...........w", ".w.........w.", "..wwwwwwwww..",
]

// MARK: Small pieces

/// A row that slides left to show a red Delete, like a list row does. For rows in a scrolling column, which has no
/// swipe actions of its own. A mostly-vertical drag is left to the scrolling.
struct SwipeToDelete<Content: View>: View {
    var onDelete: () -> Void
    @ViewBuilder var content: Content
    @State private var shift: CGFloat = 0
    @State private var open = false
    private let reveal: CGFloat = 104

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(role: .destructive, action: onDelete) {
                Text("Delete").font(geist(16, 600)).foregroundStyle(Color.bg)
                    .frame(width: reveal - 12, height: 40).background(Color.red, in: Capsule())
            }
            .buttonStyle(Press())
            .opacity(shift < 0 ? 1 : 0).allowsHitTesting(open)
            content.offset(x: shift)
        }
        .simultaneousGesture(DragGesture(minimumDistance: 14).onChanged { g in
            guard abs(g.translation.width) > abs(g.translation.height) else { return }
            shift = min(0, max(-reveal, g.translation.width + (open ? -reveal : 0)))
        }.onEnded { g in
            guard abs(g.translation.width) > abs(g.translation.height) else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                open = shift < -reveal / 2
                shift = open ? -reveal : 0
            }
        })
        .accessibilityAction(named: "Delete mark", onDelete)
    }
}

/// Seconds since the app launched, redrawn `fps` times a second.
struct Ticker<Content: View>: View {
    var fps: Double = 30
    @ViewBuilder var content: (Double) -> Content
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / fps)) { content($0.date.timeIntervalSince(tickerStart)) }
    }
}
private let tickerStart = Date()

/// The design's blink: on for half a second, nearly off for half a second.
func blink(_ t: Double, delay: Double = 0) -> Double { Int((t + delay) * 2) % 2 == 0 ? 1 : 0.15 }

struct BlinkDot: View {
    var size: CGFloat, color: Color = .red, delay = 0.0
    var body: some View {
        Ticker(fps: 4) { t in Circle().fill(color).frame(width: size, height: size).opacity(blink(t, delay: delay)) }
    }
}

struct Pill: ButtonStyle {
    var fill: Color? = .ink   // nil draws the outlined button
    var height: CGFloat = 68, size: CGFloat = 19
    var minWidth: CGFloat? = nil, grow = false

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) { configuration.label }
            .font(geist(size, 600))
            .lineLimit(1).minimumScaleFactor(0.7)
            .foregroundStyle(fill == nil ? Color.ink : .bg)
            .padding(.horizontal, fit(32, 14))
            .frame(minWidth: minWidth, maxWidth: grow ? .infinity : nil, minHeight: height)
            .background(fill ?? .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(fill == nil ? Color.outline : .clear, lineWidth: 1.5))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct Press: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.96 : 1).animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    func panel() -> some View {
        background(Color.panel, in: RoundedRectangle(cornerRadius: 28))
            .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(Color.line))
    }
}

struct Flag: View {
    var color: Color = .yellow, size: CGFloat = 16
    var body: some View {
        Path { p in
            p.addLines([CGPoint(x: 3, y: 13), CGPoint(x: 3, y: 1.5), CGPoint(x: 11, y: 1.5), CGPoint(x: 9, y: 4.5), CGPoint(x: 11, y: 7.5), CGPoint(x: 3, y: 7.5)])
        }
        .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        .frame(width: 14, height: 14)
        .scaleEffect(size / 14)
        .frame(width: size, height: size)
    }
}

struct Check: View {
    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.green, lineWidth: 2)
            Path { p in
                p.addLines([CGPoint(x: 7.5, y: 13.5), CGPoint(x: 11.1, y: 17.1), CGPoint(x: 18.5, y: 9.5)])
            }
            .stroke(Color.green, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 26, height: 26)
    }
}

struct DottedRule: View {
    var color: Color, width: CGFloat = 2
    var body: some View {
        GeometryReader { g in
            Path { p in
                p.move(to: CGPoint(x: 1, y: width / 2))
                p.addLine(to: CGPoint(x: g.size.width, y: width / 2))
            }
            .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round, dash: [0.01, width * 2]))
        }
        .frame(height: width)
    }
}

struct LevelDots: View {
    var lit: Int, of: Int
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<of, id: \.self) { Circle().fill($0 < lit ? Color.ink : .off).frame(width: 10, height: 10) }
        }
    }
}

// MARK: The clip's button, as a key

/// What the clip's one button does: one dot for a click, two for a double click, a bar for a hold. With a call
/// state it says what each does right now and dims the ones that do nothing; without one it is the general key.
struct ClipKey: View {
    var live: Live? = nil
    var oneLine = false   // iPhone's Live Call screen: the three actions side by side

    private struct Row {
        var dots: Int   // 0 draws the bar that stands for a hold
        var name: String, does: String
        var on = true
    }

    private var rows: [Row] {
        guard let live else {
            return [Row(dots: 1, name: "Click", does: "Mark the moment"), Row(dots: 2, name: "Double click", does: "Pause or resume"),
                    Row(dots: 0, name: "Hold", does: "End the call, or start one")]
        }
        let double: String
        switch live {
        case .listening: double = "Pause"
        case .between, .cutShort: double = "Resume"
        case .ready: double = "Start recording"
        case .none: double = "Pause or resume"
        }
        return [Row(dots: 1, name: "Click", does: "Mark", on: live == .listening), Row(dots: 2, name: "Double click", does: double, on: live != .none),
                Row(dots: 0, name: "Hold", does: live == .none ? "Start a call" : "End call")]
    }

    var body: some View {
        Group {
            if oneLine {
                HStack(spacing: 14) {
                    Text("Clip").font(geist(13, 600)).foregroundStyle(Color.dim)
                    ForEach(rows, id: \.name) { row in
                        HStack(spacing: 6) {
                            glyph(row.dots)
                            Text(row.does).font(geist(14, 600))
                        }
                        .opacity(row.on ? 1 : 0.35)
                        .accessibilityElement(children: .ignore).accessibilityLabel(spoken(row))
                    }
                }
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Clip button").font(geist(15, 600)).foregroundStyle(Color.dim).padding(.bottom, 6)
                    ForEach(rows, id: \.name) { row in
                        HStack(spacing: 12) {
                            glyph(row.dots).frame(width: 28, alignment: .leading)
                            Text(row.name).font(geist(16, 500)).foregroundStyle(Color.dim).frame(width: 100, alignment: .leading)
                            Text(row.does).font(geist(18, 600)).lineLimit(1).minimumScaleFactor(0.7)
                            Spacer(minLength: 0)
                        }
                        .frame(height: 32)
                        .opacity(row.on ? 1 : 0.35)
                        .accessibilityElement(children: .ignore).accessibilityLabel(spoken(row))
                    }
                }
            }
        }
        .foregroundStyle(Color.ink)
    }

    private func glyph(_ dots: Int) -> some View {
        HStack(spacing: 4) {
            if dots == 0 { Capsule().frame(width: 26, height: 10) }
            ForEach(0..<dots, id: \.self) { _ in Circle().frame(width: 10, height: 10) }
        }
    }

    private func spoken(_ row: Row) -> String { "Clip button, \(row.name): \(row.does)" + (row.on ? "" : ", nothing to do right now") }
}

// MARK: The clip, drawn as a stack of slabs

struct ClipModel: View {
    var ghost = false
    var scale: CGFloat = 1
    var rx = -10.0, ry = -28.0
    var sway = false, wiggle = false, ledBlinks = false

    var body: some View {
        Ticker(fps: sway || wiggle || ledBlinks ? 30 : 1) { t in
            let yaw = ry + (sway ? -9 * cos(t * 2 * .pi / 7) : 0)
            ZStack {
                ForEach(Array(stride(from: -18, through: 18, by: 2)), id: \.self) { z in
                    RoundedRectangle(cornerRadius: 36)
                        .fill(abs(z) == 18 ? (ghost ? Color.ghost : Color(0x5E5C58)) : (ghost ? Color(0x232326) : Color(0x8E8C87)))
                        .modifier(Slab(z: Double(z), rx: rx, ry: yaw))
                }
                face(ledOpacity: ledBlinks ? blink(t) : 1).modifier(Slab(z: 20, rx: rx, ry: yaw))
            }
            .frame(width: 174, height: 264)
            .rotationEffect(.degrees(wiggle ? 6 * sin(t * 2 * .pi / 0.3) * abs(sin(t * .pi / 0.6)) : 0))
            .scaleEffect(scale)
        }
        .frame(width: 174 * scale, height: 264 * scale)
        .accessibilityHidden(true)
    }

    private func face(ledOpacity: Double) -> some View {
        let mark = ghost ? Color.ghost : Color.bg
        return VStack {
            Dots(cols: 4, rows: 3, pitch: 20, r: 5) { _, _ in mark }
            Spacer()
            Circle().fill(ghost ? Color.clear : .red).overlay(Circle().strokeBorder(mark, lineWidth: 5)).frame(width: 68, height: 68)
            Spacer()
            HStack(spacing: 8) {
                Circle().fill(ghost ? Color.ghost : Color(0x1F9D5C)).frame(width: 10, height: 10).opacity(ledOpacity)
                Text("earshot").font(doto(15)).foregroundStyle(mark)
            }
        }
        .padding(.top, 36).padding(.bottom, 26)
        .frame(width: 174, height: 264)
        .background(ghost ? Color(0x19191B) : .ink, in: RoundedRectangle(cornerRadius: 36))
        .overlay(RoundedRectangle(cornerRadius: 36).strokeBorder(ghost ? Color.outline : .clear, style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
    }
}

/// One layer of the clip: turned like the others, then slid along the depth axis.
/// ponytail: no true 3D scene, so the back of the clip is never drawn. Turns are kept under 90 degrees.
private struct Slab: ViewModifier {
    var z: Double, rx: Double, ry: Double
    func body(content: Content) -> some View {
        let a = ry * .pi / 180, b = rx * .pi / 180
        content
            .rotation3DEffect(.degrees(ry), axis: (0, 1, 0), perspective: 0.26)
            .rotation3DEffect(.degrees(rx), axis: (1, 0, 0), perspective: 0.26)
            .offset(x: z * sin(a), y: -z * cos(a) * sin(b))
    }
}

// MARK: Words for times and counts

private let clockFormat: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
}()
func clock(_ date: Date) -> String { clockFormat.string(from: date) }
private let dayFormat: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "d MMM, HH:mm"
    return f
}()
func day(_ date: Date) -> String { dayFormat.string(from: date) }
func span(_ seconds: Int) -> String { seconds < 60 ? "\(seconds) sec" : "\(seconds / 60) min" }
func plural(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }
