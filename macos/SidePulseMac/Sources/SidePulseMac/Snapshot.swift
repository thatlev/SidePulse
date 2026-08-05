// Snapshot.swift — `SidePulseMac --preview [dark|light]` opens the popover's
// contents in an ordinary window and prints its window number, so a script can
// `screencapture -o -l <number>` it.
//
// A menu bar popover cannot be screenshotted directly (it needs assistive
// access and dismisses as soon as focus moves), and `ImageRenderer` silently
// drops AppKit-backed controls like `Picker(.segmented)` — so reviewing the
// real panel means putting the real views on screen.
//
// Nothing here binds a port or reads an agent config: the models are seeded by
// hand, so a preview run cannot collide with the copy in the menu bar.

import SwiftUI
import AppKit

enum Snapshot {
    /// Each case is a layout worth checking: both LED counts, the connected
    /// state, and the state where an error notice pushes everything down.
    private struct Scenario {
        let title: String
        let ledCount: Int
        let program: String
        let parseError: String?
        let state: LEDHTTPServer.State
    }

    private static let working = """
    ; working
    0:#00ff44 380ms pulse 0ms; 1:#00ff44 380ms pulse 80ms; 2:#00ff44 380ms pulse 160ms; \
    3:#00ff44 380ms pulse 240ms; 4:#00ff44 380ms pulse 320ms; 5:#00ff44 380ms pulse 400ms; \
    6:#00ff44 380ms pulse 480ms; 7:#00ff44 380ms pulse 560ms
    repeat

    """

    private static let approval = """
    ; approval
    #ffa000 250ms ease-out

    """

    private static var window: NSWindow?

    @MainActor
    static func showPreview(appearance: String, outputPath: String?) {
        let scenarios = [
            Scenario(title: "8 LEDs · working", ledCount: 8, program: working,
                     parseError: nil, state: .running(port: 8571, serviceName: "MacBook Pro")),
            Scenario(title: "2 LEDs · approval", ledCount: 2, program: approval,
                     parseError: nil, state: .running(port: 8571, serviceName: "MacBook Pro")),
            Scenario(title: "parse error · stopped", ledCount: 8,
                     program: "; broken\nnonsense\n",
                     parseError: "line 2: unknown token \"nonsense\"", state: .stopped),
        ]

        // The LED count reaches MenuContent through @AppStorage, so each panel
        // needs its own defaults suite rather than a shared global.
        let panels = scenarios.enumerated().map { index, scenario -> AnyView in
            let defaults = UserDefaults(suiteName: "sidepulse.preview.\(index)")!
            defaults.set(scenario.ledCount, forKey: LEDPreview.storageKey)
            let model = ServerModel()
            model.seedForSnapshot(program: scenario.program,
                                  parseError: scenario.parseError,
                                  state: scenario.state,
                                  writesSeen: 128,
                                  requestsServed: 4207)
            return AnyView(
                VStack(spacing: 6) {
                    Text(scenario.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    MenuContent(model: model, agents: AgentHooksModel())
                        .defaultAppStorage(defaults)
                }
            )
        }

        let root = VStack(alignment: .leading, spacing: 14) {
            menuBarBand(appearance: appearance)
            HStack(alignment: .top, spacing: 16) {
                ForEach(panels.indices, id: \.self) { panels[$0] }
            }
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))

        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "SidePulse preview"
        window.contentView = hosting
        window.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        window.center()
        window.makeKeyAndOrderFront(nil)
        Self.window = window

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        print("WINDOW_ID \(window.windowNumber)")
        fflush(stdout)

        guard let outputPath else { return }
        // One run loop turn so SwiftUI has laid out and the AppKit controls
        // inside it have drawn at least once; capturing sooner yields blanks.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            capture(hosting, to: outputPath)
            exit(0)
        }
    }

    /// The menu bar item at its real size, over the menu bar's own material —
    /// the one thing a popover screenshot cannot tell you, and the reason an
    /// idle strip once rendered as an invisible item.
    @MainActor
    private static func menuBarBand(appearance: String) -> some View {
        let states: [(String, Int, String)] = [
            ("idle (default)", 8, LEDFile.defaultProgram),
            ("working", 8, working),
            ("approval", 8, approval),
            ("all off", 8, "; off\noff 1s none\n"),
            ("side post idle", 2, LEDFile.defaultProgram),
        ]
        return HStack(spacing: 18) {
            ForEach(states.indices, id: \.self) { i in
                VStack(spacing: 5) {
                    // The real status-item image, not a SwiftUI lookalike — a
                    // preview of a second implementation would prove nothing.
                    Image(nsImage: menuBarImage(program: states[i].2,
                                                ledCount: states[i].1,
                                                isDark: appearance != "light"))
                    Text(states[i].0)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Runs one frame of the engine and hands the colours to the same drawing
    /// code the status item uses.
    @MainActor
    private static func menuBarImage(program: String, ledCount: Int, isDark: Bool) -> NSImage {
        let box = EngineBox()
        let colors = box.colors(for: program, ledCount: ledCount,
                                at: Date().timeIntervalSinceReferenceDate)
        return MenuBarController.stripImage(colors: colors,
                                            brightness: box.brightness,
                                            isDark: isDark)
    }

    /// Asks the view hierarchy to draw itself into a bitmap. Unlike
    /// `screencapture`/`CGWindowListCreateImage` this needs no Screen Recording
    /// permission, and unlike `ImageRenderer` it goes through real AppKit
    /// drawing, so `Picker(.segmented)` and friends appear as they actually do.
    @MainActor
    private static func capture(_ view: NSView, to path: String) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            FileHandle.standardError.write(Data("could not allocate a bitmap\n".utf8))
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)

        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("could not encode PNG\n".utf8))
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
        fflush(stdout)
    }
}
