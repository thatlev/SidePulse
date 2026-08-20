// MenuBarController.swift — the status item and the popover behind it.
//
// This is AppKit rather than SwiftUI's `MenuBarExtra` on purpose. `MenuBarExtra`
// only renders simple labels reliably; give it an animated `Canvas` and it can
// produce a blank or zero-width item, which looks exactly like an app that
// failed to launch. An `NSStatusItem` with an `NSImage` we draw ourselves always
// appears, always has a real width, and is what the menu bar API is for.
//
// The popover's contents are still SwiftUI — that part `MenuBarExtra` was never
// the problem.

import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let stripView = StatusStripView()
    private let popover = NSPopover()
    private let model: ServerModel
    private let agents: AgentHooksModel

    /// Same engine the popover and the phone use, so the menu bar cannot
    /// disagree with either about what a program means.
    private let engine = EngineBox()
    private var redrawTimer: Timer?
    private var programObservation: AnyCancellable?
    private var redrawsPaused = false

    /// The status strip is deliberately slower than the phone display. Tiny
    /// 5-point menu-bar dots do not benefit from display-rate animation, and
    /// every changed status item must be composited onto every attached menu
    /// bar. The persistent layer-backed view also ignores identical quantized
    /// frames, so static portions of a program cost no WindowServer updates.
    private static let redrawInterval: TimeInterval = 1.0 / 10.0

    private var ledCount: Int {
        let stored = UserDefaults.standard.integer(forKey: LEDPreview.storageKey)
        return stored > 0 ? stored : LEDPreview.defaultCount
    }

    init(model: ServerModel, agents: AgentHooksModel) {
        self.model = model
        self.agents = agents
        // Variable length: the item is 8 dots wide in ATLD mode and 2 in Side
        // Post mode, and the bar should reclaim the difference.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        popover.delegate = self

        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "SidePulse"
        button.setAccessibilityLabel("SidePulse")

        stripView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(stripView)
        NSLayoutConstraint.activate([
            stripView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            stripView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            stripView.heightAnchor.constraint(equalToConstant: Self.imageHeight),
        ])

        popover.behavior = .transient
        popover.animates = false

        redraw()
        programObservation = model.$program
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, !self.redrawsPaused else { return }
                self.redraw()
            }
        let timer = Timer(timeInterval: Self.redrawInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.redraw() }
        }
        timer.tolerance = 0.03
        // .common so the strip keeps animating while a menu is tracking.
        RunLoop.main.add(timer, forMode: .common)
        redrawTimer = timer
    }

    deinit { redrawTimer?.invalidate() }

    func setRedrawsPaused(_ paused: Bool) {
        redrawsPaused = paused
        redrawTimer?.fireDate = paused ? .distantFuture : Date()
        if !paused { redraw() }
    }

    // MARK: - Click

    /// How recently a close has to have happened for the click that follows it
    /// to be treated as the same interaction. Comfortably longer than the gap
    /// between a click's mouse-down and mouse-up, and short enough that a
    /// deliberate close-then-reopen still registers as two actions.
    private static let closeDebounce: TimeInterval = 0.2

    /// When the popover last closed for any reason other than our own
    /// re-anchoring. See `statusItemClicked`.
    private var lastCloseAt: Date?

    @objc private func statusItemClicked() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // A `.transient` popover dismisses itself when a click lands outside it
        // — including a click on this very button — and that happens *before*
        // the button's action runs. Without this guard the action then sees a
        // closed popover and opens it straight back up, so the item flickers
        // instead of toggling off. Whether the dismissal wins the race varies,
        // which is why it only misbehaved sometimes.
        if let lastCloseAt, Date().timeIntervalSince(lastCloseAt) < Self.closeDebounce {
            self.lastCloseAt = nil
            return
        }
        guard let button = statusItem.button else { return }
        // Re-read the agent configs on open, so a config edited in a terminal
        // since the last look is reflected.
        agents.refresh()
        present(from: button)
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        // Re-anchoring closes and immediately reopens the popover; that is not a
        // dismissal and must not swallow the user's next click.
        guard !isReanchoring else { return }
        lastCloseAt = Date()
    }

    /// Breathing room between the panel and the bottom of the screen.
    private static let screenMargin: CGFloat = 24

    /// Builds the panel and, crucially, tells the popover how big it is *before*
    /// showing it.
    ///
    /// An `NSPopover` handed an `NSHostingController` has a `contentSize` of
    /// zero until something sets it. It then gets positioned at that zero size
    /// and grown afterwards by SwiftUI, which anchors the panel so its top edge
    /// ends up above the menu bar and off the screen. Measuring first and
    /// assigning `contentSize` is what keeps the whole panel on screen.
    private func present(from button: NSStatusBarButton) {
        let screen = button.window?.screen ?? NSScreen.main
        let available = (screen?.visibleFrame.height ?? 800) - Self.screenMargin

        let content = MenuContent(model: model, agents: agents)
        let controller = NSHostingController(rootView: AnyView(content))
        controller.view.layoutSubtreeIfNeeded()

        var size = controller.view.fittingSize
        if size.width <= 0 { size.width = Theme.panelWidth }
        if size.height > available {
            // Taller than this screen allows — scroll rather than run off the
            // top, which is what AppKit does on its own when it cannot fit.
            controller.rootView = AnyView(
                ScrollView(.vertical) { content }
                    .frame(width: size.width, height: available)
            )
            size.height = available
        }
        // Keeps the panel correctly sized if its height changes while open —
        // an error notice appearing, or agent rows swapping Connect for Remove.
        controller.sizingOptions = [.preferredContentSize]
        controller.preferredContentSize = size

        popover.contentViewController = controller
        popover.contentSize = size
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // Remember where the item was when we anchored to it, so `redraw` can
        // notice if it moves out from under the panel.
        anchorFrame = button.window?.frame

        // Without this the popover appears behind the frontmost app and its
        // buttons need two clicks: one to focus, one to act.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Where the status item was when the open popover was anchored to it.
    private var anchorFrame: NSRect?

    /// True only for the close/reopen pair inside `realignIfItemMoved`.
    private var isReanchoring = false

    /// Switching between ATLD and Side Post changes the image width, which
    /// changes the status item's width, which makes the menu bar re-lay-out and
    /// slide the item sideways — out from under the panel that is pointing at
    /// it. AppKit has no API to move a shown popover, and nudging its window
    /// would leave the beak behind, so the panel is re-anchored instead.
    ///
    /// Re-presenting also picks up the new size, and covers the item moving for
    /// any other reason: another app's status item appearing or disappearing,
    /// or the display changing.
    /// Set by `--diagnose` to trace why a realign did or did not happen.
    var verboseDiagnostics = false

    private func realignIfItemMoved() {
        guard let button = statusItem.button, let current = button.window?.frame else { return }
        guard popover.isShown else {
            // Keep the anchor current, so the next open is never compared
            // against a frame from before the item last moved.
            anchorFrame = current
            return
        }
        guard let anchored = anchorFrame, current != anchored else { return }
        if verboseDiagnostics {
            print("  [realign] item moved \(anchored) -> \(current); re-anchoring")
        }
        // Close explicitly first. Assigning `contentViewController` on a shown
        // popover tears it down without reopening it, which loses the panel
        // instead of moving it.
        isReanchoring = true
        popover.close()
        present(from: button)
        isReanchoring = false
        if verboseDiagnostics {
            print("  [realign] re-anchored; shown = \(popover.isShown)")
        }
    }

    /// Replays the toggle race deterministically: the transient dismissal that
    /// AppKit performs on the click, followed by the button action that same
    /// click triggers. Simulated with `popover.close()`, which is the same code
    /// path AppKit's own dismissal takes through `popoverDidClose`.
    func toggleDiagnostics() -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            lines.append((condition ? "  ok   " : "  FAIL ") + label)
            if !condition { failures += 1 }
        }

        guard let button = statusItem.button else { return "no status item" }
        let wasTransient = popover.behavior
        popover.behavior = .applicationDefined

        // 1. A plain click on a closed popover opens it.
        lastCloseAt = nil
        if popover.isShown { popover.close() }
        lastCloseAt = nil
        statusItemClicked()
        check(popover.isShown, "click opens the popover")

        // 2. The real bug: AppKit dismisses, then the click's action arrives.
        //    The action must NOT reopen it.
        popover.close()
        check(!popover.isShown, "transient dismissal closed it")
        statusItemClicked()
        check(!popover.isShown, "the click that dismissed it does not reopen it")

        // 3. A later, deliberate click still opens it.
        Thread.sleep(forTimeInterval: Self.closeDebounce + 0.05)
        statusItemClicked()
        check(popover.isShown, "a later click opens it again")

        // 4. Clicking a shown popover closes it.
        statusItemClicked()
        check(!popover.isShown, "clicking a shown popover closes it")

        // 5. Re-anchoring must not be mistaken for a dismissal.
        lastCloseAt = nil
        statusItemClicked()
        check(popover.isShown, "reopened for the re-anchor check")
        isReanchoring = true
        popover.close()
        present(from: button)
        isReanchoring = false
        check(popover.isShown, "re-anchor leaves the popover shown")
        check(lastCloseAt == nil, "re-anchor does not count as a dismissal")
        statusItemClicked()
        check(!popover.isShown, "a click right after a re-anchor still closes it")

        popover.behavior = wasTransient
        lines.append(failures == 0 ? "RESULT: toggle is reliable"
                                   : "RESULT: \(failures) FAILURE(S)")
        return lines.joined(separator: "\n")
    }

    /// `--diagnose` pins the popover open. A `.transient` popover closes as soon
    /// as the app resigns active, which a terminal-launched accessory app does
    /// immediately — that would close the panel before the resize under test.
    func setPopoverBehaviorForDiagnostics(_ behavior: NSPopover.Behavior) {
        popover.behavior = behavior
    }

    // MARK: - Drawing

    private func redraw() {
        guard let button = statusItem.button else { return }
        let now = Date().timeIntervalSinceReferenceDate
        let count = ledCount
        let colors = engine.colors(for: model.program, ledCount: count, at: now)
        let isDark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let contentWidth = Self.imageSize(ledCount: count).width
        if stripView.ledCount != count {
            stripView.setLEDCount(count, width: contentWidth)
            // Match the horizontal breathing room AppKit previously added
            // around the image while keeping the status item an easy target.
            statusItem.length = contentWidth + 10
        }
        stripView.update(colors: colors, brightness: engine.brightness, isDark: isDark)

        // Another status item can still move this one while the popover is
        // open. Checking the frame is cheap and no longer republishes artwork.
        realignIfItemMoved()
    }

    private static let dotDiameter: CGFloat = 5
    private static let dotGap: CGFloat = 2
    private static let imageHeight: CGFloat = 16
    /// Even a 2-LED strip has to stay an easy click target.
    private static let minimumWidth: CGFloat = 24

    private static func imageSize(ledCount: Int) -> NSSize {
        let count = max(ledCount, 1)
        let span = CGFloat(count) * dotDiameter + CGFloat(count - 1) * dotGap
        return NSSize(width: max(span, minimumWidth), height: imageHeight)
    }

    static func stripImage(colors: [RGB], brightness: Double, isDark: Bool) -> NSImage {
        let count = max(colors.count, 1)
        let span = CGFloat(count) * dotDiameter + CGFloat(count - 1) * dotGap
        let size = imageSize(ledCount: count)

        // Resolved up front rather than via `labelColor`: the drawing block runs
        // lazily, outside whatever appearance was current when we asked for it.
        let chassis = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: isDark ? 0.62 : 0.82)
        let chassisOutline = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.34)

        let image = NSImage(size: size, flipped: false) { rect in
            let startX = (rect.width - span) / 2
            let y = (rect.height - dotDiameter) / 2
            for (index, rgb) in colors.enumerated() {
                let dot = NSRect(x: startX + CGFloat(index) * (dotDiameter + dotGap),
                                 y: y, width: dotDiameter, height: dotDiameter)
                let path = NSBezierPath(ovalIn: dot)

                // The unlit chassis. Without it an idle or off program draws
                // near-black dots on a dark menu bar and the item looks like it
                // never launched.
                chassis.setFill()
                path.fill()
                chassisOutline.setStroke()
                path.lineWidth = 0.5
                path.stroke()

                // The lit colour on top, faded in by how lit the LED is, so a
                // dark program tints the chassis instead of erasing it.
                let c = rgb.displayComponents(brightness: brightness)
                let intensity = max(c.r, max(c.g, c.b))
                if intensity > 0.01 {
                    NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: intensity).setFill()
                    path.fill()
                }
            }
            return true
        }
        // The dots are the status, so this is never a template image.
        image.isTemplate = false
        image.accessibilityDescription = "SidePulse status strip"
        return image
    }

    // MARK: - Diagnostics

    /// `--diagnose` answers the one question a screenshot would: does the status
    /// item exist, and is it somewhere on screen you can actually click?
    func diagnose() -> String {
        var lines: [String] = []
        lines.append("status item length: \(statusItem.length)")
        if let button = statusItem.button {
            lines.append("strip view size: \(stripView.frame.size.debugDescription)")
            lines.append("button frame: \(button.frame)")
            if let window = button.window {
                lines.append("item window frame: \(window.frame)")
                lines.append("item is visible: \(window.isVisible)")
                if let screen = NSScreen.screens.first(where: { $0.frame.intersects(window.frame) }) {
                    lines.append("on screen: \(screen.frame) (menu bar height \(screen.frame.maxY - screen.visibleFrame.maxY))")
                } else {
                    lines.append("WARNING: the item's window is not on any screen; the menu bar is full")
                }
            } else {
                lines.append("WARNING: the button has no window; the item was not placed")
            }
        } else {
            lines.append("WARNING: the status item has no button")
        }
        lines.append("visible in menu bar: \(statusItem.isVisible)")

        let probe = NSHostingController(rootView: AnyView(MenuContent(model: model, agents: agents)))
        probe.view.layoutSubtreeIfNeeded()
        lines.append("popover fitting size: \(probe.view.fittingSize)")
        lines.append("popover intrinsic: \(probe.view.intrinsicContentSize)")
        lines.append("popover contentSize: \(popover.contentSize)")
        if let screen = statusItem.button?.window?.screen ?? NSScreen.main {
            lines.append("screen visibleFrame: \(screen.visibleFrame)")
            lines.append("height available below the menu bar: \(screen.visibleFrame.height)")
        }
        return lines.joined(separator: "\n")
    }

    /// Opens the popover exactly as a click would, so `--diagnose` can report
    /// where it actually landed. Showing it is the only way to answer that:
    /// the frame is decided by AppKit at presentation time.
    func openForDiagnostics() {
        guard let button = statusItem.button else { return }
        present(from: button)
    }

    /// Opens the real menu after first-run setup finishes, so the transition
    /// ends on the live product instead of an empty desktop.
    func openAfterOnboarding() {
        guard !popover.isShown, let button = statusItem.button else { return }
        agents.refresh()
        present(from: button)
    }

    /// Switches the preview mode the way the picker in the panel does, so
    /// `--diagnose` can prove the panel follows the item when it resizes.
    func setLEDCountForDiagnostics(_ count: Int) {
        UserDefaults.standard.set(count, forKey: LEDPreview.storageKey)
    }

    /// How far the panel's beak is from the centre of the status item. This is
    /// the number that goes wrong when the item resizes under an open popover.
    func alignmentDiagnostics() -> String {
        var lines: [String] = []
        guard let button = statusItem.button,
              let itemFrame = button.window?.frame else { return "no status item" }
        lines.append("item frame:  \(itemFrame)  (width \(itemFrame.width))")
        guard let popoverFrame = popover.contentViewController?.view.window?.frame else {
            lines.append("WARNING: the popover has no window")
            return lines.joined(separator: "\n")
        }
        lines.append("panel frame: \(popoverFrame)")
        let offset = popoverFrame.midX - itemFrame.midX
        lines.append(String(format: "panel centre − item centre: %.1f pt", offset))
        // The panel is wider than the item, so it is clamped near a screen edge
        // rather than centred; a few points of slack is alignment, not drift.
        lines.append(abs(offset) <= 1 ? "RESULT: aligned" : "RESULT: MISALIGNED by \(abs(offset)) pt")
        return lines.joined(separator: "\n")
    }

    /// The question the screenshot asked: is the whole panel on screen?
    func popoverDiagnostics() -> String {
        var lines: [String] = []
        lines.append("popover shown: \(popover.isShown)")
        lines.append("popover contentSize: \(popover.contentSize)")
        guard let window = popover.contentViewController?.view.window else {
            lines.append("WARNING: the popover has no window")
            return lines.joined(separator: "\n")
        }
        let frame = window.frame
        lines.append("popover window frame: \(frame)")
        guard let screen = window.screen ?? NSScreen.main else { return lines.joined(separator: "\n") }
        let visible = screen.visibleFrame
        lines.append("screen frame: \(screen.frame)")
        lines.append("screen visibleFrame: \(visible)")
        lines.append("overflow above menu bar: \(max(0, frame.maxY - screen.frame.maxY)) pt")
        lines.append("overflow below screen:  \(max(0, visible.minY - frame.minY)) pt")
        lines.append("overflow off left:      \(max(0, visible.minX - frame.minX)) pt")
        lines.append("overflow off right:     \(max(0, frame.maxX - visible.maxX)) pt")
        let fullyOnScreen = frame.maxY <= screen.frame.maxY && frame.minY >= visible.minY
            && frame.minX >= visible.minX && frame.maxX <= visible.maxX
        lines.append(fullyOnScreen ? "RESULT: fully on screen" : "RESULT: CLIPPED")
        return lines.joined(separator: "\n")
    }
}

/// A persistent status-item renderer. Replacing `NSStatusBarButton.image` for
/// every animation frame makes AppKit rebuild and replicate the status item on
/// every display. These tiny layers are created once; subsequent frames touch
/// only LED colors that are visibly different after 8-bit quantization.
private final class StatusStripView: NSView {
    private struct Pixel: Equatable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8
    }

    private static let dotDiameter: CGFloat = 5
    private static let dotGap: CGFloat = 2

    private(set) var ledCount = 0
    private var widthConstraint: NSLayoutConstraint?
    private var chassisLayers: [CALayer] = []
    private var lightLayers: [CALayer] = []
    private var lastPixels: [Pixel] = []
    private var lastIsDark: Bool?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The status button owns the entire click target.
        nil
    }

    func setLEDCount(_ count: Int, width: CGFloat) {
        let count = max(count, 1)
        if widthConstraint == nil {
            let constraint = widthAnchor.constraint(equalToConstant: width)
            constraint.isActive = true
            widthConstraint = constraint
        } else {
            widthConstraint?.constant = width
        }
        guard count != ledCount else { return }

        ledCount = count
        chassisLayers.forEach { $0.removeFromSuperlayer() }
        lightLayers.forEach { $0.removeFromSuperlayer() }
        chassisLayers.removeAll(keepingCapacity: true)
        lightLayers.removeAll(keepingCapacity: true)

        for _ in 0..<count {
            let chassis = CALayer()
            chassis.borderWidth = 0.5
            layer?.addSublayer(chassis)
            chassisLayers.append(chassis)

            let light = CALayer()
            layer?.addSublayer(light)
            lightLayers.append(light)
        }
        lastPixels.removeAll(keepingCapacity: true)
        lastIsDark = nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let span = CGFloat(ledCount) * Self.dotDiameter
            + CGFloat(max(ledCount - 1, 0)) * Self.dotGap
        let startX = (bounds.width - span) / 2
        let y = (bounds.height - Self.dotDiameter) / 2
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in 0..<ledCount {
            let frame = NSRect(
                x: startX + CGFloat(index) * (Self.dotDiameter + Self.dotGap),
                y: y,
                width: Self.dotDiameter,
                height: Self.dotDiameter
            )
            for dot in [chassisLayers[index], lightLayers[index]] {
                dot.frame = frame
                dot.cornerRadius = Self.dotDiameter / 2
                dot.contentsScale = scale
            }
        }
        CATransaction.commit()
    }

    func update(colors: [RGB], brightness: Double, isDark: Bool) {
        guard colors.count == ledCount else { return }
        let pixels = colors.map { color -> Pixel in
            let components = color.displayComponents(brightness: brightness)
            let intensity = max(components.r, max(components.g, components.b))
            return Pixel(
                red: Self.quantize(components.r),
                green: Self.quantize(components.g),
                blue: Self.quantize(components.b),
                alpha: Self.quantize(intensity)
            )
        }
        guard pixels != lastPixels || isDark != lastIsDark else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isDark != lastIsDark {
            let chassis = NSColor(
                srgbRed: 1, green: 1, blue: 1,
                alpha: isDark ? 0.62 : 0.82
            ).cgColor
            let outline = NSColor(
                srgbRed: 0, green: 0, blue: 0, alpha: 0.34
            ).cgColor
            for layer in chassisLayers {
                layer.backgroundColor = chassis
                layer.borderColor = outline
            }
        }
        for (index, pixel) in pixels.enumerated() where
            index >= lastPixels.count || pixel != lastPixels[index] {
            lightLayers[index].backgroundColor = NSColor(
                srgbRed: CGFloat(pixel.red) / 255,
                green: CGFloat(pixel.green) / 255,
                blue: CGFloat(pixel.blue) / 255,
                alpha: 1
            ).cgColor
            lightLayers[index].opacity = Float(pixel.alpha) / 255
        }
        CATransaction.commit()

        lastPixels = pixels
        lastIsDark = isDark
    }

    private static func quantize(_ value: Double) -> UInt8 {
        UInt8((max(0, min(1, value)) * 255).rounded())
    }
}
