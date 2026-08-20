import Foundation
import Darwin

enum BundledHelpers {
    private static let names = ["sidepulse", "sidepulse-solo", "sidepulse-event"]

    static func install() throws {
        guard let resources = Bundle.main.resourceURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        let sourceDirectory = resources.appendingPathComponent("Helpers", isDirectory: true)
        let destinationDirectory = URL(fileURLWithPath: AgentPaths.home)
            .appendingPathComponent("bin", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        for name in names {
            let source = sourceDirectory.appendingPathComponent(name)
            let destination = destinationDirectory.appendingPathComponent(name)
            guard fm.isExecutableFile(atPath: source.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let temporary = destinationDirectory.appendingPathComponent(
                ".\(name).sidepulse.\(UUID().uuidString)"
            )
            defer { try? fm.removeItem(at: temporary) }
            try fm.copyItem(at: source, to: temporary)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
            guard Darwin.rename(temporary.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }
}
