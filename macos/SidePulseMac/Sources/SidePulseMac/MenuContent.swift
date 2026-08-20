// MenuContent.swift — the popover behind the menu bar item: what the phone is
// being served, whether anything is reaching it, which agents are wired up, and
// the few actions worth having without a terminal.

import SwiftUI

struct MenuContent: View {
    @ObservedObject var model: ServerModel
    @ObservedObject var agents: AgentHooksModel
    @AppStorage(LEDPreview.storageKey) private var ledCount = LEDPreview.defaultCount

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            VStack(alignment: .leading, spacing: 8) {
                LEDStage(program: model.program, ledCount: ledCount)
                Picker("", selection: $ledCount) {
                    ForEach(LEDPreview.options, id: \.count) { option in
                        Text(option.label).tag(option.count)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }

            if let parseError = model.parseError {
                notice(parseError, color: Theme.attention)
            }

            agentsSection
            activitySection

            Divider().padding(.vertical, 1)
            footer
        }
        .padding(Theme.panelPadding)
        .frame(width: Theme.panelWidth)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 9) {
            appMark
            VStack(alignment: .leading, spacing: 1) {
                Text("SidePulse")
                    .font(.system(size: 13.5, weight: .semibold))
                Text(model.computerName)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            StatusPill(text: statusText, color: statusColor, live: model.isRunning)
        }
    }

    /// A three-dot mark rather than an icon file: it is the product's own
    /// language, and it keeps the bundle free of an asset that would need
    /// redrawing for every appearance.
    private var appMark: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Theme.live.opacity(model.isRunning ? 1 - Double(i) * 0.3 : 0.25))
                    .frame(width: 4, height: 4)
            }
        }
        .padding(.horizontal, 5)
        .frame(width: 28, height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(colors: [Theme.stageTop, Theme.stageBottom],
                                     startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    // MARK: Agents

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Agents") {
                HStack(spacing: 5) {
                    Text("\(agents.connectedCount)/\(agents.installableProviders.count)")
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button(agents.allConnected ? "Disconnect hooks" : "Connect hooks") {
                        agents.toggleHooks()
                    }
                    .buttonStyle(PillButtonStyle(prominent: !agents.allConnected))
                    .disabled(!agents.canToggleHooks)
                }
            }

            Card(padding: 4) {
                VStack(spacing: 0) {
                    ForEach(Array(AgentProvider.primaryCases.enumerated()), id: \.element.id) { index, provider in
                        if index > 0 {
                            Divider().opacity(0.4).padding(.leading, 34)
                        }
                        agentRow(provider)
                    }
                }
            }

            // Controls first, messages last: the picker belongs with the rows it
            // affects, not stranded underneath a notice.
            HStack(spacing: 6) {
                Text("Controller")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Picker("", selection: $agents.controller) {
                    ForEach(SidePulseController.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 168)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
            .padding(.top, 1)

            if !agents.helperInstalled {
                notice("No \(agents.controller.binaryName) in ~/bin — run ./install.sh first.",
                       color: Theme.attention)
            } else if let error = agents.errorMessage {
                notice(error, color: Theme.fault)
            } else if agents.connectedCount > 0, let caveat = pendingCaveat {
                notice(caveat, color: .secondary)
            }
        }
    }

    /// The caveat for any connected provider that has one — currently only
    /// Codex's one-time `/hooks` trust review.
    private var pendingCaveat: String? {
        AgentProvider.primaryCases
            .first { agents.status[$0] == .connected && $0.caveat != nil }?
            .caveat
    }

    private func agentRow(_ provider: AgentProvider) -> some View {
        let state = agents.status[provider] ?? .unavailable
        let available = state != .unavailable
        let connected = state == .connected

        return HStack(spacing: 9) {
            Image(systemName: provider.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(connected ? Theme.live : Color.secondary)
                .frame(width: 25, height: 25)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill((connected ? Theme.live : Color.primary).opacity(connected ? 0.12 : 0.05))
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(provider.displayName)
                    .font(.system(size: 12, weight: .medium))
                Text(subtitle(for: state, provider: provider))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            if available {
                if connected {
                    StatusDot(color: Theme.live, size: 6)
                } else {
                    Text("Not connected")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Not installed")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .opacity(available ? 1 : 0.55)
        .animation(.easeOut(duration: 0.15), value: connected)
    }

    private func subtitle(for state: AgentHooksModel.Status, provider: AgentProvider) -> String {
        switch state {
        case .unavailable: return provider.displayPath
        case .connected: return "\(provider.events.count) hooks · \(provider.displayPath)"
        case .disconnected: return provider.displayPath
        }
    }

    // MARK: Activity

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Activity")
            Card {
                VStack(spacing: 5) {
                    StatRow(label: "Writes seen", value: "\(model.writesSeen)")
                    StatRow(label: "Requests served", value: "\(model.requestsServed)")
                    StatRow(label: "Last write", value: relative(model.lastWriteAt))
                    StatRow(label: "Last poll", value: relative(model.lastRequestAt))
                    Divider().opacity(0.4)
                    StatRow(label: "File",
                            value: (model.filePath as NSString).abbreviatingWithTildeInPath,
                            truncateHead: true)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 2) {
            Button { model.revealFileInFinder() } label: { Image(systemName: "folder") }
                .buttonStyle(IconButtonStyle())
                .help("Reveal LEDS.TXT in Finder")
            Button { model.openWriteLog() } label: { Image(systemName: "list.bullet.rectangle") }
                .buttonStyle(IconButtonStyle())
                .help("Open the write log")
            Button { model.copyHealthURL() } label: { Image(systemName: "link") }
                .buttonStyle(IconButtonStyle())
                .help("Copy the /health URL")
                .disabled(!model.isRunning)
            Button { model.restart() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(IconButtonStyle())
                .help(model.isRunning ? "Restart the server" : "Start the server")

            Spacer(minLength: 0)

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(PillButtonStyle())
        }
    }

    // MARK: Shared pieces

    private func notice(_ text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 10.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 2)
    }

    private var statusColor: Color {
        switch model.serverState {
        case .running: return Theme.live
        case .stopped: return .secondary
        case .failed: return Theme.fault
        }
    }

    private var statusText: String {
        switch model.serverState {
        case .running(let port, _): return "Live · :\(port)"
        case .stopped: return "Stopped"
        case .failed(let message): return message
        }
    }

    private func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 2 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }
}

/// The LED count is shared between the popover preview and the menu bar item,
/// so it lives in one place both can read.
enum LEDPreview {
    static let storageKey = "sidepulse.ledCount"
    static let defaultCount = 8
    static let options: [(count: Int, label: String)] = [
        (8, "ATLD · 8 LEDs"),
        (2, "Side Post · 2 LEDs"),
    ]
}
