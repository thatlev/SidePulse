// LEDHTTPServer.swift — the LAN side: an HTTP/1.1 server on :8571 that serves
// LEDS.TXT raw with ETag/304, plus /health, and advertises itself over Bonjour.
//
// Network.framework publishes the Bonjour record itself (NWListener.service), so
// unlike the Python server there is no `dns-sd` subprocess to supervise and no
// way for the advertised port to drift from the listening port.

import Foundation
import Network

/// One request per connection, always closed afterwards.
///
/// The phone polls every 500 ms. Keep-alive would let it reuse a socket the
/// server had already torn down, and that reset surfaces on the phone as a
/// failed poll — eventually the grey "disconnected" screen. Closing every
/// connection cleanly, and saying so with `Connection: close`, removes the
/// entire class of stale-socket races. The Python server does the same.
final class LEDHTTPServer {
    enum State: Equatable {
        case stopped
        case running(port: UInt16, serviceName: String)
        case failed(String)
    }

    private(set) var state: State = .stopped
    /// Called on the main queue whenever `state` changes.
    var onStateChange: ((State) -> Void)?
    /// Called on the main queue after each served request.
    var onRequest: ((_ path: String, _ status: Int) -> Void)?

    private let port: UInt16
    private let serviceName: String
    private let queue = DispatchQueue(label: "sidepulse.http")
    private var listener: NWListener?
    private var writesSeenProvider: () -> Int

    init(port: UInt16 = 8571, serviceName: String, writesSeenProvider: @escaping () -> Int) {
        self.port = port
        self.serviceName = serviceName
        self.writesSeenProvider = writesSeenProvider
    }

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true

        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: params, on: nwPort) else {
            transition(to: .failed("Could not open port \(port)."))
            return
        }
        // Publishing the service on the same NWListener that owns the socket is
        // what keeps the advertised port and the real port identical.
        listener.service = NWListener.Service(name: serviceName, type: "_sidepulse._tcp")

        listener.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.transition(to: .running(port: self.port, serviceName: self.serviceName))
            case .failed(let error):
                self.transition(to: .failed(Self.describe(error, port: self.port)))
                self.stop()
            case .cancelled:
                self.transition(to: .stopped)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        transition(to: .stopped)
    }

    private static func describe(_ error: NWError, port: UInt16) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return "Port \(port) is already in use. The Python sidepulse-server "
                 + "or another copy of this app is running."
        }
        return "\(error)"
    }

    private func transition(to new: State) {
        DispatchQueue.main.async {
            guard self.state != new else { return }
            self.state = new
            self.onStateChange?(new)
        }
    }

    // MARK: - Request handling

    private func serve(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    /// Accumulates until the end of the request head. Bodies are irrelevant: the
    /// only verb served is GET.
    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }

            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
                self.respond(to: head, on: conn)
                return
            }
            if error != nil || isComplete || buffer.count > 64 * 1024 {
                conn.cancel()
                return
            }
            self.receive(conn, buffer: buffer)
        }
    }

    private func respond(to head: String, on conn: NWConnection) {
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
        let requestLine = lines.first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : ""
        let path = parts.count > 1 ? String(parts[1]) : ""

        var ifNoneMatch: String?
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            if pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "if-none-match" {
                ifNoneMatch = pair[1].trimmingCharacters(in: .whitespaces)
            }
        }

        guard method == "GET" else {
            send(status: 405, reason: "Method Not Allowed", on: conn, path: path)
            return
        }
        switch path {
        case "/leds.txt": serveLEDs(ifNoneMatch: ifNoneMatch, on: conn)
        case "/health": serveHealth(on: conn)
        default: send(status: 404, reason: "Not Found", on: conn, path: path)
        }
    }

    private func serveLEDs(ifNoneMatch: String?, on conn: NWConnection) {
        guard let sig = LEDFile.signature() else {
            send(status: 404, reason: "Not Found", on: conn, path: "/leds.txt")
            return
        }
        let etag = sig.etag
        if ifNoneMatch == etag {
            send(status: 304, reason: "Not Modified", on: conn, path: "/leds.txt",
                 headers: ["ETag": etag, "Cache-Control": "no-cache"])
            return
        }
        guard let body = LEDFile.read() else {
            send(status: 404, reason: "Not Found", on: conn, path: "/leds.txt")
            return
        }
        send(status: 200, reason: "OK", on: conn, path: "/leds.txt",
             headers: ["Content-Type": "text/plain; charset=utf-8",
                       "ETag": etag,
                       "Cache-Control": "no-cache"],
             body: body)
    }

    private func serveHealth(on conn: NWConnection) {
        let sig = LEDFile.signature()
        let payload: [String: Any] = [
            "file": LEDFile.path,
            "mtime": sig.map { Double($0.mtimeNanos) / 1e9 } as Any? ?? NSNull(),
            "writes_seen": writesSeenProvider(),
            "server": "SidePulseMac",
        ]
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        send(status: 200, reason: "OK", on: conn, path: "/health",
             headers: ["Content-Type": "application/json"], body: body)
    }

    private func send(status: Int, reason: String, on conn: NWConnection, path: String,
                      headers: [String: String] = [:], body: Data = Data()) {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Connection: close\r\n"
        head += "Content-Length: \(body.count)\r\n"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"

        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
        DispatchQueue.main.async { self.onRequest?(path, status) }
    }
}
