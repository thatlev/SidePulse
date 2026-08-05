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
//   2. Only entries whose command mentions "sidepulse" are ever removed, so an
//      install is idempotent and an uninstall cannot touch anyone else's hooks.
//   3. Nothing is written if the file cannot be parsed — a malformed config is
//      surfaced as an error rather than overwritten.

import Foundation

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

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
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
        case .codex, .kimi: return ["type": "command", "command": command, "timeout": 3]
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
            return "Codex: run /hooks once to approve the new hooks."
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

    var errorDescription: String? {
        switch self {
        case .unreadable(let path): return "Could not read \(AgentPaths.abbreviate(path))."
        case .malformed(let path): return "\(AgentPaths.abbreviate(path)) is not valid — fix it by hand first."
        case .unwritable(let path): return "Could not write \(AgentPaths.abbreviate(path))."
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
            return jsonHooksContainMarker(root)
        case .kimi:
            guard let text = try? readText(provider.configPath) else { return false }
            return tomlSegments(text).contains { $0.isSidePulseHook }
        }
    }

    static func connect(_ provider: AgentProvider, controller: SidePulseController) throws {
        let command = "\"\(controller.path)\" \(provider.rawValue)"
        switch provider {
        case .claude, .codex:
            var root = try readJSON(provider.configPath)
            // Strip first so re-connecting after a controller change replaces the
            // old entries instead of stacking a second copy on every event.
            stripJSONHooks(&root)
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
                    block += "# SidePulse status light — managed by the SidePulse menu bar app.\n"
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
        switch provider {
        case .claude, .codex:
            guard FileManager.default.fileExists(atPath: provider.configPath) else { return }
            var root = try readJSON(provider.configPath)
            stripJSONHooks(&root)
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
    private static func jsonHooksContainMarker(_ root: [String: Any]) -> Bool {
        guard let hooks = root["hooks"] as? [String: Any] else { return false }
        for (_, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                let handlers = (group["hooks"] as? [[String: Any]]) ?? []
                if handlers.contains(where: { commandMatchesMarker($0["command"]) }) { return true }
            }
        }
        return false
    }

    private static func stripJSONHooks(_ root: inout [String: Any]) {
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            var keptGroups: [[String: Any]] = []
            for var group in groups {
                let handlers = (group["hooks"] as? [[String: Any]]) ?? []
                let keptHandlers = handlers.filter { !commandMatchesMarker($0["command"]) }
                // A group that only ever held our handler goes too, so removing
                // leaves the file exactly as it was before connecting.
                if !keptHandlers.isEmpty {
                    group["hooks"] = keptHandlers
                    keptGroups.append(group)
                }
            }
            if keptGroups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = keptGroups }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
    }

    private static func commandMatchesMarker(_ value: Any?) -> Bool {
        guard let command = value as? String else { return false }
        return command.lowercased().contains(marker)
    }

    private static func readJSON(_ path: String) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw AgentHookError.unreadable(path)
        }
        // An empty file is a legitimate starting point; anything else that fails
        // to parse is the user's config and must not be clobbered.
        if data.isEmpty { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw AgentHookError.malformed(path)
        }
        return root
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

    private static func readText(_ path: String) throws -> String {
        guard FileManager.default.fileExists(atPath: path) else { return "" }
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else {
            throw AgentHookError.unreadable(path)
        }
        return text
    }

    private static func writeText(_ text: String, to path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            throw AgentHookError.unwritable(path)
        }
    }

    private static func backup(_ path: String, suffix: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return }
        let destination = path + suffix
        try? fm.removeItem(atPath: destination)
        try? fm.copyItem(atPath: path, toPath: destination)
    }
}
