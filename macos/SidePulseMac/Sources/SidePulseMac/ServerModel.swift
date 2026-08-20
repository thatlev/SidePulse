// ServerModel.swift — observable state for the menu bar: the file watcher, the
// HTTP server, and the counters the UI shows.

import Foundation
import Combine
import AppKit
import Darwin

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
    private var watchSource: DispatchSourceFileSystemObject?
    private var fallbackTimer: Timer?
    private var lastSignature: FileSignature?
    /// Read by `/health` on the network queue, so it cannot live on the main actor.
    private let writeCounter = AtomicCounter()

    /// A directory source survives the controllers' atomic temp-file rename,
    /// unlike a source attached to the replaced LEDS.TXT inode. A slow fallback
    /// poll covers filesystems that do not deliver directory events reliably.
    private static let fallbackInterval: TimeInterval = 30
    private static let pollingOnlyInterval: TimeInterval = 0.2

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

        let hasDirectoryWatcher = startDirectoryWatcher()
        let interval = hasDirectoryWatcher
            ? Self.fallbackInterval
            : Self.pollingOnlyInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = hasDirectoryWatcher ? 5 : 0.03
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    func stop() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        watchSource?.cancel()
        watchSource = nil
        server?.stop()
        server = nil
    }

    func restart() {
        stop()
        start()
    }

    private func poll() {
        let sig = LEDFile.signature()
        let exists = sig != nil
        if fileExists != exists { fileExists = exists }
        guard let sig else {
            if lastSignature != nil {
                lastSignature = nil
                reloadProgram()
            }
            return
        }
        guard sig != lastSignature else { return }
        lastSignature = sig
        writeCounter.increment()
        writesSeen = writeCounter.value
        lastWriteAt = Date()
        LEDFile.appendWriteLog(sig)
        reloadProgram()
    }

    private func startDirectoryWatcher() -> Bool {
        let descriptor = open(LEDFile.directory, O_EVTONLY)
        guard descriptor >= 0 else { return false }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.poll() }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        watchSource = source
        source.resume()
        return true
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

    /// Fills in the published state a running server would produce, for
    /// `--snapshot`. Deliberately does not start the watcher or bind a port, so
    /// a snapshot run cannot collide with the copy already in the menu bar.
    func seedForSnapshot(program: String,
                         parseError: String?,
                         state: LEDHTTPServer.State,
                         writesSeen: Int,
                         requestsServed: Int) {
        self.program = program
        self.parseError = parseError
        self.serverState = state
        self.writesSeen = writesSeen
        self.requestsServed = requestsServed
        lastWriteAt = Date().addingTimeInterval(-3)
        lastRequestAt = Date().addingTimeInterval(-1)
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
