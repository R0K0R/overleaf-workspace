#!/usr/bin/env python3
"""Test shim: a loopback bridge that wants credentials like overleaf_bridge.

Forwards emacs-collab messages to bridge-ref/loopback.py --test.  An `open`
without credentials, or whose password/cookie is not the one in
$AUTHBRIDGE_SECRET, is answered with need_auth.  `mirror_dir` becomes `dir`.
Every open it saw is logged (without secrets) to $AUTHBRIDGE_LOG.
"""
import json, os, subprocess, sys, threading

loop = os.path.join(os.environ["EMACS_COLLAB_DIR"], "bridge-ref", "loopback.py")
child = subprocess.Popen([sys.executable, loop, "--test"], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, text=True, bufsize=1)
secret = os.environ.get("AUTHBRIDGE_SECRET", "good")
log = os.environ.get("AUTHBRIDGE_LOG")

def pump():
    for line in child.stdout:
        sys.stdout.write(line); sys.stdout.flush()
    os._exit(0)
threading.Thread(target=pump, daemon=True).start()

for line in sys.stdin:
    m = json.loads(line)
    if m.get("t") == "open":
        c = m.get("credentials") or {}
        got = c.get("password") or c.get("cookie")
        if log:
            with open(log, "a") as f:
                f.write(json.dumps({"method": c.get("method"), "email": c.get("email"),
                                    "cookie_name": c.get("cookie_name"),
                                    "params": m.get("params"), "ok": got == secret}) + "\n")
        if got != secret:
            print(json.dumps({"t": "need_auth", "fields": ["email", "password"],
                              "reason": "bad credentials"}), flush=True)
            continue
        p = m["params"]; p["dir"] = p.get("mirror_dir")
    child.stdin.write(json.dumps(m) + "\n"); child.stdin.flush()
child.stdin.close()
child.wait()
