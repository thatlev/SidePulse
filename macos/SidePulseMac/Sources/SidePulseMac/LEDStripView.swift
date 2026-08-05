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
    var spacing: CGFloat = 10

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
            // Centred rather than leading: with 2 LEDs the strip is a third of
            // the stage's width, and hugging the left edge reads as a bug.
            .frame(maxWidth: .infinity)
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
            // A lit LED is brightest off-centre-top, where the die sits under
            // the diffuser. Without this the disc reads as a flat sticker.
            .overlay(
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.38 * intensity), .clear],
                            center: UnitPoint(x: 0.36, y: 0.30),
                            startRadius: 0,
                            endRadius: diameter * 0.62
                        )
                    )
            )
            .overlay(Circle().strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
            // The glow is what makes a flat disc read as a lit LED; scaling it
            // with intensity keeps dark LEDs looking genuinely off.
            .shadow(color: color.opacity(0.70 * intensity), radius: diameter * 0.46)
    }
}

/// The dark panel the preview strip sits on, plus the program's own label.
/// Reading as a screen rather than a flat black rectangle is the whole job:
/// a vertical gradient, a specular top edge, and a hairline border.
struct LEDStage: View {
    let program: String
    let ledCount: Int

    var body: some View {
        VStack(spacing: 8) {
            LEDStripView(program: program, ledCount: ledCount)
            Text(programLabel)
                .font(.system(size: 10, weight: .medium))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(1)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [Theme.stageTop, Theme.stageBottom],
                           startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: Theme.stageRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.stageRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.04)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.5
                )
        )
    }

    /// Every program the controllers write opens with a `; name` comment, so
    /// the stage can name the state without re-deriving it from the timeline.
    private var programLabel: String {
        let first = program.split(separator: "\n", omittingEmptySubsequences: true).first ?? ""
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(";") else { return "no program" }
        let name = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "no program" : name.uppercased()
    }
}
