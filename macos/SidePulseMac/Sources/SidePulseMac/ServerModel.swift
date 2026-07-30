// ServerModel.swift — observable state for the menu bar: the file watcher, the
// HTTP server, and the counters the UI shows.

import Foundation
import Combine
import AppKit

@MainActor
final class ServerModel: ObservableObject {
    @Published private(set) var serverState: LEDHTTPServer.State = .stopped
    @Published private(set) var writesSeen = 0
    @Published private(set) var requestsServed = 0
    @Published private(set) var lastWriteAt: Date?
    @Published private(set) var lastRequestAt: Date?
    /// Raw LEDS.TXT text, republished on every detected change so the preview
    /// reparses exactly when the phone does.
    @Published private(set) var program: String = ""
    @Published private(set) var parseError: String?
    @Published private(set) var fileExists = false

    let filePath = LEDFile.path
    let writeLogPath = LEDFile.writeLogPath

    private var server: LEDHTTPServer?
    private var watchTimer: Timer?
    private var lastSignature: FileSignature?
    /// Read by `/health` on the network queue, so it cannot live on the main actor.
    private let writeCounter = AtomicCounter()

    /// Mirrors the Python server's 0.2 s poll.
    ///
    /// Polling rather than watching a file descriptor is deliberate: the
    /// controllers write atomically (temp file + rename), so the path gets a new
    /// inode on every update and a `DispatchSource` bound to the old descriptor
    /// would go silent after the first write.
    private static let watchInterval: TimeInterval = 0.2

    var isRunning: Bool {
        if case .running = serverState { return true }
        return false
    }

    var computerName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    func start() {
        LEDFile.ensureExists()
        // Baseline first so an existing file at launch isn't counted as a write.
        lastSignature = LEDFile.signature()
        fileExists = lastSignature != nil
        reloadProgram()

        let server = LEDHTTPServer(serviceName: computerName) { [counter = writeCounter] in
            counter.value
        }
        server.onStateChange = { [weak self] state in
            MainActor.assumeIsolated { self?.serverState = state }
        }
        server.onRequest = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.requestsServed += 1
                self.lastRequestAt = Date()
            }
        }
        self.server = server
        server.start()

        let timer = Timer(timeInterval: Self.watchInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchTimer = timer
    }

    func stop() {
        watchTimer?.invalidate()
        watchTimer = nil
        server?.stop()
        server = nil
    }

    func restart() {
        stop()
        start()
    }

    private func poll() {
        let sig = LEDFile.signature()
        fileExists = sig != nil
        guard let sig, sig != lastSignature else { return }
        lastSignature = sig
        writeCounter.increment()
        writesSeen = writeCounter.value
        lastWriteAt = Date()
        LEDFile.appendWriteLog(sig)
        reloadProgram()
    }

    private func reloadProgram() {
        guard let data = LEDFile.read(), let text = String(data: data, encoding: .utf8) else {
            program = ""
            parseError = nil
            return
        }
        program = text
        // Report the same parse failure the phone would hit, so a bad program is
        // diagnosable from the Mac without picking the phone up.
        do {
            _ = try LEDSParser.parse(text, ledCount: 8)
            parseError = nil
        } catch let error as LEDSParseError {
            parseError = error.description
        } catch {
            parseError = "\(error)"
        }
    }

    // MARK: - Menu actions

    func revealFileInFinder() {
        NSWorkspace.shared.selectFile(filePath, inFileViewerRootedAtPath: LEDFile.directory)
    }

    func openWriteLog() {
        guard FileManager.default.fileExists(atPath: writeLogPath) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: writeLogPath))
    }

    func copyHealthURL() {
        guard case .running(let port, _) = serverState else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("http://localhost:\(port)/health", forType: .string)
    }
}
