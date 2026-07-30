// SidePulseClient.swift — Bonjour discovery + 500 ms ETag polling.
// The phone receives the raw, unmodified file and parses it itself.

import Foundation
import Network

/// Decides what the renderer should do with a successful poll. Kept separate
/// from URLSession so the gray-screen recovery behavior is unit-testable.
enum PollProgramResult: Equatable {
    case received(String)
    case replay(String)
    case unchanged
    case forceFullFetch
}

enum PollProgramRecovery {
    static func resolve(statusCode: Int, data: Data, cachedProgram: String,
                        needsReplay: Bool) -> PollProgramResult {
        if statusCode == 200 {
            return .received(String(decoding: data, as: UTF8.self))
        }
        guard statusCode == 304 else { return .unchanged }
        if needsReplay {
            return cachedProgram.isEmpty ? .forceFullFetch : .replay(cachedProgram)
        }
        return .unchanged
    }
}

@MainActor
final class SidePulseClient: ObservableObject {
    enum ConnState: Equatable {
        case searching
        case connecting(String)
        case connected(String)
        case disconnected
    }

    @Published var state: ConnState = .searching
    @Published var rawText: String = ""
    @Published var discovered: [String] = []

    /// Called on every 200 response with the raw file text (reparse + restart).
    var onProgram: ((String) -> Void)?

    private var browser: NWBrowser?
    private var results: [NWBrowser.Result] = []
    private var resolveConnection: NWConnection?
    private var pollTask: Task<Void, Never>?
    private var baseURL: URL?
    private var etag: String?
    private var failures = 0
    // ContentView replaces the LEDs with its gray disconnected program. A 304
    // after reconnect has no body, so remember to replay the cached good
    // program instead of leaving that temporary gray program on screen.
    private var needsProgramReplay = false
    private var serverName = ""
    private let session: URLSession

    private static let lastServerKey = "lastServer"

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 3
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    func start() {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_sidepulse._tcp", domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.handleResults(Array(results)) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func connect(toName name: String) {
        guard let result = results.first(where: { Self.name(of: $0) == name }) else { return }
        connect(result)
    }

    private static func name(of result: NWBrowser.Result) -> String? {
        if case .service(let name, _, _, _) = result.endpoint { return name }
        return nil
    }

    private func handleResults(_ newResults: [NWBrowser.Result]) {
        results = newResults
        discovered = newResults.compactMap(Self.name(of:)).sorted()
        switch state {
        case .connecting, .connected:
            return
        case .searching, .disconnected:
            let last = UserDefaults.standard.string(forKey: Self.lastServerKey)
            if let last, let r = results.first(where: { Self.name(of: $0) == last }) {
                connect(r)
            } else if results.count == 1 {
                connect(results[0])
            }
            // Several unknown servers: leave the picker (overlay) to choose.
        }
    }

    private func connect(_ result: NWBrowser.Result) {
        guard let name = Self.name(of: result) else { return }
        state = .connecting(name)
        serverName = name

        // Resolve the Bonjour endpoint to host:port by opening a throwaway
        // TCP connection and reading the resolved remote endpoint.
        let conn = NWConnection(to: result.endpoint, using: .tcp)
        let previous = resolveConnection
        resolveConnection = conn
        // Install the new connection as current before cancelling the previous
        // one. Its delayed .cancelled callback must not mark the new attempt as
        // disconnected and replace the LEDs with gray.
        previous?.cancel()
        conn.stateUpdateHandler = { [weak self, weak conn] st in
            Task { @MainActor in
                guard let self, let conn else { return }
                guard self.resolveConnection === conn else { return }
                switch st {
                case .ready:
                    if let ep = conn.currentPath?.remoteEndpoint,
                       case .hostPort(let host, let port) = ep {
                        self.resolveConnection = nil
                        conn.cancel()
                        self.beginPolling(host: host, port: port)
                    } else {
                        self.resolveConnection = nil
                        conn.cancel()
                        self.markDisconnected()
                    }
                case .failed:
                    self.resolveConnection = nil
                    self.markDisconnected()
                case .cancelled:
                    // A current resolver can be cancelled by the network. A
                    // superseded resolver was rejected by the identity guard.
                    self.resolveConnection = nil
                    if case .connecting = self.state { self.markDisconnected() }
                default:
                    break
                }
            }
        }
        conn.start(queue: .main)
    }

    private func beginPolling(host: NWEndpoint.Host, port: NWEndpoint.Port) {
        let hostString: String
        switch host {
        case .ipv4(let addr):
            // Resolved addresses can carry a "%en0" interface scope; IPv4 URLs must not.
            let raw = "\(addr)"
            hostString = raw.split(separator: "%").first.map(String.init) ?? raw
        case .ipv6(let addr):
            // Bracket for URLs; keep the scope but percent-encode the "%".
            hostString = "[" + "\(addr)".replacingOccurrences(of: "%", with: "%25") + "]"
        case .name(let n, _):
            hostString = n
        @unknown default:
            markDisconnected()
            return
        }
        guard let url = URL(string: "http://\(hostString):\(port.rawValue)/leds.txt") else {
            markDisconnected()
            return
        }
        baseURL = url
        etag = nil
        failures = 0
        UserDefaults.standard.set(serverName, forKey: Self.lastServerKey)
        state = .connected(serverName)

        pollTask?.cancel()
        pollTask = Task { [weak self] in // inherits MainActor
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                let backoff = self.failures >= 12
                try? await Task.sleep(nanoseconds: backoff ? 2_000_000_000 : 500_000_000)
            }
        }
    }

    private func pollOnce() async {
        guard let url = baseURL else { return }
        var request = URLRequest(url: url)
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200 || http.statusCode == 304 else {
                throw URLError(.badServerResponse)
            }
            let result = PollProgramRecovery.resolve(
                statusCode: http.statusCode,
                data: data,
                cachedProgram: rawText,
                needsReplay: needsProgramReplay
            )
            switch result {
            case .received(let text):
                etag = http.value(forHTTPHeaderField: "ETag")
                rawText = text
                onProgram?(text)
                needsProgramReplay = false
            case .replay(let text):
                // The server correctly says its file is unchanged, but the
                // renderer is currently showing our temporary gray fallback.
                onProgram?(text)
                needsProgramReplay = false
            case .forceFullFetch:
                // No cached body exists to replay. Omit If-None-Match on the
                // next poll so the server must return a complete program.
                etag = nil
            case .unchanged:
                break
            }
            failures = 0
            if state != .connected(serverName) { state = .connected(serverName) }
        } catch {
            failures += 1
            // Only show the grey "disconnected" screen after a sustained outage
            // (~6 s at 500 ms polls), so brief Wi-Fi blips don't wipe a valid
            // program off the strip. Until then we keep displaying the last one.
            if failures == 12 {
                markDisconnected()
            }
            if failures >= 24, failures.isMultiple(of: 12) {
                // Still down after ~12 s more: the server may have moved.
                // Re-resolve from the current browse results.
                handleResults(results)
            }
        }
    }

    private func markDisconnected() {
        needsProgramReplay = true
        etag = nil // Prefer a full 200; cached replay still covers 304 races.
        state = .disconnected
    }
}
