// LEDSParser.swift — parses the LEDS.TXT DSL exactly as specified in LEDS_FORMAT.txt.
// Foundation-only so it can be unit-tested on macOS outside the app.
//
// Documented assumptions where the format doc is silent:
// - A duration with no easing name fades linearly (`linear`).
// - Durations/delays require a unit suffix (`330ms`, `1s`, `0.33s`); bare numbers are errors.
// - Keywords are lowercase; hex digits are case-insensitive.
// - `repeat N` requires N >= 1.
// - A bare `repeat` after an earlier `repeat N` marker loops the lines after that
//   marker (equals "from the first animation line" for single-marker programs).
// - Positional and indexed assignments cannot be mixed within one segment.

import Foundation

enum Easing: String {
    case linear, ease, cosine, pulse, none
    case easeIn = "ease-in"
    case easeOut = "ease-out"
    case easeInOut = "ease-in-out"
}

/// One LED color in linear-light RGB (0...1). Interpolation happens here so
/// mid-fades don't look muddy; conversion back to sRGB happens at display time.
struct RGB: Equatable {
    var r: Double
    var g: Double
    var b: Double

    static let black = RGB(r: 0, g: 0, b: 0)

    /// Parses a "#rrggbb" token (leading "#" required, exactly 6 hex digits).
    init?(hexToken token: Substring) {
        guard token.hasPrefix("#") else { return nil }
        let hex = token.dropFirst()
        guard hex.count == 6, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let v = UInt32(hex, radix: 16) else { return nil }
        r = RGB.linear(fromSRGB: Double((v >> 16) & 0xff) / 255)
        g = RGB.linear(fromSRGB: Double((v >> 8) & 0xff) / 255)
        b = RGB.linear(fromSRGB: Double(v & 0xff) / 255)
    }

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    static func linear(fromSRGB c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func srgb(fromLinear c: Double) -> Double {
        let c = max(0, min(1, c))
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    /// Gamma-encoded components for display, scaled by firmware brightness
    /// (brightness scales the written RGB byte values, i.e. gamma space).
    func displayComponents(brightness: Double) -> (r: Double, g: Double, b: Double) {
        (RGB.srgb(fromLinear: r) * brightness,
         RGB.srgb(fromLinear: g) * brightness,
         RGB.srgb(fromLinear: b) * brightness)
    }

    static func lerp(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        RGB(r: a.r + (b.r - a.r) * t,
            g: a.g + (b.g - a.g) * t,
            b: a.b + (b.b - a.b) * t)
    }
}

/// One LED's assignment within a step: fade to `target` over `durationMs`
/// after `delayMs`, shaped by `easing`.
struct LEDAction {
    var target: RGB
    var durationMs: Double
    var easing: Easing
    var delayMs: Double
}

/// One executed line. `actions[i]` is nil when LED i is unaddressed (holds state).
/// A brightness line is a zero-time step with `brightness` set.
struct Step {
    var actions: [LEDAction?]
    var brightness: Int?
    var durationMs: Double
}

enum ProgramItem {
    case step(Step)
    case repeatMark(Int?) // nil = loop forever
}

struct Program {
    var items: [ProgramItem]
    var ledCount: Int
}

struct LEDSParseError: Error, CustomStringConvertible {
    var line: Int
    var message: String
    var description: String { line > 0 ? "line \(line): \(message)" : message }
}

enum LEDSParser {
    static let maxBytes = 512
    static let maxLines = 10
    static let frameMs = 1000.0 / 60.0
    static let defaultDurationMs = 330.0

    static func parse(_ text: String, ledCount: Int = 8) throws -> Program {
        guard text.utf8.count <= maxBytes else {
            throw LEDSParseError(line: 0, message: "program is \(text.utf8.count) bytes (max \(maxBytes))")
        }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() } // trailing newline is not an extra physical line
        guard lines.count <= maxLines else {
            throw LEDSParseError(line: 0, message: "program is \(lines.count) lines (max \(maxLines))")
        }

        var items: [ProgramItem] = []
        for (i, raw) in lines.enumerated() {
            let lineNo = i + 1
            let lead = raw.drop(while: { $0.isWhitespace })
            if lead.isEmpty { continue }
            if lead.hasPrefix(";") || lead.hasPrefix("//") || lead.hasPrefix("# ") { continue }
            let fields = lead.split(whereSeparator: { $0.isWhitespace })

            if fields[0] == "brightness" {
                guard fields.count == 2, let n = Int(fields[1]), (0...255).contains(n) else {
                    throw LEDSParseError(line: lineNo, message: "brightness needs a value 0-255")
                }
                items.append(.step(Step(actions: Array(repeating: nil, count: ledCount),
                                        brightness: n, durationMs: 0)))
                continue
            }

            if fields[0] == "repeat" {
                if fields.count == 1 {
                    items.append(.repeatMark(nil))
                } else if fields.count == 2, let n = Int(fields[1]), n >= 1 {
                    items.append(.repeatMark(n))
                } else {
                    throw LEDSParseError(line: lineNo, message: "repeat takes no argument or a count >= 1")
                }
                continue
            }

            items.append(.step(try parseStepLine(lead, lineNo: lineNo, ledCount: ledCount)))
        }
        return Program(items: items, ledCount: ledCount)
    }

    // MARK: - Step lines

    private static func parseStepLine(_ line: Substring, lineNo: Int, ledCount: Int) throws -> Step {
        var actions = [LEDAction?](repeating: nil, count: ledCount)
        var sawTiming = false

        for segment in line.split(separator: ";", omittingEmptySubsequences: true) {
            let tokens = segment.split(whereSeparator: { $0.isWhitespace })
            if tokens.isEmpty { continue }

            var targets: [(Int, RGB)] = []
            var idx = 0

            if tokens[0] == "off" {
                for i in 0..<ledCount { targets.append((i, .black)) }
                idx = 1
            } else if tokens[0].hasPrefix("#") {
                var list: [RGB] = []
                while idx < tokens.count, tokens[idx].hasPrefix("#") {
                    guard let c = RGB(hexToken: tokens[idx]) else {
                        throw LEDSParseError(line: lineNo, message: "bad color '\(tokens[idx])'")
                    }
                    list.append(c)
                    idx += 1
                }
                if list.count == 1 {
                    for i in 0..<ledCount { targets.append((i, list[0])) }
                } else {
                    // Positional list: clamp to LED count; LEDs past the list turn off.
                    for i in 0..<ledCount { targets.append((i, i < list.count ? list[i] : .black)) }
                }
            } else if tokens[0].contains(":") {
                while idx < tokens.count, tokens[idx].contains(":") {
                    let t = tokens[idx]
                    let colon = t.firstIndex(of: ":")!
                    let idxPart = t[t.startIndex..<colon]
                    let colorPart = t[t.index(after: colon)...]
                    guard !idxPart.isEmpty, idxPart.allSatisfy({ $0.isASCII && $0.isNumber }),
                          let i = Int(idxPart), let c = RGB(hexToken: colorPart) else {
                        throw LEDSParseError(line: lineNo, message: "bad indexed assignment '\(t)'")
                    }
                    guard i < ledCount else {
                        throw LEDSParseError(line: lineNo, message: "LED index \(i) out of range (0-\(ledCount - 1))")
                    }
                    targets.append((i, c))
                    idx += 1
                }
            } else {
                throw LEDSParseError(line: lineNo, message: "expected a color assignment, got '\(tokens[0])'")
            }

            let timing = try parseTiming(tokens[idx...], lineNo: lineNo)
            sawTiming = sawTiming || timing.had
            for (i, color) in targets {
                actions[i] = LEDAction(target: color, durationMs: timing.durationMs,
                                       easing: timing.easing, delayMs: timing.delayMs)
            }
        }

        var durationMs = 0.0
        for action in actions {
            if let a = action { durationMs = max(durationMs, a.delayMs + a.durationMs) }
        }
        if !sawTiming { durationMs = frameMs } // a line with no timing lasts one 60 Hz frame
        return Step(actions: actions, brightness: nil, durationMs: durationMs)
    }

    // Accepts exactly: (nothing) | duration | easing | duration easing |
    // duration easing delay | duration delay | easing delay
    private static func parseTiming(
        _ tokens: ArraySlice<Substring>, lineNo: Int
    ) throws -> (durationMs: Double, easing: Easing, delayMs: Double, had: Bool) {
        if tokens.isEmpty { return (0, .none, 0, false) }
        var duration: Double?
        var easing: Easing?
        var delay: Double?
        var i = tokens.startIndex

        if let d = durationValue(tokens[i]) {
            duration = d
        } else if let e = Easing(rawValue: String(tokens[i])) {
            easing = e
        } else {
            throw LEDSParseError(line: lineNo, message: "expected duration or easing, got '\(tokens[i])'")
        }
        i += 1

        if i < tokens.endIndex {
            if easing == nil, let e = Easing(rawValue: String(tokens[i])) {
                easing = e
                i += 1
            } else if let d = durationValue(tokens[i]) {
                delay = d
                i += 1
            } else {
                throw LEDSParseError(line: lineNo, message: "unexpected token '\(tokens[i])'")
            }
        }

        if i < tokens.endIndex {
            if delay == nil, let d = durationValue(tokens[i]) {
                delay = d
                i += 1
            } else {
                throw LEDSParseError(line: lineNo, message: "unexpected token '\(tokens[i])'")
            }
        }

        guard i == tokens.endIndex else {
            throw LEDSParseError(line: lineNo, message: "unexpected token '\(tokens[i])'")
        }
        return (duration ?? defaultDurationMs, easing ?? .linear, delay ?? 0, true)
    }

    /// `330ms` (integer ms), `1s` (integer s), `0.33s` / `.33s` (decimal s) → milliseconds.
    private static func durationValue(_ token: Substring) -> Double? {
        if token.hasSuffix("ms") {
            let digits = token.dropLast(2)
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let v = Double(digits) else { return nil }
            return v
        }
        if token.hasSuffix("s") {
            let num = token.dropLast(1)
            guard !num.isEmpty, num.contains(where: { $0.isASCII && $0.isNumber }),
                  num.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "." }),
                  num.filter({ $0 == "." }).count <= 1,
                  let v = Double(num) else { return nil }
            return v * 1000
        }
        return nil
    }
}
