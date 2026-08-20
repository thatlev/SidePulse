import AppKit
import SwiftUI

struct SidePulseOnboardingView: View {
    @ObservedObject var model: ServerModel
    @ObservedObject var agents: AgentHooksModel
    let onFinish: () -> Void

    @State private var step = Step.welcome
    @State private var completedPromptSteps: Set<Step> = []
    @State private var copiedPromptStep: Step?
    @State private var copyFeedbackGeneration = 0
    @State private var openedX = false
    @State private var openedGitHub = false

    private enum Step: Int, CaseIterable {
        case welcome
        case server
        case agents
        case iphone
        case finish

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .server: return "Mac"
            case .agents: return "Agents"
            case .iphone: return "iPhone"
            case .finish: return "Finish"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            navigation
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
            Divider()
            stepContent
                .id(step)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
                .padding(.horizontal, 50)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(minWidth: 660, idealWidth: 700, minHeight: 520, idealHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var navigation: some View {
        HStack(spacing: 9) {
            SidePulseMark(isLive: model.isRunning, size: 28)
            Text("SidePulse").font(.headline)
            Spacer()
            ForEach(Step.allCases, id: \.self) { item in
                HStack(spacing: 5) {
                    Image(systemName: item.rawValue < step.rawValue ? "checkmark.circle.fill" : (item == step ? "circle.inset.filled" : "circle"))
                        .font(.system(size: 10, weight: .semibold))
                    Text(item.title)
                        .font(.caption.weight(item == step ? .semibold : .regular))
                }
                .foregroundStyle(item.rawValue <= step.rawValue ? Color.primary : Color.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(item == step ? Theme.live.opacity(0.12) : .clear))
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:
            VStack(spacing: 24) {
                SidePulseMark(isLive: true, size: 88)
                VStack(spacing: 8) {
                    Text("Know when your agents need you")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text("SidePulse turns agent activity into a light you can understand at a glance.\nSetup takes about two minutes.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 28) {
                    benefit("waveform.path", "Live status")
                    benefit("lock.shield", "Local hooks")
                    benefit("iphone", "Phone display")
                }
            }
        case .server:
            centered {
                heading(
                    icon: model.isRunning ? "checkmark.circle.fill" : "network",
                    color: model.isRunning ? Theme.live : Theme.attention,
                    title: model.isRunning ? "The Mac bridge is live" : "Starting the Mac bridge",
                    detail: model.isRunning
                        ? "SidePulse is watching the light program and advertising it privately on your local network."
                        : "The local server is starting. No account or cloud service is required."
                )
                if !model.isRunning {
                    statusCard(
                        title: "Starting…",
                        detail: model.computerName,
                        color: Theme.attention
                    )
                    Button("Try again") { model.restart() }
                }
            }
        case .agents:
            centered {
                heading(
                    icon: agents.connectedCount > 0 ? "checkmark.circle.fill" : "point.3.connected.trianglepath.dotted",
                    color: agents.connectedCount > 0 ? Theme.live : .accentColor,
                    title: agents.connectedCount > 0 ? "Your agents are connected" : "Connect the agents on this Mac",
                    detail: "SidePulse adds reversible lifecycle hooks. It never adds instructions to your projects or sends message content anywhere."
                )

                if agents.helperInstalled {
                    VStack(spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(agents.connectedCount) of \(agents.installableProviders.count) available agents connected")
                                    .font(.headline)
                                Text("Claude Code, Codex, and Kimi are detected from their local config folders.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Connect all") { agents.connectAll() }
                                .buttonStyle(.borderedProminent)
                                .disabled(!agents.canConnectAny)
                        }
                        if let error = agents.errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(Theme.fault)
                        }
                    }
                    .onAppear { agents.refresh() }
                    .padding(16)
                    .background(onboardingSurface)
                } else {
                    promptCard(
                        text: agentSetupPrompt,
                        linkTitle: "Read the setup guide",
                        link: URLs.mobileGuide,
                        copied: copiedPromptStep == .agents
                    ) {
                        copy(agentSetupPrompt, for: .agents)
                    }
                }
            }
        case .iphone:
            centered {
                heading(
                    icon: model.requestsServed > 0 ? "checkmark.circle.fill" : "iphone.radiowaves.left.and.right",
                    color: model.requestsServed > 0 ? Theme.live : .accentColor,
                    title: model.requestsServed > 0 ? "Your iPhone found SidePulse" : "Install the iPhone display",
                    detail: model.requestsServed > 0
                        ? "The phone has requested the live light program from this Mac."
                        : "Copy this prompt to your coding agent. It will build the app and stop when Xcode needs your signing approval."
                )
                if model.requestsServed == 0 {
                    promptCard(
                        text: iphoneSetupPrompt,
                        linkTitle: "Open mobile setup guide",
                        link: URLs.mobileGuide,
                        copied: copiedPromptStep == .iphone
                    ) {
                        copy(iphoneSetupPrompt, for: .iphone)
                    }
                }
            }
        case .finish:
            centered {
                heading(
                    icon: "heart.fill",
                    color: .pink,
                    title: "Help SidePulse grow",
                    detail: "Follow the build and star the repository. SidePulse only records that each link was opened."
                )
                VStack(spacing: 10) {
                    supportButton("Follow @thatlevco on X", icon: "at", done: openedX) {
                        openedX = true
                        NSWorkspace.shared.open(URLs.xProfile)
                    }
                    supportButton("Star SidePulse on GitHub", icon: "star.fill", done: openedGitHub) {
                        openedGitHub = true
                        NSWorkspace.shared.open(URLs.repository)
                    }
                }
                .frame(maxWidth: 500)
            }
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { move(to: step.rawValue - 1) }
            }
            Spacer()
            Button(footerActionTitle) {
                if step == .finish { onFinish() } else { move(to: step.rawValue + 1) }
            }
            .buttonStyle(.borderedProminent)
            .tint(canContinue ? Theme.live : Color.gray)
            .keyboardShortcut(.defaultAction)
            .disabled(step == .finish && !canContinue)
            .accessibilityHint(
                footerActionTitle == "Skip"
                    ? "Move to the next setup step without completing this one."
                    : "Complete this setup step and continue."
            )
        }
    }

    private var footerActionTitle: String {
        if step == .finish { return "Finish" }
        return canContinue ? "Continue" : "Skip"
    }

    private var canContinue: Bool {
        switch step {
        case .server: return model.isRunning
        case .agents: return agents.connectedCount > 0 || completedPromptSteps.contains(.agents)
        case .iphone: return model.requestsServed > 0 || completedPromptSteps.contains(.iphone)
        case .finish: return openedX && openedGitHub
        case .welcome: return true
        }
    }

    private func centered<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 22) {
            content()
        }
            .frame(maxWidth: 560, maxHeight: .infinity)
    }

    private func heading(icon: String, color: Color, title: String, detail: String) -> some View {
        VStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(color)
                .frame(height: 42)
            Text(title).font(.title.weight(.bold)).multilineTextAlignment(.center)
            Text(detail)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func benefit(_ icon: String, _ title: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon).font(.title3).foregroundStyle(Theme.live)
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
    }

    private func statusCard(title: String, detail: String, color: Color) -> some View {
        HStack(spacing: 12) {
            StatusDot(color: color, size: 10, glow: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: 500)
        .background(onboardingSurface)
    }

    private func promptCard(
        text: String,
        linkTitle: String,
        link: URL,
        copied: Bool,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(6)
                .textSelection(.enabled)
            HStack {
                Link(linkTitle, destination: link).font(.caption)
                Spacer()
                Button(action: action) {
                    ZStack {
                        Label("Copy prompt", systemImage: "doc.on.doc")
                            .opacity(copied ? 0 : 1)
                        Label("Copied", systemImage: "checkmark")
                            .opacity(copied ? 1 : 0)
                    }
                }
                .buttonStyle(.borderedProminent)
                .help(copied ? "Copied. Click to copy it again." : "Copy the complete setup prompt.")
            }
        }
        .padding(16)
        .frame(maxWidth: 540)
        .background(onboardingSurface)
    }

    private func supportButton(_ title: String, icon: String, done: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(done ? Theme.live : Color.accentColor)
                    .frame(width: 34)
                Text(title).font(.headline)
                Spacer()
                Image(systemName: done ? "checkmark.circle.fill" : "arrow.up.right")
                    .foregroundStyle(done ? Theme.live : Color.secondary)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(onboardingSurface)
    }

    private var onboardingSurface: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
    }

    private func move(to rawValue: Int) {
        guard let next = Step(rawValue: rawValue) else { return }
        copiedPromptStep = nil
        withAnimation(.easeOut(duration: 0.2)) { step = next }
    }

    private func copy(_ value: String, for step: Step) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        completedPromptSteps.insert(step)
        copiedPromptStep = step
        copyFeedbackGeneration += 1
        let generation = copyFeedbackGeneration
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "Setup prompt copied",
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            guard generation == copyFeedbackGeneration, copiedPromptStep == step else { return }
            copiedPromptStep = nil
        }
    }

    private var agentSetupPrompt: String {
        "Set up SidePulse for the coding agents installed on this Mac. Follow \(URLs.mobileGuide.absoluteString), install the local helpers, connect every available provider, and stop only for approval steps I must click. Do not add instructions to project files."
    }

    private var iphoneSetupPrompt: String {
        "Build and install SidePulse on my connected iPhone. Follow \(URLs.mobileGuide.absoluteString) exactly. Ask me only for Apple ID, signing-team, trust, Developer Mode, or Local Network approvals that require my click; then verify the Mac app shows at least one request served."
    }
}

private struct SidePulseMark: View {
    let isLive: Bool
    let size: CGFloat

    var body: some View {
        HStack(spacing: size * 0.07) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Theme.live.opacity(isLive ? 1 - Double(index) * 0.28 : 0.28))
                    .frame(width: size * 0.13, height: size * 0.13)
            }
        }
        .frame(width: size, height: size)
        .background(
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(LinearGradient(colors: [Theme.stageTop, Theme.stageBottom], startPoint: .top, endPoint: .bottom))
        )
        .accessibilityHidden(true)
    }
}

private enum URLs {
    static let repository = URL(string: "https://github.com/thatlev/SidePulse")!
    static let mobileGuide = URL(string: "https://github.com/thatlev/SidePulse/blob/main/docs/MOBILE-SETUP.md")!
    static let xProfile = URL(string: "https://x.com/thatlevco")!
}
