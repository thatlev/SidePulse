// LEDStripView.swift — renders the current program with the same parser and
// engine the phone uses, so the Mac preview and the phone cannot disagree.
//
// The two source files are symlinked in from ios/SidePulseSim/SidePulseSim/,
// not copied: one implementation, two front ends.

import SwiftUI

/// Holds engine state across view updates and reloads only when the program or
/// LED count actually changes. A reference type on purpose — SwiftUI must not
/// treat per-frame engine mutation as a state change.
final class EngineBox {
    private var engine = LEDEngine(ledCount: 8)
    private var loadedProgram: String?
    private var loadedCount = 8

    var brightness: Double { engine.brightness }
    private(set) var parseFailed = false

    func colors(for program: String, ledCount: Int, at now: TimeInterval) -> [RGB] {
        if loadedProgram != program || loadedCount != ledCount {
            if loadedCount != ledCount {
                engine = LEDEngine(ledCount: ledCount)
                loadedCount = ledCount
            }
            loadedProgram = program
            // Mirror the phone: an unparseable program shows the firmware's
            // red parse-error blink rather than freezing the last good frame.
            if let parsed = try? LEDSParser.parse(program, ledCount: ledCount) {
                parseFailed = false
                engine.load(parsed, at: now)
            } else {
                parseFailed = true
                engine.load(BuiltinPrograms.errorBlink, at: now)
            }
        }
        return engine.colors(at: now)
    }
}

struct LEDStripView: View {
    let program: String
    let ledCount: Int
    var diameter: CGFloat = 22
    var spacing: CGFloat = 8

    @State private var box = EngineBox()

    var body: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let colors = box.colors(for: program, ledCount: ledCount, at: now)
            HStack(spacing: spacing) {
                ForEach(colors.indices, id: \.self) { i in
                    led(colors[i])
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func led(_ rgb: RGB) -> some View {
        let c = rgb.displayComponents(brightness: box.brightness)
        let color = Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
        let intensity = max(c.r, max(c.g, c.b))
        return Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .overlay(Circle().strokeBorder(.white.opacity(0.09), lineWidth: 0.5))
            // The glow is what makes a flat disc read as a lit LED; scaling it
            // with intensity keeps dark LEDs looking genuinely off.
            .shadow(color: color.opacity(0.65 * intensity), radius: diameter * 0.42)
    }
}

/// The 8 LEDs shrunk into the menu bar. Deliberately slower than the popover
/// (20 fps): it is always on screen, and the strip's animations are slow enough
/// that the difference is invisible.
struct MenuBarStrip: View {
    let program: String
    @State private var box = EngineBox()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let colors = box.colors(for: program, ledCount: 8, at: now)
            Canvas { context, size in
                let n = colors.count
                guard n > 0 else { return }
                let d = min(size.height, size.width / CGFloat(n) - 1)
                let gap = (size.width - d * CGFloat(n)) / CGFloat(max(n - 1, 1))
                for (i, rgb) in colors.enumerated() {
                    let c = rgb.displayComponents(brightness: box.brightness)
                    let rect = CGRect(x: CGFloat(i) * (d + gap),
                                      y: (size.height - d) / 2,
                                      width: d, height: d)
                    context.fill(Path(ellipseIn: rect),
                                 with: .color(Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)))
                }
            }
            .frame(width: 46, height: 10)
        }
    }
}
