// Test harness for AgentHooks — the code that edits your real agent configs.
// Usage: swift-hooks-tests <sandbox-dir>
//
// The sandbox is built from scratch on every run and $SIDEPULSE_AGENT_HOME must
// point into it. The guard below is not ceremony: `expandingTildeInPath` and
// `NSHomeDirectory()` both ignore $HOME, so a harness that forgets to redirect
// would rewrite the developer's own ~/.claude, ~/.codex and ~/.kimi-code.

import Foundation

var failures = 0
var checks = 0

func check(_ cond: Bool, _ label: String) {
    checks += 1
    if !cond {
        failures += 1
        print("FAIL  \(label)")
    }
}

let sandbox = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/sidepulse-hooks-test"

guard AgentPaths.home == sandbox, sandbox != NSHomeDirectory() else {
    print("""
    REFUSING TO RUN — this test writes agent config files.
      $SIDEPULSE_AGENT_HOME = \(AgentPaths.home)
      sandbox argument       = \(sandbox)
    Run it as:
      SIDEPULSE_AGENT_HOME=\(sandbox) swift-hooks-tests \(sandbox)
    """)
    exit(2)
}

// MARK: - Sandbox

let fm = FileManager.default

/// A config that already contains unrelated hooks, so every test also proves we
/// leave other tools' entries alone.
let claudeOriginal = """
{
  "hooks" : {
    "Stop" : [
      {
        "hooks" : [
          { "command" : "node \\"/opt/other-tool/hook.cjs\\"", "type" : "command" },
          { "command" : "\\"/Applications/StillOn.app/Contents/MacOS/stillon-agent-hook\\" claude", "type" : "command" },
          { "command" : "node \\"/opt/sidepulse-monitor/hook.cjs\\"", "type" : "command" }
        ]
      }
    ]
  },
  "model" : "opus"
}
"""

let codexOriginal = """
{
  "hooks" : {
    "UserPromptSubmit" : [
      {
        "hooks" : [
          { "command" : "node \\"/opt/other-tool/prompt.cjs\\"", "type" : "command" },
          { "command" : "\\"/Applications/StillOn.app/Contents/MacOS/stillon-agent-hook\\" codex", "statusMessage" : "StillOn", "type" : "command" }
        ]
      }
    ]
  }
}
"""

let kimiOriginal = """
default_model = "kimi-code/k3"

[thinking]
enabled = true
effort = "high"

[models."kimi-code/k3"]
provider = "managed:kimi-code"
max_context_size = 1048576

"""

func buildSandbox() {
    try? fm.removeItem(atPath: sandbox)
    for sub in [".claude", ".codex", ".kimi-code", "bin"] {
        try! fm.createDirectory(atPath: (sandbox as NSString).appendingPathComponent(sub),
                                withIntermediateDirectories: true)
    }
    try! claudeOriginal.write(toFile: AgentProvider.claude.configPath, atomically: true, encoding: .utf8)
    try! codexOriginal.write(toFile: AgentProvider.codex.configPath, atomically: true, encoding: .utf8)
    try! kimiOriginal.write(toFile: AgentProvider.kimi.configPath, atomically: true, encoding: .utf8)
    for controller in SidePulseController.allCases {
        try! "#!/bin/sh\n".write(toFile: controller.path, atomically: true, encoding: .utf8)
        try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: controller.path)
    }
}

func read(_ path: String) -> String {
    (try? String(contentsOfFile: path, encoding: .utf8)) ?? "<missing>"
}

func original(for provider: AgentProvider) -> String {
    switch provider {
    case .claude: return claudeOriginal
    case .codex: return codexOriginal
    case .kimi: return kimiOriginal
    }
}

/// JSON is re-serialised on write, so identity has to be compared as a tree.
func sameJSON(_ a: String, _ b: String) -> Bool {
    guard let x = try? JSONSerialization.jsonObject(with: Data(a.utf8)) as? NSDictionary,
          let y = try? JSONSerialization.jsonObject(with: Data(b.utf8)) as? NSDictionary else { return false }
    return x == y
}

func matchesOriginal(_ provider: AgentProvider) -> Bool {
    let now = read(provider.configPath)
    switch provider {
    // TOML is edited as text, so it must come back byte-for-byte.
    case .kimi: return now == original(for: provider)
    case .claude, .codex: return sameJSON(now, original(for: provider))
    }
}

buildSandbox()

// MARK: - Detection

for provider in AgentProvider.allCases {
    check(provider.isAvailable, "\(provider.displayName) is detected as installed")
    check(!AgentHooks.isConnected(provider), "\(provider.displayName) starts disconnected")
}

check(!AgentProvider.claude.displayPath.hasPrefix(sandbox),
      "display path is abbreviated, not absolute")
check(AgentProvider.primaryCases == [.claude, .codex],
      "one-button setup is limited to Claude Code and ChatGPT")

// MARK: - Connect / disconnect round trip

for controller in SidePulseController.allCases {
    for provider in AgentProvider.allCases {
        buildSandbox()

        do { try AgentHooks.connect(provider, controller: controller) }
        catch { failures += 1; print("FAIL  connect \(provider.rawValue): \(error)") }

        check(AgentHooks.isConnected(provider),
              "\(provider.displayName) reports connected [\(controller.label)]")

        let body = read(provider.configPath)
        check(body.components(separatedBy: controller.binaryName).count - 1 == provider.events.count,
              "\(provider.displayName) writes one entry per event [\(controller.label)]")
        check(body.contains("other-tool") || provider == .kimi,
              "\(provider.displayName) preserves the unrelated hook [\(controller.label)]")
        check(body.contains("StillOn") || provider != .codex,
              "\(provider.displayName) preserves StillOn [\(controller.label)]")
        if provider == .claude {
            check(body.contains("/opt/sidepulse-monitor/hook.cjs"),
                  "Claude preserves foreign commands that merely contain sidepulse")
        }
        if provider == .codex {
            check(body.contains("\"statusMessage\" : \"SidePulse\""),
                  "ChatGPT handlers identify SidePulse in hook settings")
        }

        // Connecting twice must replace, not stack.
        do { try AgentHooks.connect(provider, controller: controller) } catch {}
        check(read(provider.configPath).components(separatedBy: controller.binaryName).count - 1
              == provider.events.count,
              "\(provider.displayName) connect is idempotent [\(controller.label)]")

        do { try AgentHooks.disconnect(provider) }
        catch { failures += 1; print("FAIL  disconnect \(provider.rawValue): \(error)") }

        check(!AgentHooks.isConnected(provider),
              "\(provider.displayName) reports disconnected [\(controller.label)]")
        check(matchesOriginal(provider),
              "\(provider.displayName) restores the original config [\(controller.label)]")
    }
}

// MARK: - Switching controller replaces rather than duplicates

buildSandbox()
for provider in AgentProvider.allCases {
    try? AgentHooks.connect(provider, controller: .solo)
    try? AgentHooks.connect(provider, controller: .multi)
    let body = read(provider.configPath)
    check(!body.contains("sidepulse-solo"),
          "\(provider.displayName) drops the old controller when switching")
    check(body.components(separatedBy: "sidepulse-event").count - 1 == provider.events.count,
          "\(provider.displayName) has only the new controller's entries")
    try? AgentHooks.disconnect(provider)
    check(matchesOriginal(provider), "\(provider.displayName) restores after a controller switch")
}

// MARK: - Hand-written blocks are cleaned up too

buildSandbox()
// A config ending in a single newline, which is how a file the user has not
// yet appended to actually looks. Exactly one blank line then separates the
// block they pasted in from the README.
let handBase = kimiOriginal.replacingOccurrences(of: "1048576\n\n", with: "1048576\n")
let handWritten = handBase
    + "\n[[hooks]]\n"
    + "event = \"Stop\"\n"
    + "command = \"$HOME/bin/sidepulse-event kimi\"\n"
try! handWritten.write(toFile: AgentProvider.kimi.configPath, atomically: true, encoding: .utf8)
check(AgentHooks.isConnected(.kimi), "a hand-written Kimi block is detected")
try? AgentHooks.disconnect(.kimi)
check(read(AgentProvider.kimi.configPath) == handBase, "a hand-written Kimi block is removed cleanly")

// MARK: - Disconnecting what was never connected is a no-op

buildSandbox()
for provider in AgentProvider.allCases {
    try? AgentHooks.disconnect(provider)
    check(matchesOriginal(provider), "\(provider.displayName) disconnect is a no-op when not connected")
}

// MARK: - A malformed config is refused, never overwritten

buildSandbox()
let broken = "{ this is not json"
try! broken.write(toFile: AgentProvider.claude.configPath, atomically: true, encoding: .utf8)
do {
    try AgentHooks.connect(.claude, controller: .solo)
    failures += 1
    print("FAIL  malformed config was accepted")
} catch {
    checks += 1
}
check(read(AgentProvider.claude.configPath) == broken, "malformed config is left byte-for-byte intact")

buildSandbox()
let unsupportedHooks = "{ \"hooks\": { \"Stop\": { \"hooks\": [] } } }"
try! unsupportedHooks.write(
    toFile: AgentProvider.claude.configPath,
    atomically: true,
    encoding: .utf8
)
do {
    try AgentHooks.connect(.claude, controller: .solo)
    failures += 1
    print("FAIL  unsupported hook shape was accepted")
} catch {
    checks += 1
}
check(read(AgentProvider.claude.configPath) == unsupportedHooks,
      "unsupported hook shape is left byte-for-byte intact")

// MARK: - Missing files are created rather than failing

buildSandbox()
try! fm.removeItem(atPath: AgentProvider.codex.configPath)
do { try AgentHooks.connect(.codex, controller: .solo) }
catch { failures += 1; print("FAIL  connect with no existing file: \(error)") }
check(AgentHooks.isConnected(.codex), "a missing config file is created on connect")

// MARK: - Backups

buildSandbox()
try? AgentHooks.connect(.claude, controller: .solo)
check(sameJSON(read(AgentProvider.claude.configPath + ".bak-sidepulse"), claudeOriginal),
      "connect backs up the pre-existing config")
try? AgentHooks.disconnect(.claude)
check(fm.fileExists(atPath: AgentProvider.claude.configPath + ".bak-sidepulse-remove"),
      "disconnect writes its own backup")

// MARK: - File safety

buildSandbox()
try! fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AgentProvider.claude.configPath)
try? AgentHooks.connect(.claude, controller: .solo)
let connectedMode = (try? fm.attributesOfItem(
    atPath: AgentProvider.claude.configPath
)[.posixPermissions] as? NSNumber)?.intValue
check(connectedMode == 0o600, "atomic writes preserve config permissions")

buildSandbox()
let claudeTarget = (sandbox as NSString).appendingPathComponent(".claude/settings.real.json")
try! fm.moveItem(atPath: AgentProvider.claude.configPath, toPath: claudeTarget)
try! fm.createSymbolicLink(atPath: AgentProvider.claude.configPath, withDestinationPath: claudeTarget)
try? AgentHooks.connect(.claude, controller: .solo)
let symlinkValues = try? URL(fileURLWithPath: AgentProvider.claude.configPath)
    .resourceValues(forKeys: [.isSymbolicLinkKey])
check(symlinkValues?.isSymbolicLink == true, "atomic writes preserve config symlinks")
try? AgentHooks.disconnect(.claude)
check(sameJSON(read(claudeTarget), claudeOriginal),
      "symlinked config round trip restores the target")

try? fm.removeItem(atPath: sandbox)

print(failures == 0 ? "PASS  \(checks) checks" : "FAILED  \(failures)/\(checks) checks")
exit(failures == 0 ? 0 : 1)
