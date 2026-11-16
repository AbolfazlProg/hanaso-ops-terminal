#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Account flows test: /whoami, logout, change-password (incl. session
invalidation after password change). Writes the FINAL password to a file so
subsequent battery tests can use it."""
import http.client
import json
import os
import re
import ssl
import sys
import time

BASE = os.environ.get("OPS_TEST_BASE", "https://ops.hanaso.ir:8443")
IP = os.environ.get("OPS_TEST_IP", "127.0.0.1")
INSECURE = True


class Conn(http.client.HTTPSConnection):
    def __init__(self, host, port, ip, timeout=10):
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        super().__init__(host, port, context=ctx, timeout=timeout)
        self._ip = ip

    def connect(self):
        raw = socket_mod.create_connection((self._ip, self.port), timeout=self.timeout)
        self.sock = self._context.wrap_socket(raw, server_hostname=self.host)


import socket as socket_mod

PASS = []
FAILS = []


def ok(m):
    PASS.append(m); print("  [PASS] " + m)


def bad(m):
    FAILS.append(m); print("  [FAIL] " + m)


def esc(s):
    return s.replace("%", "%25").replace("&", "%26").replace("+", "%2B").replace("=", "%3D")


def login(username, password):
    """Returns (jar dict, ok?) doing the full CSRF flow.
    Retries once if nginx rate-limit (429) kicks in during a test burst."""
    for attempt in (1, 2):
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
        if r.status == 429 and attempt == 1:
            time.sleep(12)  # let the nginx limit_req bucket drain
            continue
        if r.status != 200 or 'name="csrf"' not in body:
            return {}, r.status
        csrf = re.search(r'name="csrf" value="([^"]+)"', body).group(1)
        cookie = "; ".join("%s=%s" % kv for kv in jar.items())
        form = ("csrf=%s&username=%s&password=%s" % (esc(csrf), esc(username), esc(password))).encode()
        c = Conn(host, port, IP)
        c.request("POST", "/login", body=form, headers={
            "Content-Type": "application/x-www-form-urlencoded", "Cookie": cookie})
        r = c.getresponse(); r.read()
        for h in r.getheaders():
            if h[0].lower() == "set-cookie":
                k, v = h[1].split(";", 1)[0].split("=", 1)
                jar[k.strip()] = v.strip()
        c.close()
        if r.status == 429 and attempt == 1:
            time.sleep(12)
            continue
        return jar, r.status
    return {}, 0


def req(method, path, jar=None, body=None, ctype=None):
    m = re.match(r"https://([^/:]+)(?::(\d+))?", BASE)
    host, port = m.group(1), int(m.group(2) or 443)
    headers = {"User-Agent": "ops-account-test"}
    if jar:
        headers["Cookie"] = "; ".join("%s=%s" % kv for kv in jar.items())
    if ctype:
        headers["Content-Type"] = ctype
    c = Conn(host, port, IP)
    c.request(method, path, body=body, headers=headers)
    r = c.getresponse(); data = r.read().decode("utf-8", "replace")
    newcookies = {}
    for h in r.getheaders():
        if h[0].lower() == "set-cookie":
            k, v = h[1].split(";", 1)[0].split("=", 1)
            newcookies[k.strip()] = v.strip()
    c.close()
    return r, data, newcookies


def main():
    username = os.environ.get("OPS_TEST_USER", "ops-admin")
    old_pw = os.environ["OPS_TEST_OLD_PW"]
    new_pw = os.environ.get("OPS_TEST_NEW_PW") or ("Rotated" + os.urandom(4).hex())
    out_pw_file = os.environ["OPS_TEST_PW_FILE"]

    print("== whoami with live session ==")
    jar, st = login(username, old_pw)
    if st == 302 and "ops_session" in jar:
        ok("login OK")
    else:
        bad("login failed: %d" % st); return 1
    r, body, _ = req("GET", "/whoami", jar)
    if r.status == 200 and username in body:
        ok("/whoami -> %s" % body.strip().replace("\n", " "))
    else:
        bad("/whoami: %d %s" % (r.status, body[:80]))

    print("== logout flow ==")
    r, body, fresh = req("GET", "/logout", jar)
    jar.update(fresh)  # absorb the fresh ops_csrf cookie
    if r.status == 200 and 'name="csrf"' in body:
        ok("GET /logout -> confirmation form")
    else:
        bad("GET /logout: %d" % r.status)
    csrf = re.search(r'name="csrf" value="([^"]+)"', body).group(1)
    form = ("csrf=%s" % esc(csrf)).encode()
    r, _, _ = req("POST", "/logout", jar, body=form,
                  ctype="application/x-www-form-urlencoded")
    if r.status == 302 and "/login" in (r.getheader("Location") or ""):
        ok("POST /logout -> 302 /login (cookie cleared)")
    else:
        bad("POST /logout: %d" % r.status)
    r, _, _ = req("GET", "/", jar)
    if r.status in (301, 302):
        ok("panel inaccessible after logout (redirect)")
    else:
        bad("still authorized after logout: %d" % r.status)

    print("== change-password flow ==")
    jar2, st = login(username, old_pw)
    r, body, fresh = req("GET", "/change-password", jar2)
    jar2.update(fresh)  # absorb the fresh ops_csrf cookie
    if r.status == 200 and 'name="csrf"' in body:
        ok("GET /change-password -> form")
        csrf = re.search(r'name="csrf" value="([^"]+)"', body).group(1)
        form = ("csrf=%s&current=%s&new1=%s&new2=%s" %
                (esc(csrf), esc(old_pw), esc(new_pw), esc(new_pw))).encode()
        r, _, _ = req("POST", "/change-password", jar2, body=form,
                      ctype="application/x-www-form-urlencoded")
        if r.status == 302:
            ok("POST /change-password -> 302 (accepted)")
        else:
            bad("change-password rejected: %d" % r.status)
    else:
        bad("GET /change-password: %d" % r.status)
        return 1

    r, _, _ = req("GET", "/", jar2)
    if r.status in (301, 302):
        ok("OLD session invalidated after password change (key version bump)")
    else:
        bad("old session still valid after rotation: %d" % r.status)

    jar3, st = login(username, new_pw)
    if st == 302 and "ops_session" in jar3:
        ok("login with NEW password works")
    else:
        bad("login with new password failed: %d" % st); return 1

    _, st = login(username, old_pw)
    if st in (401, 423):
        ok("login with OLD password rejected (%d)" % st)
    else:
        bad("old password still works: %d" % st)

    with open(out_pw_file, "w") as fh:
        fh.write(new_pw + "\n")
    os.chmod(out_pw_file, 0o600)
    print("==============================================")
    print(" ACCOUNT TEST: PASS=%d FAIL=%d  (new password -> %s)" % (len(PASS), len(FAILS), out_pw_file))
    print("==============================================")
    return 0 if not FAILS else 1


if __name__ == "__main__":
    sys.exit(main())
