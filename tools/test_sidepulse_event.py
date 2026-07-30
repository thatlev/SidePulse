#!/usr/bin/env python3
"""End-to-end tests for sidepulse-event, run against the installed binary
with isolated state (SIDEPULSE_STATE_DIR / SIDEPULSE_FILE overridden)."""
import json
import os
import shutil
import subprocess
import sys
import time

HELPER = os.path.expanduser("~/bin/sidepulse-event")
ROOT = "/tmp/sp-test"
STATE = ROOT + "/state"
LEDS = ROOT + "/leds/LEDS.TXT"

env = dict(os.environ)
env["SIDEPULSE_STATE_DIR"] = STATE
env["SIDEPULSE_FILE"] = LEDS
env.pop("SIDEPULSE_PROVIDER", None)
env.pop("SIDEPULSE_REVERSE", None)

failures = []
checks = [0]


def check(cond, label):
    checks[0] += 1
    if not cond:
        failures.append(label)
        print("FAIL ", label)


def fire(provider, payload, extra_env=None):
    e = dict(env)
    if extra_env:
        e.update(extra_env)
    r = subprocess.run([HELPER, provider], input=json.dumps(payload),
                       capture_output=True, text=True, env=e, timeout=10)
    return r.returncode


def state():
    with open(STATE + "/status.json") as f:
        return json.load(f)


def leds():
    with open(LEDS) as f:
        return f.read()


def reset():
    shutil.rmtree(ROOT, ignore_errors=True)
    os.makedirs(ROOT + "/leds")


def slot_of(key):
    s = state()["sessions"].get(key)
    return None if s is None else s["slot"]


def backdate(key, secs):
    """Age a session by rewinding its `updated` timestamp (simulate a stale
    or dead session without waiting)."""
    st = state()
    st["sessions"][key]["updated"] -= secs
    with open(STATE + "/status.json", "w") as f:
        json.dump(st, f)


def led_color(i):
    # rendered line contains "i:#XXXXXX 300ms ease-out"
    for part in leds().splitlines()[1].split("; "):
        idx, rest = part.split(":", 1)
        if int(idx) == i:
            return rest.split()[0]
    return None


COL = {"idle": "#FAFAFA", "thinking": "#9CB6F6", "complete": "#B5E3BA",
       "needs_input": "#F6E19D", "error": "#F0A2BB", "off": "#000000"}
BRAND = {"claude": "#D97757", "codex": "#10A37F", "kimi": "#8B5CF6",
         "unknown": "#6E6E6E"}

# Slot layout: first LED (0,3,6) = brand, second LED (1,4,7) = status.
BRAND_LED = {0: 0, 1: 3, 2: 6}   # slot -> its brand LED index
STATUS_LED = {0: 1, 1: 4, 2: 7}  # slot -> its status LED index

# --- 1. allocation: three sessions get slots 0,1,2, idle white -------------
reset()
for n, sid in enumerate(["A", "B", "C"]):
    check(fire("claude", {"hook_event_name": "SessionStart",
                          "session_id": sid, "cwd": "/p"}) == 0, f"start {sid} exit 0")
check(slot_of("A") == 0 and slot_of("B") == 1 and slot_of("C") == 2,
      "slots allocated 0,1,2 in arrival order")
for i in (0, 3, 6):
    check(led_color(i) == BRAND["claude"], f"LED {i} claude brand")
for i in (1, 4, 7):
    check(led_color(i) == COL["idle"], f"LED {i} idle white")
for i in (2, 5):
    check(led_color(i) == COL["off"], f"separator {i} off")

# --- 2. transitions (status on second LED, brand unchanged on first) --------
fire("claude", {"hook_event_name": "UserPromptSubmit", "session_id": "A", "cwd": "/p"})
check(led_color(1) == COL["thinking"], "prompt -> thinking")
check(led_color(0) == BRAND["claude"], "brand LED holds through status change")
fire("claude", {"hook_event_name": "PermissionRequest", "session_id": "A", "cwd": "/p"})
check(led_color(1) == COL["needs_input"], "permission -> needs input")
fire("claude", {"hook_event_name": "PostToolUse", "session_id": "A", "cwd": "/p"})
check(led_color(1) == COL["thinking"], "post-tool -> thinking")
fire("claude", {"hook_event_name": "Stop", "session_id": "A", "cwd": "/p"})
check(led_color(1) == COL["complete"], "stop -> complete")
fire("kimi", {"hook_event_name": "StopFailure", "session_id": "B", "cwd": "/p"})
check(led_color(4) == COL["error"], "stopfailure -> error")
check(led_color(3) == BRAND["kimi"], "provider switch shows kimi brand")
fire("kimi", {"hook_event_name": "Interrupt", "session_id": "B", "cwd": "/p"})
check(led_color(4) == COL["idle"], "interrupt -> idle")
fire("claude", {"hook_event_name": "Notification", "session_id": "C", "cwd": "/p"})
check(led_color(7) == COL["needs_input"], "notification -> needs input")
check("repeat" not in leds(), "static render has no repeat line")
check(led_color(0) == BRAND["claude"] and led_color(1) == COL["complete"],
      "slot shows brand + status on its two LEDs")
check(led_color(6) == BRAND["claude"] and led_color(7) == COL["needs_input"],
      "slot 2 brand + status (claude / needs input)")

# --- 3. skip-unchanged -------------------------------------------------------
mtime1 = os.stat(LEDS).st_mtime_ns
time.sleep(0.05)
fire("claude", {"hook_event_name": "Notification", "session_id": "C", "cwd": "/p"})
check(os.stat(LEDS).st_mtime_ns == mtime1, "unchanged render skips the write")

# --- 3b. SessionStart must not reset a working session to idle --------------
# (resume/compact/clear re-fire SessionStart mid-work)
reset()
fire("claude", {"hook_event_name": "SessionStart", "session_id": "W", "cwd": "/p"})
check(led_color(1) == COL["idle"], "fresh session starts idle")
fire("claude", {"hook_event_name": "UserPromptSubmit", "session_id": "W", "cwd": "/p"})
check(led_color(1) == COL["thinking"], "working -> thinking")
fire("claude", {"hook_event_name": "SessionStart", "session_id": "W", "cwd": "/p"})
check(led_color(1) == COL["thinking"], "SessionStart mid-work keeps thinking")
check(slot_of("W") == 0, "session keeps its slot across SessionStart")

# --- 4. eviction: never evict thinking / needs_input -------------------------
reset()
fire("claude", {"hook_event_name": "SessionStart", "session_id": "A", "cwd": "/p"})
time.sleep(0.02)
fire("claude", {"hook_event_name": "UserPromptSubmit", "session_id": "A", "cwd": "/p"})
fire("claude", {"hook_event_name": "Stop", "session_id": "A", "cwd": "/p"})  # complete, oldest
time.sleep(0.02)
fire("kimi", {"hook_event_name": "SessionStart", "session_id": "B", "cwd": "/p"})
fire("kimi", {"hook_event_name": "UserPromptSubmit", "session_id": "B", "cwd": "/p"})  # thinking
time.sleep(0.02)
fire("codex", {"event": "agent-turn-complete", "session_id": "x", "cwd": "/q"})  # complete
fire("claude", {"hook_event_name": "SessionStart", "session_id": "D", "cwd": "/p"})
check(slot_of("A") is None, "LRU releasable session evicted (A)")
check(slot_of("D") == 0, "newcomer takes the evicted slot")
check(slot_of("B") == 1, "thinking session keeps its slot")

# all three protected -> 4th gets nothing
reset()
for sid in ("A", "B", "C"):
    fire("claude", {"hook_event_name": "SessionStart", "session_id": sid, "cwd": "/p"})
    fire("claude", {"hook_event_name": "UserPromptSubmit", "session_id": sid, "cwd": "/p"})
fire("claude", {"hook_event_name": "PermissionRequest", "session_id": "C", "cwd": "/p"})
fire("claude", {"hook_event_name": "SessionStart", "session_id": "E", "cwd": "/p"})
check(len(state()["sessions"]) == 3, "4th session not allocated when all protected")
check(slot_of("E") is None, "E has no slot")

# --- 4f. stale thinking zombie is evicted by a new active session -----------
# (Codex fires no end event, so its 'thinking' would otherwise squat forever)
reset()
for sid in ("A", "B", "C"):
    fire("claude", {"hook_event_name": "UserPromptSubmit", "session_id": sid, "cwd": "/p"})
check(all(slot_of(s) is not None for s in "ABC"), "three active sessions fill slots")
# fresh: a 4th active session is refused (all three genuinely working)
fire("claude", {"hook_event_name": "UserPromptSubmit", "session_id": "D", "cwd": "/p"})
check(slot_of("D") is None, "recent thinking sessions are NOT bumped")
# age B past the stale threshold -> it becomes evictable
backdate("B", 300)
fire("claude", {"hook_event_name": "UserPromptSubmit", "session_id": "E", "cwd": "/p"})
check(slot_of("B") is None, "stale thinking zombie evicted")
check(slot_of("E") == 1, "new active session takes the zombie's slot")

# --- 4g. long-dead session is pruned entirely -------------------------------
reset()
fire("claude", {"hook_event_name": "UserPromptSubmit", "session_id": "A", "cwd": "/p"})
fire("claude", {"hook_event_name": "UserPromptSubmit", "session_id": "B", "cwd": "/p"})
backdate("A", 4000)  # > DEAD_SECS
fire("claude", {"hook_event_name": "PostToolUse", "session_id": "B", "cwd": "/p"})
check("A" not in state()["sessions"], "long-dead session pruned")
check(slot_of("B") is not None, "live session survives the prune")

# --- 4h. stale active status renders faded (not full brightness) ------------
reset()
fire("claude", {"hook_event_name": "UserPromptSubmit", "session_id": "A", "cwd": "/p"})
fire("claude", {"hook_event_name": "UserPromptSubmit", "session_id": "B", "cwd": "/p"})
check(led_color(1) == COL["thinking"], "fresh thinking is full-brightness blue")
backdate("A", 300)
fire("claude", {"hook_event_name": "PostToolUse", "session_id": "B", "cwd": "/p"})  # re-render
check(led_color(0) == BRAND["claude"], "stale slot keeps full-brightness brand")
faded = led_color(1)
check(faded != COL["thinking"], "stale thinking status is not full blue")
check(int(faded[1:], 16) < int(COL["thinking"][1:], 16), "stale status is dimmer")
check(led_color(4) == COL["thinking"], "live neighbour stays full blue")

# --- 5. session end releases the slot ---------------------------------------
fire("claude", {"hook_event_name": "SessionEnd", "session_id": "A", "cwd": "/p"})
check(slot_of("A") is None, "session end removes the session")
check(led_color(0) == COL["off"] and led_color(1) == COL["off"],
      "released slot LEDs off")
fire("claude", {"hook_event_name": "SessionStart", "session_id": "F", "cwd": "/p"})
check(slot_of("F") == 0, "freed slot reused")

# --- 6. codex: notify + manual events merge into one slot --------------------
reset()
fire("codex", {"event": "agent-turn-complete", "session_id": "abc", "cwd": os.getcwd()})
r = subprocess.run([HELPER, "codex"],
                   input='{"hook_event_name": "UserPromptSubmit"}',
                   capture_output=True, text=True, env=env, cwd=os.getcwd(), timeout=10)
check(len(state()["sessions"]) == 1, "codex notify + manual share one session")
check(led_color(1) == COL["thinking"], "codex manual prompt -> thinking")
check(led_color(0) == BRAND["codex"], "codex brand on first slot LED")

# --- 7. robustness ------------------------------------------------------------
r = subprocess.run([HELPER, "claude"], input="not json {{{",
                   capture_output=True, text=True, env=env, timeout=10)
check(r.returncode == 0, "garbage stdin exits 0")
r = subprocess.run([HELPER, "claude"], input='{"hook_event_name": "Mystery"}',
                   capture_output=True, text=True, env=env, timeout=10)
check(r.returncode == 0, "unknown event exits 0")

# disconnected: missing LEDS dir -> exit 0, no dir created, write retried later
reset()
gone = ROOT + "/nowhere/LEDS.TXT"
e2 = dict(env, SIDEPULSE_FILE=gone)
r = subprocess.run([HELPER, "claude"], input='{"hook_event_name":"SessionStart","session_id":"A","cwd":"/p"}',
                   capture_output=True, text=True, env=e2, timeout=10)
check(r.returncode == 0, "disconnected exits 0")
check(not os.path.exists(ROOT + "/nowhere"), "no directory created when disconnected")
os.makedirs(ROOT + "/nowhere")  # strip "reconnects"
subprocess.run([HELPER, "claude"], input='{"hook_event_name":"UserPromptSubmit","session_id":"A","cwd":"/p"}',
               capture_output=True, text=True, env=e2, timeout=10)
check(os.path.exists(gone), "write retried on next event after reconnect")

# A claimed single-agent project is authoritative even when an old provider
# hook still invokes sidepulse-event. The event is routed through the sibling
# sidepulse-solo helper, preventing a sparse multi-agent render from replacing
# the whole-strip animation.
reset()
os.makedirs(STATE, exist_ok=True)
with open(STATE + "/solo-owner", "w") as f:
    f.write("/p\n")
check(fire("codex", {"hook_event_name": "UserPromptSubmit", "cwd": "/p"}) == 0,
      "claimed solo project accepts event through stale multi hook")
check(leds().startswith("; working\n"),
      "stale multi hook routes to whole-strip solo working program")
check("repeat\n" in leds() and "s0=" not in leds(),
      "routed solo program contains snake animation, not slot render")
with open(os.path.join(os.path.dirname(__file__), "..", "fixtures",
                       "solo-working.txt")) as f:
    expected_solo_working = f.read()
check(leds() == expected_solo_working,
      "controller output exactly matches the Swift-tested solo snake fixture")

# --- 8. concurrency ------------------------------------------------------------
reset()
procs = []
for n in range(20):
    p = subprocess.Popen([HELPER, "claude"],
                         stdin=subprocess.PIPE, env=env,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    p.stdin.write(json.dumps({"hook_event_name": "SessionStart",
                              "session_id": "S%d" % n, "cwd": "/p"}).encode())
    p.stdin.close()
    procs.append(p)
for p in procs:
    check(p.wait(timeout=15) == 0, "parallel event exit 0")
try:
    st = state()
    check(len(st["sessions"]) <= 3, "state valid under concurrency (<=3 slots)")
except ValueError:
    check(False, "status file corrupted")
with open(LEDS) as f:
    lines = f.read().splitlines()
check(len(lines) == 2 and lines[1].count(";") == 7, "rendered file well-formed")

# --- 9. --claim: pin a session to a chosen slot, swapping the occupant -------
reset()
dirs = {k: os.path.join(ROOT, k) for k in ("a", "b", "c")}
for d in dirs.values():
    os.makedirs(d)


def claim(n, cwd, session=None):
    args = [HELPER, "--claim", str(n)]
    if session:
        args += ["--session", session]
    r = subprocess.run(args, capture_output=True, text=True, env=env,
                       cwd=cwd, timeout=10)
    return r.returncode


# three sessions, one per dir -> slots 0,1,2 in start order
for key, d in dirs.items():
    fire("claude", {"hook_event_name": "SessionStart", "session_id": key,
                    "cwd": d})
check(slot_of("a") == 0 and slot_of("b") == 1 and slot_of("c") == 2,
      "claim: initial allocation 0,1,2")

# session in dir a claims slot 3 (1-based) -> swaps with c (slot 2)
check(claim(3, dirs["a"]) == 0, "claim 3 exits 0")
check(slot_of("a") == 2 and slot_of("c") == 0, "claim: a<->c slots swapped")
check(slot_of("b") == 1, "claim: uninvolved session b unchanged")

# idempotent: claiming the slot it already holds is a no-op success
check(claim(3, dirs["a"]) == 0 and slot_of("a") == 2, "claim: idempotent")

# explicit --session id overrides cwd matching
check(claim(2, ROOT, session="b") == 0 and slot_of("b") == 1,
      "claim: explicit --session honored (b already slot 1)")

# strip render reflects the swap: slot 2 (LED 6-7) now shows a (claude, idle)
check(led_color(6) == BRAND["claude"] and led_color(7) == COL["idle"],
      "claim: swapped slot renders brand + status")

# bad slot number -> non-zero, state untouched
before = state()
check(claim(9, dirs["a"]) == 2, "claim: out-of-range slot exits 2")
check(claim("x", dirs["a"]) == 2, "claim: non-numeric slot exits 2")
check(state() == before, "claim: bad input leaves state unchanged")

# no session in this dir -> exits 1, nothing changes
check(claim(1, os.path.join(ROOT, "leds")) == 1, "claim: unknown cwd exits 1")

print("PASS %d checks" % checks[0] if not failures else
      "FAILED %d/%d" % (len(failures), checks[0]))
sys.exit(1 if failures else 0)
