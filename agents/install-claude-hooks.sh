#!/bin/sh
# Merges the sidepulse session-status hooks into user-level ~/.claude/settings.json.
# Covers Claude Code CLI, the VS Code extension, and the Claude desktop app —
# all share this config. Idempotent: removes any prior sidepulse hook entries,
# then adds the current mapping. Backs up to settings.json.bak-sidepulse first.
#
# Which helper the hooks call is chosen by $SIDEPULSE_HELPER (a basename in
# ~/bin), default "sidepulse-solo" (single-agent). Set it to "sidepulse-event"
# for the multi-agent controller. Every hook pipes the event JSON via stdin:
#   SessionStart · UserPromptSubmit · PermissionRequest · PostToolUse ·
#   Stop · SessionEnd · Notification  ->  <helper> claude
set -eu

SIDEPULSE_HELPER="${SIDEPULSE_HELPER:-sidepulse-solo}"
export SIDEPULSE_HELPER

python3 - <<'EOF'
import json, os, shutil

path = os.path.expanduser("~/.claude/settings.json")
os.makedirs(os.path.dirname(path), exist_ok=True)
if os.path.exists(path):
    shutil.copy2(path, path + ".bak-sidepulse")
    with open(path) as f:
        cfg = json.load(f)
else:
    cfg = {}   # fresh install: create a minimal settings.json

hooks = cfg.setdefault("hooks", {})
helper = os.environ.get("SIDEPULSE_HELPER", "sidepulse-solo")
CMD = os.path.expanduser("~/bin/" + helper)

# Remove every existing sidepulse hook entry (any older mapping / other mode).
for event, groups in hooks.items():
    for g in groups:
        g["hooks"] = [h for h in g.get("hooks", [])
                      if "sidepulse" not in h.get("command", "")]
    hooks[event] = [g for g in groups if g.get("hooks")]

for event in ("SessionStart", "UserPromptSubmit", "PermissionRequest",
              "PostToolUse", "Stop", "SessionEnd", "Notification"):
    hooks.setdefault(event, []).append({
        "matcher": "",
        "hooks": [{"type": "command", "command": f'"{CMD}" claude', "async": True}],
    })

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")

print(f"{helper} hooks installed for: SessionStart, UserPromptSubmit, "
      "PermissionRequest, PostToolUse, Stop, SessionEnd, Notification")
EOF
