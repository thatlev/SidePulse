// ContentView.swift — a dark room for the light to live in.

import SwiftUI

enum DeviceProfile: String, CaseIterable, Identifiable {
    case atld
    case sidePost

    var id: String { rawValue }
    var title: String {
        switch self {
        case .atld: return "ATLD · 8"
        case .sidePost: return "Side Post · 2"
        }
    }
    var ledCount: Int { self == .atld ? 8 : 2 }
}

struct ContentView: View {
    @StateObject private var client = SidePulseClient()
    @State private var engine = LEDEngine(ledCount: 8)
    @State private var parseError: String?
    @State private var showOverlay = false
    @State private var overlayToken = 0
    @AppStorage("appBrightness") private var appBrightness = 1.0
    @AppStorage("keepAwake") private var keepAwake = true
    @AppStorage("deviceProfile") private var deviceProfile: DeviceProfile = .atld

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            // The portrait pill is (shortSide * 0.85) long and 32 pt thick. Keep
            // that exact length:thickness ratio in landscape so the bar just
            // scales up to span the screen width instead of becoming a fat stub —
            // and every LED stays on-screen (0.90 leaves margin for the glows).
            let shortSide = min(geo.size.width, geo.size.height)
            let portraitRatio = (shortSide * 0.85) / 32
            let atldWidth = geo.size.width * (isLandscape ? 0.90 : 0.85)
            // The Side Post is a chunky two-dot pill, not a shortened strip.
            // Its side-on face is roughly 2.15:1 and should feel substantial.
            let sidePostWidth = min(geo.size.width * (isLandscape ? 0.46 : 0.52),
                                    isLandscape ? 278 : 206)
            let pillWidth = deviceProfile == .atld ? atldWidth : sidePostWidth
            let pillHeight: CGFloat = deviceProfile == .atld
                ? (isLandscape ? pillWidth / portraitRatio : 32)
                : pillWidth / 2.15
            ZStack {
                Color.black.ignoresSafeArea()

                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let colors = Array(engine.colors(at: t).prefix(deviceProfile.ledCount))
                    PillView(profile: deviceProfile,
                             colors: colors,
                             firmwareBrightness: engine.brightness,
                             alpha: appBrightness,
                             pillWidth: pillWidth,
                             pillHeight: pillHeight)
                }

                if showOverlay {
                    OverlayView(client: client,
                                parseError: parseError,
                                appBrightness: $appBrightness,
                                keepAwake: $keepAwake,
                                deviceProfile: $deviceProfile,
                                bumpToken: { overlayToken += 1 })
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { showOverlay.toggle() }
                overlayToken += 1
            }
        }
        // Status bar (clock, battery) and the Dynamic Island / its Live
        // Activities stay visible — nothing is hidden here on purpose.
        .preferredColorScheme(.dark)
        .onAppear {
            engine.load(BuiltinPrograms.disconnected, at: Date().timeIntervalSinceReferenceDate)
            client.onProgram = { text in
                let now = Date().timeIntervalSinceReferenceDate
                do {
                    engine.load(try LEDSParser.parse(text), at: now)
                    parseError = nil
                } catch {
                    // Firmware parse-error behavior: red blink, 6 times, 150 ms.
                    engine.load(BuiltinPrograms.errorBlink, at: now)
                    parseError = "\(error)"
                }
            }
            client.start()
            updateIdleTimer()
        }
        .onChange(of: client.state) {
            if client.state == .disconnected {
                engine.load(BuiltinPrograms.disconnected, at: Date().timeIntervalSinceReferenceDate)
            }
            updateIdleTimer()
        }
        .onChange(of: keepAwake) { updateIdleTimer() }
    }

    private func updateIdleTimer() {
        let connected: Bool
        if case .connected = client.state { connected = true } else { connected = false }
        UIApplication.shared.isIdleTimerDisabled = keepAwake && connected
    }
}

// MARK: - The pill

struct PillView: View {
    let profile: DeviceProfile
    let colors: [RGB]
    let firmwareBrightness: Double
    let alpha: Double
    let pillWidth: CGFloat
    let pillHeight: CGFloat

    var body: some View {
        // LED core diameter tracks the pill height (0.19 keeps the portrait
        // 32 pt pill at the original 6 pt core), but never exceeds half the LED
        // spacing, so the dots stay distinct when the bar fills a landscape screen.
        let count = max(colors.count, 1)
        let fullRowWidth = pillWidth - pillHeight
        let spacing = profile == .atld
            ? fullRowWidth / CGFloat(count)
            : pillWidth * 0.50
        let coreScale: CGFloat = profile == .atld ? 0.19 : 0.22
        let core = min(pillHeight * coreScale, spacing * 0.5)
        ZStack {
            housing

            if profile == .atld {
                HStack(spacing: 0) {
                    ForEach(0..<colors.count, id: \.self) { i in
                        LEDView(color: ledColor(i), core: core)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(width: fullRowWidth, height: pillHeight)
            } else {
                HStack(spacing: max(0, spacing - core)) {
                    ForEach(0..<colors.count, id: \.self) { i in
                        LEDView(color: ledColor(i), core: core)
                            .frame(width: core, height: pillHeight)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var housing: some View {
        let fill = Color(red: 0x0d / 255.0, green: 0x0d / 255.0, blue: 0x0f / 255.0)
        let edge = Color(red: 0x1c / 255.0, green: 0x1c / 255.0, blue: 0x1e / 255.0)
        if profile == .atld {
            Capsule()
                .fill(fill)
                .overlay(Capsule().strokeBorder(edge, lineWidth: 1))
                .frame(width: pillWidth, height: pillHeight)
        } else {
            Capsule()
                .fill(fill)
                .overlay(
                    Capsule()
                        .strokeBorder(edge.opacity(0.95), lineWidth: 1)
                )
                .overlay(alignment: .top) {
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.035), lineWidth: 1)
                        .mask(
                            LinearGradient(colors: [.white, .clear],
                                           startPoint: .top,
                                           endPoint: .center)
                        )
                }
                .frame(width: pillWidth, height: pillHeight)
        }
    }

    private func ledColor(_ i: Int) -> Color {
        let c = colors[i].displayComponents(brightness: firmwareBrightness)
        return Color(red: c.r, green: c.g, blue: c.b).opacity(alpha)
    }
}

/// A bright core plus screen-blended radial glows so adjacent LEDs' light
/// physically mixes — the transparent-casing diffusion effect.
struct LEDView: View {
    let color: Color
    let core: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: core * 6, height: core * 6)
                .blur(radius: core * 2.2)
                .blendMode(.screen)
            Circle()
                .fill(color)
                .frame(width: core * 2.6, height: core * 2.6)
                .blur(radius: core * 0.8)
                .blendMode(.screen)
            Circle()
                .fill(color)
                .frame(width: core, height: core)
                .blur(radius: max(0.4, core * 0.07))
        }
    }
}

// MARK: - Overlay chrome

struct OverlayView: View {
    @ObservedObject var client: SidePulseClient
    let parseError: String?
    @Binding var appBrightness: Double
    @Binding var keepAwake: Bool
    @Binding var deviceProfile: DeviceProfile
    let bumpToken: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusIsConnected ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(statusLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                if parseError != nil {
                    Label("parse error", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(.red)
                }
            }

            if client.discovered.count > 1 {
                ForEach(client.discovered, id: \.self) { name in
                    Button {
                        client.connect(toName: name)
                        bumpToken()
                    } label: {
                        HStack {
                            Image(systemName: "dot.radiowaves.left.and.right")
                            Text(name)
                            Spacer()
                        }
                        .font(.footnote)
                    }
                    .buttonStyle(.bordered)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Device")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Device", selection: $deviceProfile) {
                    ForEach(DeviceProfile.allCases) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: deviceProfile) { bumpToken() }
            }

            HStack {
                Image(systemName: "sun.min")
                    .foregroundStyle(.secondary)
                Slider(value: $appBrightness, in: 0.05...1) { _ in bumpToken() }
                Image(systemName: "sun.max")
                    .foregroundStyle(.secondary)
            }

            Toggle("Keep awake", isOn: $keepAwake)
                .font(.footnote)
                .onChange(of: keepAwake) { bumpToken() }

            if let parseError {
                Text(parseError)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollView {
                Text(client.rawText.isEmpty ? "(no program received yet)" : client.rawText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
        }
        .padding(16)
        .frame(maxWidth: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var statusIsConnected: Bool {
        if case .connected = client.state { return true }
        return false
    }

    private var statusLabel: String {
        switch client.state {
        case .searching: return "searching for sidepulse-server…"
        case .connecting(let name): return "connecting to \(name)…"
        case .connected(let name): return name
        case .disconnected: return "disconnected"
        }
    }
}

#Preview {
    ContentView()
}
