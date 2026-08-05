// AgentHooksModel.swift — observable state for the Agents card: which providers
// are wired up, which controller they call, and the result of the last action.

import Foundation
import SwiftUI

@MainActor
final class AgentHooksModel: ObservableObject {
    enum Status: Equatable {
        /// The agent is not installed on this Mac — nothing to wire up.
        case unavailable
        case connected
        case disconnected
    }

    @Published private(set) var status: [AgentProvider: Status] = [:]
    /// Non-nil only after a failed action. Cleared by the next successful one.
    @Published private(set) var errorMessage: String?
    @Published var controller: SidePulseController {
        didSet {
            guard controller != oldValue else { return }
            UserDefaults.standard.set(controller.rawValue, forKey: Self.controllerKey)
            // Connected agents point at the old helper by name, so the change
            // only takes effect once their entries are rewritten.
            reconnectConnected()
        }
    }

    private static let controllerKey = "sidepulse.controller"

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.controllerKey)
        controller = stored.flatMap(SidePulseController.init(rawValue:)) ?? .solo
        refresh()
    }

    // MARK: Derived state

    var installableProviders: [AgentProvider] {
        AgentProvider.allCases.filter { status[$0] != .unavailable }
    }

    var connectedCount: Int {
        status.values.filter { $0 == .connected }.count
    }

    var helperInstalled: Bool { controller.isInstalled }

    /// True when there is at least one agent left to connect, so "Connect all"
    /// can be disabled rather than silently doing nothing.
    var canConnectAny: Bool {
        helperInstalled && installableProviders.contains { status[$0] == .disconnected }
    }

    var canDisconnectAny: Bool {
        installableProviders.contains { status[$0] == .connected }
    }

    // MARK: Actions

    func refresh() {
        var next: [AgentProvider: Status] = [:]
        for provider in AgentProvider.allCases {
            guard provider.isAvailable else { next[provider] = .unavailable; continue }
            next[provider] = AgentHooks.isConnected(provider) ? .connected : .disconnected
        }
        status = next
    }

    func connect(_ provider: AgentProvider) {
        perform { try AgentHooks.connect(provider, controller: controller) }
    }

    func disconnect(_ provider: AgentProvider) {
        perform { try AgentHooks.disconnect(provider) }
    }

    func connectAll() {
        perform {
            for provider in installableProviders where status[provider] == .disconnected {
                try AgentHooks.connect(provider, controller: controller)
            }
        }
    }

    func disconnectAll() {
        perform {
            for provider in installableProviders where status[provider] == .connected {
                try AgentHooks.disconnect(provider)
            }
        }
    }

    private func reconnectConnected() {
        perform {
            for provider in installableProviders where status[provider] == .connected {
                try AgentHooks.connect(provider, controller: controller)
            }
        }
    }

    /// Every mutation refreshes afterwards, including on failure: a partial
    /// batch must still be reflected accurately in the UI.
    private func perform(_ work: () throws -> Void) {
        do {
            try work()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }
}
