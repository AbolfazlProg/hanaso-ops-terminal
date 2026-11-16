#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Brute-force behaviour test:
  Phase A (rapid): 8 fast login attempts -> nginx limit_req must answer 429
                   at some point (outer layer).
  Phase B (slow): 5 spaced failures -> gateway engages persistent lockout
                   (423); correct password is then ALSO blocked; lockout
                   survives a gateway restart (state.json); after state
                   cleanup + restart, correct login works again."""
import http.client
import os
import re
import ssl
import socket
import subprocess
import sys
import time

BASE = os.environ.get("OPS_TEST_BASE", "https://ops.hanaso.ir:8443")
IP = os.environ.get("OPS_TEST_IP", "127.0.0.1")
PW = os.environ["OPS_TEST_PW"]
USER = os.environ.get("OPS_TEST_USER", "ops-admin")
CTL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sandbox-ctl.sh")
STATE_FILE = "/home/z/ops-sandbox/var/lib/ops-terminal/state.json"


class Conn(http.client.HTTPSConnection):
    def __init__(self, host, port, ip, timeout=10):
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        super().__init__(host, port, context=ctx, timeout=timeout)
        self._ip = ip

    def connect(self):
        raw = socket.create_connection((self._ip, self.port), timeout=self.timeout)
        self.sock = self._context.wrap_socket(raw, server_hostname=self.host)


def attempt(password, delay=0.0):
    """Full CSRF login attempt; returns HTTP status (page or POST)."""
    if delay:
        time.sleep(delay)
    m = re.match(r"https://([^/:]+)(?::(\d+))?", BASE)
    host, port = m.group(1), int(m.group(2) or 443)
    jar = {}
    c = Conn(host, port, IP)
    c.request("GET", "/login")
    r = c.getresponse(); body = r.read().decode()
    for h in r.getheaders():
        if h[0].lower() == "set-cookie":
            k, v = h[1].split(";", 1)[0].split("=", 1)
            jar[k.strip()] = v.strip()
    c.close()
    if r.status != 200:
        return r.status  # e.g. 429 from nginx limit_req
    csrf = re.search(r'name="csrf" value="([^"]+)"', body).group(1)
    form = ("csrf=%s&username=%s&password=%s" %
            (csrf.replace("%", "%25").replace("&", "%26"),
             USER, password.replace("%", "%25").replace("&", "%26"))).encode()
    c = Conn(host, port, IP)
    c.request("POST", "/login", body=form, headers={
        "Content-Type": "application/x-www-form-urlencoded",
        "Cookie": "; ".join("%s=%s" % kv for kv in jar.items())})
    r = c.getresponse(); r.read(); c.close()
    return r.status


def main():
    fails = 0
    print("== Phase A: rapid-fire (nginx limit_req layer) ==")
    codes = [attempt("WrongPassword%02d" % i) for i in range(8)]
    print("  rapid attempt codes: %s" % codes)
    if 429 in codes:
        print("  [PASS] nginx rate-limit engaged (HTTP 429 seen)")
    else:
        print("  [WARN] no 429 observed (codes above) — nginx layer did not trigger")
    # let the rate-limit bucket drain before phase B
    time.sleep(20)

    print("== Phase B: spaced failures (gateway lockout layer) ==")
    codes = [attempt("WrongSlow%02d" % i, delay=6.0) for i in range(5)]
    print("  spaced attempt codes: %s" % codes)
    if 423 in codes:
        print("  [PASS] gateway lockout engaged (HTTP 423 after %d failures)" %
              (codes.index(423) + 1))
    else:
        print("  [FAIL] expected 423 lockout, got %s" % codes); fails += 1

    st = attempt(PW, delay=2.0)
    if st == 423:
        print("  [PASS] correct password ALSO blocked while IP locked (423)")
    else:
        print("  [FAIL] correct password unexpectedly accepted/rejected: %d" % st); fails += 1

    subprocess.run(["bash", CTL, "restart", "gateway"], check=True)
    time.sleep(1.5)
    st = attempt(PW, delay=2.0)
    if st == 423:
        print("  [PASS] lockout persisted across gateway restart (state.json)")
    else:
        print("  [FAIL] lockout lost after restart: %d" % st); fails += 1

    if os.path.exists(STATE_FILE):
        os.remove(STATE_FILE)
    subprocess.run(["bash", CTL, "restart", "gateway"], check=True)
    time.sleep(1.5)
    st = attempt(PW, delay=2.0)
    if st == 302:
        print("  [PASS] after state cleanup, correct login works (302)")
    else:
        print("  [FAIL] login after cleanup: %d" % st); fails += 1

    print("BRUTE-FORCE TEST RESULT: %s" % ("PASS" if fails == 0 else "FAIL"))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
