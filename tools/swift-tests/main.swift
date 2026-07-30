// Test harness for LEDSParser + LEDEngine, run on macOS with swiftc.
// Usage: swift-tests <fixtures-dir>

import Foundation

var failures = 0
var checks = 0

func check(_ cond: Bool, _ label: String) {
    checks += 1
    if !cond {
        failures += 1
        print("FAIL  \(label)")
    }
}

func near(_ a: Double, _ b: Double, _ eps: Double = 0.01) -> Bool { abs(a - b) < eps }

func near(_ a: RGB, _ b: RGB, _ eps: Double = 0.01) -> Bool {
    near(a.r, b.r, eps) && near(a.g, b.g, eps) && near(a.b, b.b, eps)
}

func rgb(_ hex: String) -> RGB { RGB(hexToken: Substring("#" + hex))! }

func parses(_ text: String) -> Program? { try? LEDSParser.parse(text) }

let fixturesDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "fixtures"

func fixture(_ name: String) -> String {
    let path = (fixturesDir as NSString).appendingPathComponent(name)
    guard let s = try? String(contentsOfFile: path, encoding: .utf8) else {
        fatalError("cannot read fixture \(path)")
    }
    return s
}

// MARK: - Parsing basics

do {
    let p = try LEDSParser.parse("#ffffff")
    check(p.items.count == 1, "single color line = 1 item")
    if case .step(let s) = p.items[0] {
        check(s.actions.allSatisfy { $0 != nil }, "single color addresses all LEDs")
        check(near(s.actions[0]!.target, rgb("ffffff")), "single color is white")
        check(near(s.durationMs, 1000.0 / 60.0, 0.01), "no timing = one 60 Hz frame")
    } else { check(false, "single color parses to step") }
} catch { check(false, "plain color parses: \(error)") }

// Comments
do {
    let p = try LEDSParser.parse("; a\n// b\n# c\n#ff0000")
    check(p.items.count == 1, ";, //, and '# ' lines are comments")
} catch { check(false, "comment forms parse: \(error)") }
check(parses("#") == nil, "bare '#' is an error, not a comment")

// Positional list
do {
    let p = try LEDSParser.parse("#ff0000 #00ff00 #0000ff")
    if case .step(let s) = p.items[0] {
        check(near(s.actions[0]!.target, rgb("ff0000")), "positional LED 0 red")
        check(near(s.actions[1]!.target, rgb("00ff00")), "positional LED 1 green")
        check(near(s.actions[2]!.target, rgb("0000ff")), "positional LED 2 blue")
        for i in 3..<8 {
            check(near(s.actions[i]!.target, .black), "positional LED \(i) past list turns off")
        }
    }
} catch { check(false, "positional list parses: \(error)") }

// Indexed assignments hold unmentioned LEDs
do {
    let p = try LEDSParser.parse("0:#ffffff 2:#ff00ee 7:#0040ff")
    if case .step(let s) = p.items[0] {
        check(s.actions[1] == nil && s.actions[3] == nil, "indexed: unmentioned LEDs hold")
        check(near(s.actions[7]!.target, rgb("0040ff")), "indexed LED 7 assigned")
    }
} catch { check(false, "indexed parses: \(error)") }
check(parses("8:#ffffff") == nil, "LED index 8 out of range on 8-LED build")

// Last assignment wins across segments
do {
    let p = try LEDSParser.parse("0:#ff0000 1s; 0:#0000ff 1s")
    if case .step(let s) = p.items[0] {
        check(near(s.actions[0]!.target, rgb("0000ff")), "last assignment wins")
        check(near(s.durationMs, 1000), "segment durations produce line duration")
    }
} catch { check(false, "last-wins parses: \(error)") }

// Timing grammar
func action(_ line: String) -> LEDAction? {
    guard let p = parses(line), case .step(let s) = p.items[0] else { return nil }
    return s.actions[0]
}
do {
    let a = action("#ff00ff 330ms")!
    check(near(a.durationMs, 330) && a.easing == .linear && near(a.delayMs, 0), "duration only → linear")
    let b = action("#ff00ff ease-in")!
    check(near(b.durationMs, 330) && b.easing == .easeIn, "easing only → default 330 ms")
    let c = action("#ff00ff 0.33s ease-in 1s")!
    check(near(c.durationMs, 330) && c.easing == .easeIn && near(c.delayMs, 1000), "duration easing delay")
    let d = action("#ff00ff 100ms 250ms")!
    check(near(d.durationMs, 100) && near(d.delayMs, 250), "duration delay")
    let e = action("#ff00ff pulse 1s")!
    check(e.easing == .pulse && near(e.durationMs, 330) && near(e.delayMs, 1000), "easing delay (pulse 1s)")
    let f = action("#ff00ff .5s")!
    check(near(f.durationMs, 500), "bare-decimal seconds")
}
check(parses("#ff0000 200ms warp-speed") == nil, "unknown easing is a parse error")
check(parses("#ff0000 200") == nil, "unit-less duration is a parse error")
check(parses("#ff0000 1s 2s 3s") == nil, "too many timing tokens is a parse error")
check(parses("#ff0000 ease linear") == nil, "two easings is a parse error")
check(parses("wat") == nil, "garbage line is a parse error")

// Limits
check(parses(String(repeating: "; padding padding\n", count: 40)) == nil, ">512 bytes rejected")
check(parses(String(repeating: "off\n", count: 11)) == nil, ">10 lines rejected")
check(parses("off\noff\noff\noff\noff\noff\noff\noff\noff\noff\n") != nil,
      "10 lines + trailing newline accepted")

// brightness / repeat forms
check(parses("brightness 300") == nil, "brightness > 255 rejected")
check(parses("repeat 0") == nil, "repeat 0 rejected")
check(parses("repeat 10") != nil && parses("repeat") != nil, "repeat forms accepted")

// MARK: - Fixtures all parse (except invalid)

for name in ["comet.txt", "done.txt", "needs-you.txt", "aurora.txt", "wave.txt",
             "breathing.txt", "positional.txt", "indexed-sparkle.txt",
             "brightness-gray.txt", "finite-repeat.txt", "solo-working.txt",
             "sidepost-idle.txt", "sidepost-working.txt",
             "sidepost-needs-you.txt", "sidepost-approved.txt",
             "sidepost-error.txt"] {
    check(parses(fixture(name)) != nil, "fixture \(name) parses")
}
check(parses(fixture("invalid.txt")) == nil, "fixture invalid.txt is rejected")
check(BuiltinPrograms.errorBlink.items.count == 3, "builtin error blink parses")
check(BuiltinPrograms.disconnected.items.count == 4, "builtin disconnected parses")

// MARK: - Engine semantics

// Fade completes and holds after program end
do {
    let e = LEDEngine()
    e.load(try LEDSParser.parse(fixture("done.txt")), at: 0)
    check(near(e.colors(at: 0)[0], .black, 0.03), "fade starts from black")
    check(near(e.colors(at: 10)[3], rgb("30d158")), "done holds solid green")
}

// State holds across steps (chase)
do {
    let e = LEDEngine()
    e.load(try LEDSParser.parse("0:#ff0000 100ms none\n1:#00ff00 100ms none"), at: 0)
    let mid = e.colors(at: 0.15)
    check(near(mid[0], rgb("ff0000")), "LED 0 holds red during step 2")
    check(near(mid[1], rgb("00ff00")), "LED 1 green in step 2")
}

// Pulse peaks at target and returns to start
do {
    let e = LEDEngine()
    e.load(try LEDSParser.parse("#ff0000 1s pulse"), at: 0)
    check(near(e.colors(at: 0.5)[0], rgb("ff0000"), 0.02), "pulse peak = target at half duration")
    check(near(e.colors(at: 2.0)[0], .black), "pulse returns to start color")
}

// `none` jumps after delay
do {
    let e = LEDEngine()
    e.load(try LEDSParser.parse("#ffffff 100ms none 200ms"), at: 0)
    check(near(e.colors(at: 0.1)[0], .black), "holds start during delay")
    check(near(e.colors(at: 0.21)[0], rgb("ffffff")), "none jumps to target after delay")
}

// Finite repeat with trailing lines: off / red / green / repeat 2 / off
do {
    let e = LEDEngine()
    e.load(try LEDSParser.parse(fixture("finite-repeat.txt")), at: 0)
    let frame = 1.0 / 60.0
    check(near(e.colors(at: frame + 0.10)[0], rgb("ff0000")), "pass 1 red")
    check(near(e.colors(at: frame + 0.30)[0], rgb("00ff00")), "pass 1 green")
    check(near(e.colors(at: frame + 0.50)[0], rgb("ff0000")), "pass 2 red")
    check(near(e.colors(at: frame + 0.70)[0], rgb("00ff00")), "pass 2 green")
    check(near(e.colors(at: frame + 0.95)[0], .black), "trailing off after repeat 2")
    check(near(e.colors(at: 60)[0], .black), "holds final state")
}

// Infinite repeat loops forever, phase-locked
do {
    let e = LEDEngine()
    e.load(try LEDSParser.parse("#ff0000 100ms none\noff 100ms none\nrepeat"), at: 0)
    check(near(e.colors(at: 0.05)[0], rgb("ff0000")), "loop pass 1 on")
    check(near(e.colors(at: 0.15)[0], .black), "loop pass 1 off")
    check(near(e.colors(at: 100.05)[0], rgb("ff0000")), "still looping at t=100 s")
}

// Brightness: scales output, resets on reparse
do {
    let e = LEDEngine()
    e.load(try LEDSParser.parse(fixture("brightness-gray.txt")), at: 0)
    _ = e.colors(at: 1)
    check(near(e.brightness, 128.0 / 255.0), "brightness 128 applied")
    e.load(try LEDSParser.parse("#ffffff"), at: 2)
    check(near(e.brightness, 1.0), "brightness resets to 255 on new parse")
}

// Rewrite behavior: new program starts from current visible state
do {
    let e = LEDEngine()
    e.load(try LEDSParser.parse("#ff0000 1s linear"), at: 0)
    let mid = e.colors(at: 0.5)[0]
    check(mid.r > 0.1 && mid.r < 0.9, "mid-fade is partial red")
    e.load(try LEDSParser.parse("#0000ff 1s linear"), at: 0.5)
    check(near(e.colors(at: 0.5)[0], mid, 0.02), "reparse starts from visible state")
    check(near(e.colors(at: 2.0)[0], rgb("0000ff")), "then fades to new target")
}

// Zero-duration off (the `sidepulse off` program) completes instantly
do {
    let e = LEDEngine()
    e.load(try LEDSParser.parse("#ffffff"), at: 0)
    _ = e.colors(at: 0.1)
    e.load(try LEDSParser.parse("off 0ms none"), at: 1)
    check(near(e.colors(at: 1.001)[0], .black), "off 0ms none goes black immediately")
}

// Degenerate zero-duration loop must not hang
do {
    let e = LEDEngine()
    e.load(try LEDSParser.parse("off 0ms none\nrepeat"), at: 0)
    _ = e.colors(at: 5)
    check(true, "zero-duration repeat loop does not hang")
}

// Error blink timeline: 6 red flashes at 150 ms on/off, then off
do {
    let e = LEDEngine()
    e.load(BuiltinPrograms.errorBlink, at: 0)
    check(near(e.colors(at: 0.075)[0], rgb("ff0000")), "error blink 1 on")
    check(near(e.colors(at: 0.225)[0], .black), "error blink 1 off")
    check(near(e.colors(at: 1.575)[0], rgb("ff0000")), "error blink 6 on")
    check(near(e.colors(at: 5.0)[0], .black), "error blink ends dark")
}

// Comet: staggered pulses sweep left to right
do {
    let e = LEDEngine()
    e.load(try LEDSParser.parse(fixture("comet.txt")), at: 0)
    let t0 = 0.1 + 0.2 // head of LED 0's pulse (peak at delay 0 + 200ms into 400ms pulse)
    let c = e.colors(at: t0)
    check(c[0].b > 0.5, "comet LED 0 near peak")
    check(c[7].b < 0.05, "comet LED 7 still dark early in sweep")
}

// The exact single-agent working program parses and visibly sweeps green.
do {
    let e = LEDEngine()
    e.load(try LEDSParser.parse(fixture("solo-working.txt")), at: 0)
    let c = e.colors(at: 0.27) // 80 ms off step + LED 0 pulse midpoint
    check(c[0].g > 0.5, "solo snake LED 0 reaches a visible green peak")
    check(c[7].g < 0.05, "solo snake LED 7 remains dark early in the sweep")
    let next = e.colors(at: 1.29) // same phase one full 1.02 s loop later
    check(next[0].g > 0.5, "solo snake repeats instead of remaining black")
}

// Side Post uses a genuine 2-LED build: a smooth cyan pulse snakes left to right.
do {
    let e = LEDEngine(ledCount: 2)
    e.load(try LEDSParser.parse(fixture("sidepost-working.txt"), ledCount: 2), at: 0)
    let first = e.colors(at: 0.30)
    check(first[0].b > 0.8 && near(first[1], .black),
          "Side Post cyan snake peaks on the left dot first")
    let second = e.colors(at: 0.60)
    check(near(second[0], .black) && second[1].b > 0.8,
          "Side Post cyan snake travels to the right dot")
    let repeated = e.colors(at: 1.20)
    check(repeated[0].b > 0.8 && near(repeated[1], .black),
          "Side Post cyan snake repeats with a visible 900 ms sweep")
}

// Idle is a solid blue glow with only a slight synchronized pulse.
do {
    let e = LEDEngine(ledCount: 2)
    e.load(try LEDSParser.parse(fixture("sidepost-idle.txt"), ledCount: 2), at: 0)
    let bright = e.colors(at: 0.90)
    check(bright.allSatisfy { near($0, rgb("26D8FF"), 0.02) },
          "Side Post idle reaches solid blue on both dots")
    let dim = e.colors(at: 1.80)
    check(dim.allSatisfy { near($0, rgb("22C5E8"), 0.02) },
          "Side Post idle pulse stays blue at its subtle trough")
}

// Waiting for permission holds both dots solid orange.
do {
    let e = LEDEngine(ledCount: 2)
    e.load(try LEDSParser.parse(fixture("sidepost-needs-you.txt"), ledCount: 2), at: 0)
    check(e.colors(at: 1.0).allSatisfy { near($0, rgb("FF9F0A"), 0.02) },
          "Side Post permission state is solid orange on both dots")
}

// Approval confirms cyan/orange, then the second working phase pulses purple.
do {
    let e = LEDEngine(ledCount: 2)
    e.load(try LEDSParser.parse(fixture("sidepost-approved.txt"), ledCount: 2), at: 0)
    let held = e.colors(at: 0.60)
    check(near(held[0], rgb("26D8FF"), 0.02)
          && near(held[1], rgb("FF9F0A"), 0.02),
          "Side Post approval is cyan left and orange right")
    let purpleLeft = e.colors(at: 1.30)
    check(near(purpleLeft[0], rgb("BF5AF2"), 0.02)
          && near(purpleLeft[1], .black, 0.02),
          "Side Post second working phase starts purple on the left")
    let purpleRight = e.colors(at: 1.60)
    check(near(purpleRight[0], .black, 0.02)
          && near(purpleRight[1], rgb("BF5AF2"), 0.02),
          "Side Post second working phase snakes purple to the right")
}

// Genuine failures retain the separate red double-blink alert.
do {
    let e = LEDEngine(ledCount: 2)
    e.load(try LEDSParser.parse(fixture("sidepost-error.txt"), ledCount: 2), at: 0)
    check(e.colors(at: 0.04).allSatisfy { $0.r > 0.9 },
          "Side Post error first red flash lights both dots")
    check(e.colors(at: 0.13).allSatisfy { near($0, .black) },
          "Side Post error gap is dark")
    check(e.colors(at: 0.22).allSatisfy { $0.r > 0.9 },
          "Side Post error second red flash lights both dots")
    check(e.colors(at: 0.55).allSatisfy { near($0, .black) },
          "Side Post error holds the 600 ms pause")
}

print(failures == 0 ? "PASS  \(checks) checks" : "FAILED  \(failures)/\(checks) checks")
exit(failures == 0 ? 0 : 1)
