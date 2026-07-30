#!/usr/bin/env python3
"""Behavior tests for the directory-scoped ATLD and Side Post controller."""

import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HELPER = os.path.join(ROOT, "cli", "sidepulse-solo")

failures = []
checks = 0


def check(condition, label):
    global checks
    checks += 1
    if not condition:
        failures.append(label)
        print("FAIL ", label)


with tempfile.TemporaryDirectory(prefix="sidepulse-solo-test-") as temp:
    state_dir = os.path.join(temp, "state")
    leds_dir = os.path.join(temp, "leds")
    leds_file = os.path.join(leds_dir, "LEDS.TXT")
    claimed_dir = os.path.join(temp, "claimed")
    other_dir = os.path.join(temp, "other")
    os.makedirs(leds_dir)
    os.makedirs(claimed_dir)
    os.makedirs(other_dir)

    env = dict(os.environ)
    env.update({
        "SIDEPULSE_STATE_DIR": state_dir,
        "SIDEPULSE_FILE": leds_file,
    })
    env.pop("SIDEPULSE_REVERSE", None)

    def run(*args, payload=None, extra_env=None):
        command_env = dict(env)
        if extra_env:
            command_env.update(extra_env)
        return subprocess.run(
            [HELPER, *args],
            input=json.dumps(payload) if payload is not None else None,
            capture_output=True,
            text=True,
            env=command_env,
            timeout=10,
        )

    def leds():
        with open(leds_file) as handle:
            return handle.read()

    claim = run("--claim", claimed_dir, "--device", "sidepost")
    check(claim.returncode == 0, "Side Post claim exits 0")
    check("sidepost owner set to" in claim.stdout, "claim reports Side Post profile")
    with open(os.path.join(state_dir, "solo-owner")) as handle:
        check(handle.read().strip() == os.path.realpath(claimed_dir),
              "claim stores only the selected directory")
    with open(os.path.join(state_dir, "solo-device")) as handle:
        check(handle.read().strip() == "sidepost", "claim stores Side Post profile")
    with open(os.path.join(ROOT, "fixtures", "sidepost-idle.txt")) as handle:
        expected_idle = handle.read()
    check(leds() == expected_idle,
          "Side Post claim starts with the subtle blue idle pulse")

    outside = run("codex", payload={
        "hook_event_name": "UserPromptSubmit",
        "cwd": other_dir,
    })
    check(outside.returncode == 0, "outside-project hook exits safely")
    check(leds() == expected_idle,
          "outside-project hook cannot change the claimed device")

    run("codex", payload={
        "hook_event_name": "UserPromptSubmit",
        "cwd": claimed_dir,
    })
    with open(os.path.join(ROOT, "fixtures", "sidepost-working.txt")) as handle:
        expected_working = handle.read()
    check(leds() == expected_working, "prompt starts exact cyan ping-pong program")

    run("codex", payload={
        "hook_event_name": "PostToolUse",
        "cwd": claimed_dir,
    })
    check(leds() == expected_working,
          "ordinary tool completion remains working before any permission")

    run("codex", payload={
        "hook_event_name": "PermissionRequest",
        "cwd": claimed_dir,
    })
    with open(os.path.join(ROOT, "fixtures", "sidepost-needs-you.txt")) as handle:
        expected_needs_you = handle.read()
    check(leds() == expected_needs_you,
          "permission request holds both dots solid orange")

    run("codex", payload={
        "hook_event_name": "PostToolUse",
        "cwd": claimed_dir,
    })
    with open(os.path.join(ROOT, "fixtures", "sidepost-approved.txt")) as handle:
        expected_approved = handle.read()
    check(leds() == expected_approved,
          "approved tool confirms cyan/orange then resumes purple")

    run("codex", payload={
        "hook_event_name": "Stop",
        "cwd": claimed_dir,
    })
    check(leds() == "; done sidepost\n#30D158 200ms ease-out\n",
          "stop settles both dots green")

    run("codex", payload={
        "hook_event_name": "PermissionRequest",
        "cwd": claimed_dir,
    })
    run("codex", payload={
        "hook_event_name": "PostToolUse",
        "cwd": claimed_dir,
    })
    run("codex", payload={
        "hook_event_name": "StopFailure",
        "cwd": claimed_dir,
    })
    with open(os.path.join(ROOT, "fixtures", "sidepost-error.txt")) as handle:
        expected_error = handle.read()
    check(leds() == expected_error, "failure keeps the red double-blink alert")

    run("codex", payload={
        "hook_event_name": "Stop",
        "cwd": claimed_dir,
    })
    check(leds() == "; done sidepost\n#30D158 200ms ease-out\n",
          "stop settles both dots to solid green")

    run("codex", payload={
        "hook_event_name": "SessionEnd",
        "cwd": claimed_dir,
    })
    check(leds() == "off 200ms none\n", "session end turns the device off")

    run("--device", "atld")
    run("working")
    with open(os.path.join(ROOT, "fixtures", "solo-working.txt")) as handle:
        check(leds() == handle.read(), "switching back preserves exact ATLD snake")

    run("--device", "sidepost")
    run("approved", extra_env={"SIDEPULSE_REVERSE": "1"})
    check(leds().splitlines()[1].startswith("1:#26D8FF"),
          "reverse keeps cyan on physical left")
    run("working", extra_env={"SIDEPULSE_REVERSE": "1"})
    check(leds().splitlines()[2].startswith("1:#26D8FF"),
          "reverse flips the Side Post snake direction")

print("PASS %d checks" % checks if not failures else
      "FAILED %d/%d" % (len(failures), checks))
sys.exit(1 if failures else 0)
