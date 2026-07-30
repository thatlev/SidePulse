#!/usr/bin/env python3
"""sidepulse-server — serves LEDS.TXT to the SidePulse Sim iPhone app.

Single-file, stdlib only. Watches $SIDEPULSE_FILE (default ~/sidepulse/LEDS.TXT),
serves it raw over HTTP with ETag/304 support, advertises _sidepulse._tcp via
Bonjour (dns-sd subprocess, ships with macOS), and appends a row to
~/sidepulse/write-log.csv on every detected change — the dataset that answers
"do agents actually update status promptly and correctly."

Run:  python3 sidepulse-server.py
"""
import csv
import hashlib
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 8571
LEDS_FILE = os.path.abspath(os.path.expanduser(
    os.environ.get("SIDEPULSE_FILE", "~/sidepulse/LEDS.TXT")))
LOG_FILE = os.path.join(os.path.dirname(LEDS_FILE), "write-log.csv")
WATCH_INTERVAL = 0.2  # seconds

DEFAULT_PROGRAM = """; breathing
#404040 1.4s pulse
off 400ms none
repeat
"""

_state_lock = threading.Lock()
_state = {"writes_seen": 0, "last_sig": None}


def file_sig():
    """(mtime_ns, size) of the LEDS file, or None if missing."""
    try:
        st = os.stat(LEDS_FILE)
        return (st.st_mtime_ns, st.st_size)
    except OSError:
        return None


def etag_for(sig):
    return '"%s"' % hashlib.md5(("%d-%d" % sig).encode()).hexdigest()[:16]


def ensure_file():
    os.makedirs(os.path.dirname(LEDS_FILE), exist_ok=True)
    if not os.path.exists(LEDS_FILE):
        tmp = LEDS_FILE + ".tmp"
        with open(tmp, "w") as f:
            f.write(DEFAULT_PROGRAM)
        os.replace(tmp, LEDS_FILE)
        print(f"created {LEDS_FILE} with default breathing program")


def log_write(sig):
    """Append timestamp, mtime, bytes, first_line to write-log.csv."""
    first_line = ""
    try:
        with open(LEDS_FILE, "r", errors="replace") as f:
            first_line = f.readline().rstrip("\n")
    except OSError:
        pass
    new_log = not os.path.exists(LOG_FILE)
    with open(LOG_FILE, "a", newline="") as f:
        w = csv.writer(f)
        if new_log:
            w.writerow(["timestamp", "mtime", "bytes", "first_line"])
        w.writerow([
            datetime.now(timezone.utc).isoformat(),
            "%.6f" % (sig[0] / 1e9),
            sig[1],
            first_line,
        ])


def watcher():
    while True:
        sig = file_sig()
        with _state_lock:
            changed = sig is not None and sig != _state["last_sig"]
            if changed:
                _state["last_sig"] = sig
                _state["writes_seen"] += 1
        if changed:
            log_write(sig)
        time.sleep(WATCH_INTERVAL)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        # One request per connection. URLSession's 500 ms polling reuses
        # keep-alive sockets; a reset on a stale one surfaces as a client-side
        # failure (and eventually the grey "disconnected" screen). Closing each
        # connection cleanly — and telling the client via Connection: close —
        # avoids the whole class of stale-socket resets.
        self.close_connection = True
        if self.path == "/leds.txt":
            self.serve_leds()
        elif self.path == "/health":
            self.serve_health()
        else:
            self.send_error(404)

    def serve_leds(self):
        sig = file_sig()
        if sig is None:
            self.send_error(404, "LEDS file missing")
            return
        etag = etag_for(sig)
        if self.headers.get("If-None-Match") == etag:
            self.send_response(304)
            self.send_header("Connection", "close")
            self.send_header("ETag", etag)
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        try:
            with open(LEDS_FILE, "rb") as f:
                body = f.read()
        except OSError:
            self.send_error(404, "LEDS file missing")
            return
        self.send_response(200)
        self.send_header("Connection", "close")
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("ETag", etag)
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def serve_health(self):
        sig = file_sig()
        with _state_lock:
            writes = _state["writes_seen"]
        body = json.dumps({
            "file": LEDS_FILE,
            "mtime": sig[0] / 1e9 if sig else None,
            "writes_seen": writes,
        }).encode()
        self.send_response(200)
        self.send_header("Connection", "close")
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass  # quiet; write-log.csv is the record that matters


def bonjour_name():
    try:
        name = subprocess.run(["scutil", "--get", "ComputerName"],
                              capture_output=True, text=True, timeout=5).stdout.strip()
        if name:
            return name
    except OSError:
        pass
    return socket.gethostname().split(".")[0]


def bonjour_loop(stop_event):
    """Keep a dns-sd registration alive; restart it if it dies."""
    name = bonjour_name()
    while not stop_event.is_set():
        proc = subprocess.Popen(
            ["dns-sd", "-R", name, "_sidepulse._tcp", ".", str(PORT)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        while proc.poll() is None:
            if stop_event.wait(1.0):
                proc.terminate()
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    proc.kill()
                return
        time.sleep(2)  # dns-sd died; re-register


def main():
    ensure_file()
    with _state_lock:
        _state["last_sig"] = file_sig()  # baseline; don't count startup as a write

    threading.Thread(target=watcher, daemon=True).start()

    stop_event = threading.Event()
    bonjour_thread = threading.Thread(target=bonjour_loop, args=(stop_event,), daemon=True)
    bonjour_thread.start()

    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)

    def shutdown(signum, frame):
        stop_event.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    print(f"sidepulse-server: serving {LEDS_FILE}")
    print(f"  http://0.0.0.0:{PORT}/leds.txt  (ETag/304)")
    print(f"  http://0.0.0.0:{PORT}/health")
    print(f"  bonjour: {bonjour_name()} via _sidepulse._tcp, write log: {LOG_FILE}")
    try:
        server.serve_forever()
    finally:
        stop_event.set()
        bonjour_thread.join(timeout=5)
        server.server_close()


if __name__ == "__main__":
    main()
