// AppDelegate.swift — brings up the status item and the server, and handles the
// development flags.

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = ServerModel()
    private let agents = AgentHooksModel()
    private var menuBar: MenuBarController?
    private var onboardingWindow: NSWindowController?

    private static let completedOnboardingKey = "SidePulse.completedOnboarding.v1"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments

        // `--preview [dark|light] [--snapshot <path>]` shows the popover's
        // contents in an ordinary window for visual review; see Snapshot.swift.
        if let flag = arguments.firstIndex(of: "--preview") {
            let next = flag + 1
            let appearance = next < arguments.count && !arguments[next].hasPrefix("--")
                ? arguments[next] : "dark"
            var snapshotPath: String?
            if let s = arguments.firstIndex(of: "--snapshot"), s + 1 < arguments.count {
                snapshotPath = arguments[s + 1]
            }
            Snapshot.showPreview(appearance: appearance, outputPath: snapshotPath)
            return
        }

        menuBar = MenuBarController(model: model, agents: agents)
        model.start()

        if arguments.contains("--onboarding-preview") {
            NSApp.setActivationPolicy(.regular)
        }
        if arguments.contains("--onboarding-preview")
            || !UserDefaults.standard.bool(forKey: Self.completedOnboardingKey) {
            menuBar?.setRedrawsPaused(true)
            showOnboarding()
        }

        if arguments.contains("--diagnose") {
            print(menuBar?.diagnose() ?? "no status item")
            // One turn of the run loop first, so the item has been placed and
            // has a window to report on.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                print("--- after placement ---")
                print(self?.menuBar?.diagnose() ?? "no status item")
                self?.menuBar?.verboseDiagnostics = true
                self?.menuBar?.setPopoverBehaviorForDiagnostics(.applicationDefined)
                self?.menuBar?.setLEDCountForDiagnostics(8)
                self?.menuBar?.openForDiagnostics()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    print("--- popover ---")
                    print(self?.menuBar?.popoverDiagnostics() ?? "no popover")
                    print("--- alignment, 8 LEDs ---")
                    print(self?.menuBar?.alignmentDiagnostics() ?? "no popover")

                    // Switch to Side Post while the panel is open: the item gets
                    // narrower, the menu bar re-lays out, and the panel has to
                    // follow it.
                    self?.menuBar?.setLEDCountForDiagnostics(2)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        print("--- alignment, 2 LEDs (after resize) ---")
                        print(self?.menuBar?.alignmentDiagnostics() ?? "no popover")
                        print("--- still on screen? ---")
                        print(self?.menuBar?.popoverDiagnostics() ?? "no popover")
                        self?.menuBar?.setLEDCountForDiagnostics(8)
                        print("--- toggle ---")
                        print(self?.menuBar?.toggleDiagnostics() ?? "no popover")
                        exit(0)
                    }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    private func showOnboarding() {
        let content = SidePulseOnboardingView(
            model: model,
            agents: agents,
            onFinish: { [weak self] in self?.finishOnboarding() }
        )
        let controller = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: controller)
        window.title = "Set Up SidePulse"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 700, height: 560))
        window.minSize = NSSize(width: 660, height: 520)
        window.isReleasedWhenClosed = false
        window.center()
        onboardingWindow = NSWindowController(window: window)

        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.completedOnboardingKey)
        onboardingWindow?.close()
        onboardingWindow = nil
        menuBar?.setRedrawsPaused(false)
        DispatchQueue.main.async { [weak self] in
            self?.menuBar?.openAfterOnboarding()
        }
    }
}
