// LEDFile.swift — the LEDS.TXT file on disk: path resolution, signature,
// ETag, default program and the write log.
//
// Every value here is byte-compatible with server/sidepulse-server.py so the
// two servers are interchangeable: an ETag minted by one is accepted by the
// other, and both append to the same write-log.csv schema.

import Foundation
import CryptoKit

/// Identity of the file at a point in time. Matches the Python server's
/// `(st_mtime_ns, st_size)` tuple — content is never hashed, so a rewrite with
/// identical bytes but a new mtime still counts as a write.
struct FileSignature: Equatable {
    var mtimeNanos: UInt64
    var size: UInt64

    /// `"<first 16 hex of md5("<mtime_ns>-<size>")>"`, quoted, exactly as the
    /// Python server computes it.
    var etag: String {
        let seed = "\(mtimeNanos)-\(size)"
        let digest = Insecure.MD5.hash(data: Data(seed.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\"\(hex.prefix(16))\""
    }
}

enum LEDFile {
    /// Written on first run so a fresh install shows something instead of a 404.
    static let defaultProgram = """
    ; breathing
    #404040 1.4s pulse
    off 400ms none
    repeat

    """

    /// `$SIDEPULSE_FILE`, else `~/sidepulse/LEDS.TXT`. The controllers, the CLI
    /// and both servers honour the same variable, which is the single switch
    /// that points everything at real hardware.
    static let path: String = {
        let raw = ProcessInfo.processInfo.environment["SIDEPULSE_FILE"] ?? "~/sidepulse/LEDS.TXT"
        return (raw as NSString).expandingTildeInPath
    }()

    static var directory: String { (path as NSString).deletingLastPathComponent }

    static var writeLogPath: String {
        (directory as NSString).appendingPathComponent("write-log.csv")
    }

    static func signature() -> FileSignature? {
        // One `stat` supplies both nanosecond modification time and size. The
        // previous `attributesOfItem` call duplicated this filesystem lookup
        // on every watcher poll and its Date value was not precise enough to
        // use anyway.
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        let nanos = UInt64(st.st_mtimespec.tv_sec) * 1_000_000_000 + UInt64(st.st_mtimespec.tv_nsec)
        return FileSignature(mtimeNanos: nanos, size: UInt64(st.st_size))
    }

    static func read() -> Data? { FileManager.default.contents(atPath: path) }

    /// Creates the directory and a default program if the file is missing.
    /// Written temp-then-rename so a poll can never observe a half-written file.
    @discardableResult
    static func ensureExists() -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: path) else { return false }
        let tmp = path + ".tmp"
        guard let data = defaultProgram.data(using: .utf8),
              fm.createFile(atPath: tmp, contents: data) else { return false }
        _ = try? fm.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tmp))
        return true
    }

    /// Appends one row per detected change: the dataset that answers whether
    /// agents actually update their status promptly.
    static func appendWriteLog(_ sig: FileSignature) {
        let firstLine = firstLineOfFile()
        let row = [
            isoMicroseconds(Date()),
            String(format: "%.6f", Double(sig.mtimeNanos) / 1e9),
            String(sig.size),
            firstLine,
        ].map(csvEscaped).joined(separator: ",") + "\r\n"

        let header = "timestamp,mtime,bytes,first_line\r\n"
        let fm = FileManager.default
        let isNew = !fm.fileExists(atPath: writeLogPath)
        guard let handle = FileHandle(forWritingAtPath: writeLogPath)
                ?? { fm.createFile(atPath: writeLogPath, contents: nil)
                     return FileHandle(forWritingAtPath: writeLogPath) }() else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        if isNew { try? handle.write(contentsOf: Data(header.utf8)) }
        try? handle.write(contentsOf: Data(row.utf8))
    }

    private static func firstLineOfFile() -> String {
        guard let data = read(), let text = String(data: data, encoding: .utf8) else { return "" }
        return text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
    }

    /// Python's default csv dialect: quote only when necessary, double inner quotes.
    private static func csvEscaped(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// Reproduces Python's `datetime.now(timezone.utc).isoformat()` byte for byte:
/// six fractional digits and a `+00:00` offset rather than `Z`.
///
/// Both servers append to the same write-log.csv, so a single parser has to read
/// rows from either one. `ISO8601DateFormatter` cannot do this — it emits at
/// most three fractional digits.
private func isoMicroseconds(_ date: Date) -> String {
    let base = LEDFile.writeLogDateFormatter.string(from: date)
    let seconds = date.timeIntervalSince1970
    let micros = Int((seconds - floor(seconds)) * 1_000_000).clamped(to: 0...999_999)
    return base + String(format: ".%06d+00:00", micros)
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension LEDFile {
    static let writeLogDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()
}
