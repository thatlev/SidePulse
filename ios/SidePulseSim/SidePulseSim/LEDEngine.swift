// LEDEngine.swift — evaluates a parsed Program over time, replicating the
// firmware's execution model: sequential steps, per-LED hold, repeat markers,
// state carried across parses. Foundation-only for macOS unit testing.

import Foundation

final class LEDEngine {
    let ledCount: Int

    /// Firmware brightness (0...1, from `brightness N` / 255). Resets to 1 on load.
    private(set) var brightness: Double = 1.0

    private var items: [ProgramItem] = []
    private var pc = 0
    private var blockStart = 0          // first item of the current repeat block
    private var passes: [Int: Int] = [:] // finite repeat markers: passes completed
    private var stepStart: TimeInterval = 0
    private var finished = true
    private var committed: [RGB]         // LED state at the start of the current step

    init(ledCount: Int = 8) {
        self.ledCount = ledCount
        committed = Array(repeating: .black, count: ledCount)
    }

    /// Loads a new program. The current *visible* state (not the committed step
    /// start) becomes the transition start colors — the firmware's rewrite behavior.
    func load(_ program: Program, at now: TimeInterval) {
        committed = colors(at: now)
        items = program.items
        pc = 0
        blockStart = 0
        passes = [:]
        stepStart = now
        finished = items.isEmpty
        brightness = 1.0
    }

    /// Current per-LED colors (linear RGB), advancing program state as needed.
    func colors(at now: TimeInterval) -> [RGB] {
        advance(to: now)
        guard !finished, pc < items.count, case .step(let step) = items[pc] else {
            return committed
        }
        return evaluate(step, at: now - stepStart)
    }

    private func advance(to now: TimeInterval) {
        guard !finished else { return }
        var hops = 0
        while hops < 500 { // cap protects against zero-duration repeat blocks
            hops += 1
            guard pc < items.count else {
                finished = true
                return
            }
            switch items[pc] {
            case .repeatMark(let count):
                if let count {
                    let done = (passes[pc] ?? 0) + 1
                    if done < count {
                        passes[pc] = done
                        pc = blockStart
                    } else {
                        passes[pc] = 0 // reset so an outer loop can re-run the block
                        pc += 1
                        blockStart = pc
                    }
                } else {
                    pc = blockStart
                }
            case .step(let step):
                if let b = step.brightness {
                    brightness = Double(b) / 255.0
                    pc += 1
                    continue
                }
                let dur = step.durationMs / 1000.0
                if now - stepStart >= dur {
                    committed = endState(step, from: committed)
                    stepStart += dur
                    pc += 1
                } else {
                    return
                }
            }
        }
    }

    private func evaluate(_ step: Step, at t: TimeInterval) -> [RGB] {
        var out = committed
        let tMs = t * 1000
        for i in 0..<ledCount {
            guard let a = step.actions[i] else { continue }
            let start = committed[i]
            if tMs < a.delayMs { continue } // holds start color during delay
            let p = a.durationMs > 0 ? min((tMs - a.delayMs) / a.durationMs, 1.0) : 1.0
            switch a.easing {
            case .none:
                out[i] = a.target
            case .pulse:
                // Full cycle start → target (peak) → start over one duration.
                let f = p >= 1 ? 0 : (1 - cos(2 * .pi * p)) / 2
                out[i] = RGB.lerp(start, a.target, f)
            case .linear:
                out[i] = RGB.lerp(start, a.target, p)
            case .cosine:
                out[i] = RGB.lerp(start, a.target, (1 - cos(.pi * p)) / 2)
            case .ease:
                out[i] = RGB.lerp(start, a.target, UnitBezier.ease.solve(p))
            case .easeIn:
                out[i] = RGB.lerp(start, a.target, UnitBezier.easeIn.solve(p))
            case .easeOut:
                out[i] = RGB.lerp(start, a.target, UnitBezier.easeOut.solve(p))
            case .easeInOut:
                out[i] = RGB.lerp(start, a.target, UnitBezier.easeInOut.solve(p))
            }
        }
        return out
    }

    private func endState(_ step: Step, from: [RGB]) -> [RGB] {
        var out = from
        for i in 0..<ledCount {
            guard let a = step.actions[i] else { continue }
            out[i] = a.easing == .pulse ? from[i] : a.target
        }
        return out
    }
}

/// Programs the simulator itself needs, written in the same DSL (dogfooding the
/// parser). Both are covered by the unit tests, so force-parse is safe.
enum BuiltinPrograms {
    /// Firmware parse-error behavior: blink all LEDs red 6 times, 150 ms on/off.
    static let errorBlink = try! LEDSParser.parse("""
    #ff0000 150ms none
    off 150ms none
    repeat 6
    """)

    /// Disconnected: fade to off, faint grey breathing dot on LED 0.
    static let disconnected = try! LEDSParser.parse("""
    off 800ms ease-out
    0:#2e2e33 1.6s pulse
    0:#000000 400ms none
    repeat
    """)
}

/// CSS cubic-bezier easing (WebKit-style solver).
struct UnitBezier {
    private let ax, bx, cx, ay, by, cy: Double

    init(_ p1x: Double, _ p1y: Double, _ p2x: Double, _ p2y: Double) {
        cx = 3 * p1x
        bx = 3 * (p2x - p1x) - cx
        ax = 1 - cx - bx
        cy = 3 * p1y
        by = 3 * (p2y - p1y) - cy
        ay = 1 - cy - by
    }

    static let ease = UnitBezier(0.25, 0.1, 0.25, 1)
    static let easeIn = UnitBezier(0.42, 0, 1, 1)
    static let easeOut = UnitBezier(0, 0, 0.58, 1)
    static let easeInOut = UnitBezier(0.42, 0, 0.58, 1)

    private func sampleX(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
    private func sampleY(_ t: Double) -> Double { ((ay * t + by) * t + cy) * t }
    private func sampleDX(_ t: Double) -> Double { (3 * ax * t + 2 * bx) * t + cx }

    func solve(_ x: Double) -> Double {
        let x = max(0, min(1, x))
        var t = x
        for _ in 0..<8 { // Newton-Raphson
            let dx = sampleX(t) - x
            if abs(dx) < 1e-6 { return sampleY(t) }
            let d = sampleDX(t)
            if abs(d) < 1e-6 { break }
            t -= dx / d
        }
        var lo = 0.0, hi = 1.0 // fall back to bisection
        t = x
        while hi - lo > 1e-6 {
            if sampleX(t) < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return sampleY(t)
    }
}
