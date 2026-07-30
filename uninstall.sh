#!/usr/bin/env bash
#
# SidePulse uninstaller — cleanly reverses install.sh.
#
#   ./uninstall.sh            remove CLIs, server, LaunchAgent, and Claude hooks
#   ./uninstall.sh --purge    also delete runtime data (~/sidepulse: LEDS.TXT,
#                             write-log.csv, server.log)
#
# Leaves your source clone untouched. Idempotent.
#
set -euo pipefail

BIN_DIR="$HOME/bin"
DATA_DIR="$HOME/sidepulse"
PLIST="$HOME/Library/LaunchAgents/com.sidepulse.server.plist"
LABEL="com.sidepulse.server"
PURGE=0

for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    -h|--help) sed -n '3,10p' "$0"; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[1;36m▸ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }

# ── 1. Stop & remove the LaunchAgent ─────────────────────────────────────────
say "Removing server LaunchAgent"
launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
rm -f "$PLIST"
ok "stopped and removed $LABEL"

# ── 2. Strip the Claude hooks (any hook whose command mentions sidepulse) ─────
say "Removing Claude hooks"
python3 - <<'EOF' || true
import json, os
path = os.path.expanduser("~/.claude/settings.json")
if os.path.exists(path):
    with open(path) as f:
        cfg = json.load(f)
    hooks = cfg.get("hooks", {})
    for event, groups in list(hooks.items()):
        for g in groups:
            g["hooks"] = [h for h in g.get("hooks", [])
                          if "sidepulse" not in h.get("command", "")]
        hooks[event] = [g for g in groups if g.get("hooks")]
        if not hooks[event]:
            del hooks[event]
    if not hooks:
        cfg.pop("hooks", None)
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2); f.write("\n")
    print("  \033[1;32m✓\033[0m stripped sidepulse hooks from settings.json")
else:
    print("  \033[1;32m✓\033[0m no ~/.claude/settings.json — nothing to strip")
EOF

# ── 3. Remove the CLIs ────────────────────────────────────────────────────────
say "Removing CLIs from $BIN_DIR"
rm -f "$BIN_DIR/sidepulse" "$BIN_DIR/sidepulse-event" "$BIN_DIR/sidepulse-solo"
ok "removed sidepulse, sidepulse-event, sidepulse-solo"

# ── 4. Remove the server copy (and data if --purge) ──────────────────────────
say "Removing server"
rm -f "$DATA_DIR/sidepulse-server.py"
ok "removed sidepulse-server.py"
if [ "$PURGE" = 1 ]; then
  rm -f "$DATA_DIR/LEDS.TXT" "$DATA_DIR/write-log.csv" "$DATA_DIR/server.log"
  rmdir "$DATA_DIR" 2>/dev/null || true
  rm -rf "$HOME/Library/Caches/SidePulse"
  ok "purged runtime data (~/sidepulse, caches)"
else
  ok "kept runtime data in $DATA_DIR (use --purge to delete)"
fi

# ── Note: PATH line & Kimi/Codex hooks ───────────────────────────────────────
say "Done."
cat <<'NOTE'
Left in place (remove by hand if you want):
  - the "# SidePulse: add ~/bin to PATH" line in your shell rc
  - any Kimi (~/.kimi-code/config.toml) or Codex (~/.codex/config.toml) hooks
NOTE
