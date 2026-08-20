// AgentHooks.swift — wiring SidePulse into each coding agent's *global* config
// from the menu bar, instead of by running shell scripts.
//
// What actually drives the lights is lifecycle hooks, not instruction text: the
// agent runs `<helper> <provider>` on every session event and the helper writes
// LEDS.TXT. So "add SidePulse to an agent" means merging hook entries into that
// agent's user-level config, and "undo" means removing exactly those entries.
//
// Three rules keep this safe to run against a config full of unrelated hooks:
//   1. A backup is written before every modification.
//   2. Only exact SidePulse helper commands are removed, so an install is
//      idempotent and an uninstall cannot touch StillOn or another tool.
//   3. Nothing is written if the file cannot be parsed — a malformed config is
//      surfaced as an error rather than overwritten.
// Mutations also share StillOn's process lock and use durable atomic writes.

import Foundation
import Darwin

// MARK: - Paths

/// Every path this file touches is resolved through here rather than through
/// `expandingTildeInPath`, which reads the real account's home even when `HOME`
/// says otherwise — so a test run against a temp directory would silently
/// rewrite the developer's own agent configs. `$SIDEPULSE_AGENT_HOME` redirects
/// the whole set, the same way `$SIDEPULSE_FILE` redirects LEDS.TXT.
enum AgentPaths {
    static var home: String {
        ProcessInfo.processInfo.environment["SIDEPULSE_AGENT_HOME"] ?? NSHomeDirectory()
    }

    /// `resolve("~/.claude/settings.json")` -> an absolute path under `home`.
    static func resolve(_ tildePath: String) -> String {
        guard tildePath.hasPrefix("~/") else { return tildePath }
        return (home as NSString).appendingPathComponent(String(tildePath.dropFirst(2)))
    }

    /// The inverse, for display. Falls back to the plain path when it is not
    /// under the resolved home.
    static func abbreviate(_ path: String) -> String {
        guard path.hasPrefix(home + "/") else { return path }
        return "~/" + String(path.dropFirst(home.count + 1))
    }
}

// MARK: - Controller

/// Which helper the hooks call. Mirrors `install.sh` and `install.sh --multi`.
enum SidePulseController: String, CaseIterable, Identifiable {
    /// The whole strip is one agent. The default, and what most setups want.
    case solo
    /// Three slots, one per concurrent agent.
    case multi

    var id: String { rawValue }

    var binaryName: String {
        switch self {
        case .solo: return "sidepulse-solo"
        case .multi: return "sidepulse-event"
        }
    }

    var label: String {
        switch self {
        case .solo: return "Solo"
        case .multi: return "Multi-agent"
        }
    }

    var path: String { AgentPaths.resolve("~/bin/" + binaryName) }

    var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: path) }
}

// MARK: - Providers

enum AgentProvider: String, CaseIterable, Identifiable {
    case claude
    case codex
    case kimi

    /// The setup surface stays focused on the two agents SidePulse supports as
    /// first-class integrations. Kimi remains readable/removable for existing
    /// installs, but is no longer added by the one-button setup.
    static let primaryCases: [AgentProvider] = [.claude, .codex]

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "ChatGPT"
        case .kimi: return "Kimi CLI"
        }
    }

    var symbol: String {
        switch self {
        case .claude: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .kimi: return "moon.stars"
        }
    }

    /// Where the hooks go. All three are user-level, so wiring one covers every
    /// project on the machine.
    var configPath: String {
        let raw: String
        switch self {
        case .claude: raw = "~/.claude/settings.json"
        case .codex: raw = "~/.codex/hooks.json"
        case .kimi: raw = "~/.kimi-code/config.toml"
        }
        return AgentPaths.resolve(raw)
    }

    var displayPath: String { AgentPaths.abbreviate(configPath) }

    /// The agent's home directory. Its absence is how we tell "this agent is not
    /// installed on this Mac" from "installed but not wired up".
    private var homeDirectory: String {
        (configPath as NSString).deletingLastPathComponent
    }

    var isAvailable: Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: homeDirectory, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    /// The lifecycle events each provider emits that map to a light state.
    /// Sending an event the provider never fires is harmless; sending too few
    /// leaves the light stuck, so each list is the provider's full useful set.
    var events: [String] {
        switch self {
        case .claude:
            return ["SessionStart", "UserPromptSubmit", "PermissionRequest",
                    "PostToolUse", "Stop", "SessionEnd", "Notification"]
        case .codex:
            return ["SessionStart", "UserPromptSubmit", "PermissionRequest",
                    "PostToolUse", "Stop", "SessionEnd"]
        case .kimi:
            return ["SessionStart", "UserPromptSubmit", "PermissionRequest",
                    "PermissionResult", "Stop", "StopFailure", "Interrupt", "SessionEnd"]
        }
    }

    /// One handler entry, in the dialect the provider expects. Claude Code runs
    /// hooks off the critical path when `async` is set, which is what the shell
    /// installer writes; Codex has no async flag and takes a timeout instead.
    func handler(command: String) -> [String: Any] {
        switch self {
        case .claude: return ["type": "command", "command": command, "async": true]
        case .codex:
            return [
                "type": "command",
                "command": command,
                "timeout": 3,
                "statusMessage": "SidePulse",
            ]
        case .kimi:
            return ["type": "command", "command": command, "timeout": 3]
        }
    }

    /// Claude Code's own installer writes an empty matcher; Codex treats an
    /// empty string as a pattern to match rather than "match everything", so
    /// there the key is left out entirely.
    var usesEmptyMatcher: Bool { self == .claude }

    /// Shown under the row when connected, for anything the user must still do
    /// by hand. Only Codex has such a step.
    var caveat: String? {
        switch self {
        case .codex:
            return "ChatGPT: run /hooks once to approve the new hooks."
        case .claude, .kimi:
            return nil
        }
    }
}

// MARK: - Errors

enum AgentHookError: LocalizedError {
    case unreadable(String)
    case malformed(String)
    case unwritable(String)
    case busy
    case unsafeLock

    var errorDescription: String? {
        switch self {
        case .unreadable(let path): return "Could not read \(AgentPaths.abbreviate(path))."
        case .malformed(let path): return "\(AgentPaths.abbreviate(path)) is not valid. Fix it by hand first."
        case .unwritable(let path): return "Could not write \(AgentPaths.abbreviate(path))."
        case .busy: return "StillOn or SidePulse is updating agent hooks. Try again."
        case .unsafeLock: return "The shared agent-hook lock is not safe to use."
        }
    }
}

// MARK: - The engine

enum AgentHooks {
    /// Every entry this app writes contains the helper's name, which contains
    /// this token. Detection and removal both key off it.
    private static let marker = "sidepulse"

    static func isConnected(_ provider: AgentProvider) -> Bool {
        switch provider {
        case .claude, .codex:
            guard let root = try? readJSON(provider.configPath) else { return false }
            return jsonHooksContainOwnedCommand(root, provider: provider)
        case .kimi:
            guard let text = try? readText(provider.configPath) else { return false }
            return tomlSegments(text).contains { $0.isSidePulseHook }
        }
    }

    static func connect(_ provider: AgentProvider, controller: SidePulseController) throws {
        try withSharedHookLock {
            try connectLocked(provider, controller: controller)
        }
    }

    private static func connectLocked(_ provider: AgentProvider, controller: SidePulseController) throws {
        let command = "\"\(controller.path)\" \(provider.rawValue)"
        switch provider {
        case .claude, .codex:
            var root = try readJSON(provider.configPath)
            // Strip first so re-connecting after a controller change replaces the
            // old entries instead of stacking a second copy on every event.
            stripJSONHooks(&root, provider: provider)
            var hooks = (root["hooks"] as? [String: Any]) ?? [:]
            for event in provider.events {
                var groups = (hooks[event] as? [[String: Any]]) ?? []
                var group: [String: Any] = ["hooks": [provider.handler(command: command)]]
                if provider.usesEmptyMatcher { group["matcher"] = "" }
                groups.append(group)
                hooks[event] = groups
            }
            root["hooks"] = hooks
            try backup(provider.configPath, suffix: ".bak-sidepulse")
            try writeJSON(root, to: provider.configPath)

        case .kimi:
            let text = (try? readText(provider.configPath)) ?? ""
            let kept = stripKimiHooks(from: text)
            let blocks = provider.events.enumerated().map { index, event -> String in
                var block = "[[hooks]]\n"
                if index == 0 {
                    // Inside the first table on purpose: a comment above the
                    // header would belong to the previous section and survive
                    // removal, accumulating one stale line per install.
                    block += "# SidePulse status light, managed by the SidePulse menu bar app.\n"
                }
                block += "event = \(tomlString(event))\n"
                block += "command = \(tomlString(command))\n"
                block += "timeout = 3\n"
                return block
            }
            // The existing text is appended to verbatim — normalising its
            // trailing newline here would make a later disconnect unable to
            // restore the file byte-for-byte.
            let separator = kept.isEmpty ? "" : "\n"
            try backup(provider.configPath, suffix: ".bak-sidepulse")
            try writeText(kept + separator + blocks.joined(separator: "\n"), to: provider.configPath)
        }
    }

    static func disconnect(_ provider: AgentProvider) throws {
        try withSharedHookLock {
            try disconnectLocked(provider)
        }
    }

    private static func disconnectLocked(_ provider: AgentProvider) throws {
        switch provider {
        case .claude, .codex:
            guard FileManager.default.fileExists(atPath: provider.configPath) else { return }
            var root = try readJSON(provider.configPath)
            stripJSONHooks(&root, provider: provider)
            try backup(provider.configPath, suffix: ".bak-sidepulse-remove")
            try writeJSON(root, to: provider.configPath)

        case .kimi:
            guard FileManager.default.fileExists(atPath: provider.configPath) else { return }
            let text = try readText(provider.configPath)
            try backup(provider.configPath, suffix: ".bak-sidepulse-remove")
            try writeText(stripKimiHooks(from: text), to: provider.configPath)
        }
    }

    // MARK: JSON providers (Claude, Codex)

    /// `{ "hooks": { "<Event>": [ { "matcher": …, "hooks": [ {command…} ] } ] } }`
    /// — the shape Claude Code and Codex both use for user-level hooks.
    private static func jsonHooksContainOwnedCommand(
        _ root: [String: Any],
        provider: AgentProvider
    ) -> Bool {
        guard let hooks = root["hooks"] as? [String: Any] else { return false }
        for (_, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                let handlers = (group["hooks"] as? [[String: Any]]) ?? []
                if handlers.contains(where: { commandIsOwned($0["command"], provider: provider) }) {
                    return true
                }
            }
        }
        return false
    }

    private static func stripJSONHooks(
        _ root: inout [String: Any],
        provider: AgentProvider
    ) {
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            var keptGroups: [[String: Any]] = []
            for var group in groups {
                let handlers = (group["hooks"] as? [[String: Any]]) ?? []
                let keptHandlers = handlers.filter {
                    !commandIsOwned($0["command"], provider: provider)
                }
                // A group that only ever held our handler goes too, so removing
                // leaves the file exactly as it was before connecting.
                let carriesForeignMetadata = group.keys.contains {
                    $0 != "hooks" && $0 != "matcher"
                }
                if !keptHandlers.isEmpty || carriesForeignMetadata {
                    group["hooks"] = keptHandlers
                    keptGroups.append(group)
                }
            }
            if keptGroups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = keptGroups }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
    }

    private static func commandIsOwned(_ value: Any?, provider: AgentProvider) -> Bool {
        guard let command = value as? String else { return false }
        return SidePulseController.allCases.contains { controller in
            let absolute = controller.path
            let suffix = " \(provider.rawValue)"
            return command == "\"\(absolute)\"\(suffix)"
                || command == "\(absolute)\(suffix)"
                || command == "$HOME/bin/\(controller.binaryName)\(suffix)"
                || command == "~/bin/\(controller.binaryName)\(suffix)"
        }
    }

    private static func readJSON(_ path: String) throws -> [String: Any] {
        let target = resolvedPath(path)
        guard FileManager.default.fileExists(atPath: target) else { return [:] }
        guard let data = FileManager.default.contents(atPath: target) else {
            throw AgentHookError.unreadable(path)
        }
        // An empty file is a legitimate starting point; anything else that fails
        // to parse is the user's config and must not be clobbered.
        if data.isEmpty { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw AgentHookError.malformed(path)
        }
        try validateJSONHooks(root, at: path)
        return root
    }

    private static func validateJSONHooks(_ root: [String: Any], at path: String) throws {
        guard let rawHooks = root["hooks"] else { return }
        guard let hooks = rawHooks as? [String: Any] else {
            throw AgentHookError.malformed(path)
        }
        for value in hooks.values {
            guard let groups = value as? [[String: Any]] else {
                throw AgentHookError.malformed(path)
            }
            for group in groups {
                if let handlers = group["hooks"], !(handlers is [[String: Any]]) {
                    throw AgentHookError.malformed(path)
                }
            }
        }
    }

    private static func writeJSON(_ root: [String: Any], to path: String) throws {
        guard let data = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { throw AgentHookError.unwritable(path) }
        try writeText((String(data: data, encoding: .utf8) ?? "") + "\n", to: path)
    }

    // MARK: TOML provider (Kimi)

    /// One top-level TOML section: its header line plus every line up to the
    /// next header. Kimi's hooks are a flat array of tables, so removal is
    /// "drop each `[[hooks]]` section whose body mentions sidepulse" — which
    /// also cleans up blocks added by hand from the README.
    private struct TOMLSegment {
        var header: String?
        var lines: [String]

        var text: String { lines.joined(separator: "\n") }

        var isSidePulseHook: Bool {
            header == "[[hooks]]" && text.lowercased().contains(marker)
        }
    }

    private static func tomlSegments(_ text: String) -> [TOMLSegment] {
        var segments: [TOMLSegment] = []
        var current = TOMLSegment(header: nil, lines: [])
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                segments.append(current)
                current = TOMLSegment(header: trimmed, lines: [line])
            } else {
                current.lines.append(line)
            }
        }
        segments.append(current)
        return segments
    }

    private static func stripKimiHooks(from text: String) -> String {
        let kept = tomlSegments(text).filter { !$0.isSidePulseHook }
        // Collapse the run of blank lines a removed section leaves behind so
        // repeated connect/disconnect cycles do not grow the file.
        var result = kept.map(\.text).joined(separator: "\n")
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result
    }

    /// A TOML basic string. Paths never realistically contain these, but the
    /// command is built from a user-visible path, so escaping is not optional.
    private static func tomlString(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: Files

    /// SidePulse and StillOn both edit Claude/ChatGPT's global hook files. The
    /// intentionally shared lock serializes their read-modify-write cycles so
    /// neither app can overwrite a change the other app just made.
    private static func withSharedHookLock<T>(_ body: () throws -> T) throws -> T {
        let directory = "/tmp/com.thatlev.stillon.agent.\(getuid())"
        var info = stat()
        if Darwin.lstat(directory, &info) != 0 {
            guard errno == ENOENT else { throw AgentHookError.unsafeLock }
            let result = Darwin.mkdir(directory, 0o700)
            guard (result == 0 || errno == EEXIST),
                  Darwin.lstat(directory, &info) == 0 else {
                throw AgentHookError.unsafeLock
            }
        }
        guard info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(),
              info.st_mode & 0o777 == 0o700 else {
            throw AgentHookError.unsafeLock
        }

        let path = directory + "/agent-hooks.lock"
        let descriptor = Darwin.open(
            path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw AgentHookError.unsafeLock }
        defer { Darwin.close(descriptor) }
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              Darwin.fchmod(descriptor, 0o600) == 0 else {
            throw AgentHookError.unsafeLock
        }

        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLK, &lock) != -1 else {
            throw AgentHookError.busy
        }
        defer {
            lock.l_type = Int16(F_UNLCK)
            _ = Darwin.fcntl(descriptor, F_SETLK, &lock)
        }
        return try body()
    }

    private static func readText(_ path: String) throws -> String {
        let target = resolvedPath(path)
        guard FileManager.default.fileExists(atPath: target) else { return "" }
        guard let data = FileManager.default.contents(atPath: target),
              let text = String(data: data, encoding: .utf8) else {
            throw AgentHookError.unreadable(path)
        }
        return text
    }

    private static func writeText(_ text: String, to path: String) throws {
        let target = resolvedPath(path)
        let directory = (target as NSString).deletingLastPathComponent
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let existing = try? fm.attributesOfItem(atPath: target)
            let permissions = (existing?[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
            let temporary = (directory as NSString).appendingPathComponent(
                ".\((target as NSString).lastPathComponent).sidepulse.\(UUID().uuidString)"
            )
            defer { try? fm.removeItem(atPath: temporary) }
            guard fm.createFile(
                atPath: temporary,
                contents: Data(text.utf8),
                attributes: [.posixPermissions: permissions]
            ) else {
                throw AgentHookError.unwritable(path)
            }
            let descriptor = Darwin.open(temporary, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw AgentHookError.unwritable(path) }
            let syncResult = Darwin.fsync(descriptor)
            Darwin.close(descriptor)
            guard syncResult == 0, Darwin.rename(temporary, target) == 0 else {
                throw AgentHookError.unwritable(path)
            }
        } catch {
            if error is AgentHookError { throw error }
            throw AgentHookError.unwritable(path)
        }
    }

    private static func backup(_ path: String, suffix: String) throws {
        let fm = FileManager.default
        let source = resolvedPath(path)
        guard fm.fileExists(atPath: source) else { return }
        let destination = source + suffix
        try? fm.removeItem(atPath: destination)
        try? fm.copyItem(atPath: source, toPath: destination)
    }

    /// Atomic replacement must update a dotfile manager's target, not replace
    /// the symlink stored at the conventional config path.
    private static func resolvedPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values?.isSymbolicLink == true ? url.resolvingSymlinksInPath().path : path
    }
}
