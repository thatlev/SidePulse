// MenuContent.swift — the popover behind the menu bar item: what the phone is
// being served, whether anything is reaching it, and the few actions worth
// having without a terminal.

import SwiftUI

struct MenuContent: View {
    @ObservedObject var model: ServerModel
    @State private var ledCount = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            VStack(alignment: .leading, spacing: 8) {
                LEDStripView(program: model.program, ledCount: ledCount)
                Picker("", selection: $ledCount) {
                    Text("ATLD · 8").tag(8)
                    Text("Side Post · 2").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))

            if let parseError = model.parseError {
                Label(parseError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            stats
            Divider()
            actions
        }
        .padding(16)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text("SidePulse")
                .font(.headline)
            Spacer()
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var stats: some View {
        VStack(spacing: 5) {
            row("Writes seen", "\(model.writesSeen)")
            row("Requests served", "\(model.requestsServed)")
            row("Last write", relative(model.lastWriteAt))
            row("Last poll", relative(model.lastRequestAt))
            row("File", (model.filePath as NSString).abbreviatingWithTildeInPath)
        }
        .font(.caption)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    private var actions: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Button("Reveal LEDS.TXT") { model.revealFileInFinder() }
                Button("Write log") { model.openWriteLog() }
                Button("Copy /health") { model.copyHealthURL() }
            }
            .controlSize(.small)
            HStack(spacing: 6) {
                Button(model.isRunning ? "Restart server" : "Start server") { model.restart() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .controlSize(.small)
        }
    }

    private var statusColor: Color {
        switch model.serverState {
        case .running: return .green
        case .stopped: return .secondary
        case .failed: return .red
        }
    }

    private var statusText: String {
        switch model.serverState {
        case .running(let port, let name): return "\(name) · :\(port)"
        case .stopped: return "stopped"
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
