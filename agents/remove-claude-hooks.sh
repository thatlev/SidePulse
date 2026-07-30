#!/bin/sh
# Remove only SidePulse command hooks from Claude's user settings.
# All unrelated hooks and settings are preserved. A backup is written first.
set -eu

python3 - <<'EOF'
import json
import os
import shutil

path = os.path.expanduser("~/.claude/settings.json")
if not os.path.exists(path):
    print("No Claude settings file; no SidePulse hooks to remove.")
    raise SystemExit(0)

shutil.copy2(path, path + ".bak-sidepulse-remove")
with open(path) as handle:
    config = json.load(handle)

hooks = config.get("hooks", {})
removed = 0
for event, groups in list(hooks.items()):
    kept_groups = []
    for group in groups:
        kept_handlers = []
        for handler in group.get("hooks", []):
            if "sidepulse" in handler.get("command", "").lower():
                removed += 1
            else:
                kept_handlers.append(handler)
        if kept_handlers:
            updated = dict(group)
            updated["hooks"] = kept_handlers
            kept_groups.append(updated)
    if kept_groups:
        hooks[event] = kept_groups
    else:
        hooks.pop(event, None)

with open(path, "w") as handle:
    json.dump(config, handle, indent=2)
    handle.write("\n")

print("Removed %d SidePulse Claude hook(s)." % removed)
EOF
