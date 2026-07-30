#!/usr/bin/env bash
#
# SidePulse onboarding installer.
#
# One command to go from a fresh clone to a working agent status light:
#   ./install.sh
#
# It is idempotent (safe to re-run) and non-destructive: existing config is
# backed up, and every step can be skipped. Nothing here touches your source
# code — it only installs into ~/bin, ~/sidepulse, and (optionally) your
# LaunchAgents + Claude hooks.
#
# By default it installs SINGLE-AGENT mode (the whole strip = one agent: a green
# snake sweeping left->right while working, solid orange while waiting for
# approval, solid green when done). Pass --multi for the 3-slot multi-agent mode.
#
# Flags:
#   --multi       wire the multi-agent controller (3 slots) instead of solo
#   --yes         non-interactive; accept all defaults (server + Claude hooks on)
#   --no-service  don't install the auto-start LaunchAgent (run the server by hand)
#   --no-hooks    don't wire Claude Code lifecycle hooks
#   --no-path     don't touch your shell rc for ~/bin on PATH
#   -h, --help    show this help
#
set -euo pipefail

# ── Resolve repo dir (works from any cwd) ─────────────────────────────────────
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BIN_DIR="$HOME/bin"
DATA_DIR="$HOME/sidepulse"
PLIST="$HOME/Library/LaunchAgents/com.sidepulse.server.plist"
LABEL="com.sidepulse.server"

ASSUME_YES=0
DO_SERVICE=1
DO_HOOKS=1
DO_PATH=1
HELPER="sidepulse-solo"   # single-agent by default; --multi switches to 3-slot
MODE="single-agent"

for arg in "$@"; do
  case "$arg" in
    --multi)      HELPER="sidepulse-event"; MODE="multi-agent" ;;
    --yes|-y)     ASSUME_YES=1 ;;
    --no-service) DO_SERVICE=0 ;;
    --no-hooks)   DO_HOOKS=0 ;;
    --no-path)    DO_PATH=0 ;;
    -h|--help)
      sed -n '3,23p' "$REPO/install.sh"; exit 0 ;;
    *) echo "unknown flag: $arg (try --help)" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[1;36m▸ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$*"; }

# Prompt yes/no. Returns 0 for yes. Honors --yes (default yes).
ask() {
  local prompt="$1"
  if [ "$ASSUME_YES" = 1 ]; then return 0; fi
  local reply
  printf '  %s [Y/n] ' "$prompt"
  read -r reply || reply=""
  case "$reply" in [nN]*) return 1 ;; *) return 0 ;; esac
}

# ── Preflight ─────────────────────────────────────────────────────────────────
say "SidePulse installer"
if [ "$(uname -s)" != "Darwin" ]; then
  warn "This targets macOS. The CLIs and server may still work, but Bonjour and"
  warn "LaunchAgent steps are macOS-only. Continuing anyway."
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found — install it (e.g. via Xcode Command Line Tools) and re-run." >&2
  exit 1
fi
PYTHON3="$(command -v python3)"
ok "python3: $PYTHON3"

# ── 1. Install the CLIs into ~/bin ────────────────────────────────────────────
say "Installing CLIs to $BIN_DIR  (mode: $MODE)"
mkdir -p "$BIN_DIR"
install -m 0755 "$REPO/cli/sidepulse-solo"  "$BIN_DIR/sidepulse-solo"
install -m 0755 "$REPO/cli/sidepulse-event" "$BIN_DIR/sidepulse-event"
install -m 0755 "$REPO/cli/sidepulse"       "$BIN_DIR/sidepulse"
if [ "$HELPER" = "sidepulse-event" ]; then
  # A solo claim is the mode arbiter. Clear it when explicitly switching to
  # multi-agent mode so sidepulse-event does not route hooks back to solo.
  rm -f "$HOME/Library/Caches/SidePulse/solo-owner"
fi
ok "sidepulse-solo, sidepulse-event, sidepulse"

# ── 2. Ensure ~/bin is on PATH ────────────────────────────────────────────────
if [ "$DO_PATH" = 1 ]; then
  case ":$PATH:" in
    *":$BIN_DIR:"*) ok "$BIN_DIR already on PATH" ;;
    *)
      # Pick the rc for the user's login shell.
      case "${SHELL:-}" in
        */zsh)  RC="$HOME/.zshrc" ;;
        */bash) RC="$HOME/.bash_profile" ;;
        *)      RC="$HOME/.profile" ;;
      esac
      LINE='export PATH="$HOME/bin:$PATH"'
      if [ -f "$RC" ] && grep -qF 'SidePulse: add ~/bin to PATH' "$RC"; then
        ok "PATH entry already present in $RC"
      else
        { printf '\n# SidePulse: add ~/bin to PATH\n%s\n' "$LINE"; } >> "$RC"
        ok "added ~/bin to PATH in $RC (open a new terminal to pick it up)"
      fi
      ;;
  esac
fi

# ── 3. Install the server (a copy outside ~/Documents; TCC needs this) ────────
say "Installing server to $DATA_DIR"
mkdir -p "$DATA_DIR"
install -m 0755 "$REPO/server/sidepulse-server.py" "$DATA_DIR/sidepulse-server.py"
ok "sidepulse-server.py"

# ── 4. Auto-start the server via a LaunchAgent (optional) ─────────────────────
if [ "$DO_SERVICE" = 1 ] && ask "Install the auto-start server LaunchAgent ($LABEL)?"; then
  mkdir -p "$(dirname "$PLIST")"
  cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PYTHON3</string>
    <string>$DATA_DIR/sidepulse-server.py</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$DATA_DIR/server.log</string>
  <key>StandardErrorPath</key><string>$DATA_DIR/server.log</string>
</dict>
</plist>
PLIST_EOF
  # Reload cleanly whether or not it was already loaded.
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  if launchctl bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1; then
    launchctl kickstart -k "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
    ok "server running as $LABEL (auto-starts at login)"
  else
    warn "could not load LaunchAgent; start it by hand:"
    warn "  python3 $DATA_DIR/sidepulse-server.py"
  fi
else
  warn "skipping auto-start service. Run the server by hand when you need it:"
  warn "  python3 $DATA_DIR/sidepulse-server.py"
fi

# ── 5. Wire Claude Code lifecycle hooks (optional) ────────────────────────────
if [ "$DO_HOOKS" = 1 ] && ask "Wire Claude Code lifecycle hooks in $MODE mode (drives the lights automatically)?"; then
  if SIDEPULSE_HELPER="$HELPER" sh "$REPO/agents/install-claude-hooks.sh"; then
    ok "Claude hooks installed -> $HELPER (backup: ~/.claude/settings.json.bak-sidepulse)"
  else
    warn "hook install failed — you can re-run: SIDEPULSE_HELPER=$HELPER ./agents/install-claude-hooks.sh"
  fi
  warn "Kimi & Codex are wired manually — see the README section 'Wire up the agent hooks'."
else
  warn "skipping global hooks. Project-local hooks can still drive an installed controller."
fi

# ── 6. Smoke test ─────────────────────────────────────────────────────────────
say "Smoke test"
if [ "$HELPER" = "sidepulse-solo" ]; then
  wrote=$("$BIN_DIR/sidepulse-solo" working >/dev/null 2>&1 && echo yes || echo no)
else
  wrote=$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"smoke"}' \
            | "$BIN_DIR/sidepulse-event" claude >/dev/null 2>&1 && echo yes || echo no)
fi
if [ "$wrote" = yes ]; then
  ok "wrote a 'working' program to $DATA_DIR/LEDS.TXT"
else
  warn "could not write LEDS.TXT — check permissions on $DATA_DIR"
fi
if [ "$DO_SERVICE" = 1 ]; then
  # Give launchd a beat, then probe /health.
  for _ in 1 2 3 4 5; do
    if curl -fs http://localhost:8571/health >/dev/null 2>&1; then
      ok "server responding on http://localhost:8571/health"; break
    fi
    sleep 0.4
  done || true
fi

# ── Done ──────────────────────────────────────────────────────────────────────
say "Done."
cat <<NEXT

Next steps:
  1. Build the iPhone app (simulator or device):
       open ios/SidePulseSim/SidePulseSim.xcodeproj
     In Signing & Capabilities, pick YOUR team (the committed team ID is a
     placeholder). Same Wi-Fi as this Mac; allow the Local Network prompt.

  2. Try it:
       sidepulse thinking            # phone pill should switch within ~1s
       sidepulse-event --status      # live session/slot state

  3. Turn it off later:
       ./uninstall.sh                # removes CLIs, server, service, and hooks

Full docs: README.md
NEXT
