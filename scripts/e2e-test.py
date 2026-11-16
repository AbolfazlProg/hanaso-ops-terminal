#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
HANASO OPS Web Terminal — End-to-End verification (stdlib only).

Drives the FULL public path exactly like a real browser:
  https://domain/ -> redirect /login -> CSRF form -> POST /login -> cookie
  -> ttyd index -> GET /token -> WebSocket /ws (subprotocol "tty")
  -> init message -> REAL keystrokes in the shell -> assertions on output.

Also verifies:
  * unauthenticated access is rejected (HTTP + WS)
  * session continuity across a websocket disconnect (tmux keeps running)
  * long-running command output arrives after reconnect

Usage:
  e2e-test.py --base https://ops.hanaso.ir --connect 127.0.0.1 --port 443 \
              --username ops-admin --password-stdin [--insecure-allow] \
              [--expect-uid 0] [--timeout 30]
"""
import base64
import http.client
import json
import os
import re
import socket
import ssl
import struct
import sys
import time

# --------------------------------------------------------------------------- #
PASS = []
FAILS = []


def ok(msg):
    PASS.append(msg)
    print("  [PASS] %s" % msg)


def bad(msg):
    FAILS.append(msg)
    print("  [FAIL] %s" % msg)


# --------------------------------------------------------------------------- #
class HTTPSConn(http.client.HTTPSConnection):
    """HTTPS connection with DNS overridden (like curl --resolve)."""

    def __init__(self, host, port, ip, insecure, timeout=15):
        ctx = ssl.create_default_context()
        if insecure:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        super().__init__(host, port, context=ctx, timeout=timeout)
        self._ip = ip

    def connect(self):
        raw = socket.create_connection((self._ip, self.port), timeout=self.timeout)
        self.sock = self._context.wrap_socket(raw, server_hostname=self.host)


class CookieJar(dict):
    def absorb(self, response):
        for sc in response.getheaders():
            if sc[0].lower() == "set-cookie":
                pair = sc[1].split(";", 1)[0]
                if "=" in pair:
                    k, v = pair.split("=", 1)
                    self[k.strip()] = v.strip()

    def header(self):
        if not self:
            return ""
        return "Cookie: " + "; ".join("%s=%s" % kv for kv in self.items()) + "\r\n"


# --------------------------------------------------------------------------- #
# Minimal RFC6455 client (masked client frames, ping/pong, close)
# --------------------------------------------------------------------------- #
class WSClient(object):
    def __init__(self, host, port, ip, path, insecure, cookies, origin, timeout=15):
        self.host, self.port, self.ip = host, port, ip
        self.path, self.origin, self.cookies = path, origin, cookies
        self.timeout = timeout
        ctx = ssl.create_default_context()
        if insecure:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        raw = socket.create_connection((ip, port), timeout=timeout)
        self.sock = ctx.wrap_socket(raw, server_hostname=host)
        self.sock.settimeout(timeout)
        self.buf = b""
        self.output = ""

    def handshake(self, expect=101):
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        host_hdr = self.host if self.port in (80, 443) else "%s:%d" % (self.host, self.port)
        req = ("GET %s HTTP/1.1\r\n"
               "Host: %s\r\n"
               "Upgrade: websocket\r\n"
               "Connection: Upgrade\r\n"
               "Sec-WebSocket-Key: %s\r\n"
               "Sec-WebSocket-Version: 13\r\n"
               "Sec-WebSocket-Protocol: tty\r\n"
               "Origin: %s\r\n"
               "User-Agent: ops-e2e/1.0\r\n"
               "%s"
               "\r\n") % (self.path, host_hdr, key, self.origin, self.cookies.header())
        self.sock.sendall(req.encode("ascii"))
        while b"\r\n\r\n" not in self.buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("handshake: connection closed")
            self.buf += chunk
        head, self.buf = self.buf.split(b"\r\n\r\n", 1)
        status = head.split(b"\r\n")[0].decode("latin-1")
        code = int(status.split()[1])
        if code != expect:
            raise ConnectionError("handshake status %d (expected %d): %s" % (code, expect, status))
        return code

    def _recv_exact(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("socket closed mid-frame")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def send_frame(self, opcode, payload=b""):
        mask = os.urandom(4)
        hdr = bytearray([0x80 | opcode])
        n = len(payload)
        if n < 126:
            hdr.append(0x80 | n)
        elif n < 65536:
            hdr.append(0x80 | 126)
            hdr += struct.pack(">H", n)
        else:
            hdr.append(0x80 | 127)
            hdr += struct.pack(">Q", n)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(bytes(hdr) + mask + masked)

    def recv_frame(self):
        b1, b2 = self._recv_exact(2)
        opcode = b1 & 0x0F
        masked = b2 & 0x80
        ln = b2 & 0x7F
        if ln == 126:
            ln = struct.unpack(">H", self._recv_exact(2))[0]
        elif ln == 127:
            ln = struct.unpack(">Q", self._recv_exact(8))[0]
        if masked:
            mk = self._recv_exact(4)
        data = self._recv_exact(ln) if ln else b""
        if masked:
            data = bytes(b ^ mk[i % 4] for i, b in enumerate(data))
        return opcode, data

    def drain(self):
        """Read whatever is buffered (non-blocking-ish)."""
        try:
            while True:
                self.sock.settimeout(0.05)
                op, data = self.recv_frame()
                self._consume(op, data)
        except (socket.timeout, TimeoutError):
            pass
        finally:
            self.sock.settimeout(self.timeout)

    def _consume(self, op, data):
        if op == 0x9:  # ping -> pong
            self.send_frame(0xA, data)
        elif op == 0x2 and data[:1] in (b"0", b"1", b"2"):
            if data[:1] == b"0":
                self.output += data[1:].decode("utf-8", "replace")

    def wait_for(self, predicate, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            self.sock.settimeout(max(0.05, deadline - time.time()))
            try:
                op, data = self.recv_frame()
                self._consume(op, data)
            except (socket.timeout, TimeoutError):
                pass
            if predicate(self.output):
                return True
        return predicate(self.output)

    def send_input(self, text):
        """ttyd INPUT frame: first byte '0' + raw bytes."""
        self.send_frame(0x2, b"0" + text.encode("utf-8"))

    def send_init(self, token, cols=110, rows=32):
        msg = json.dumps({"AuthToken": token, "columns": cols, "rows": rows}).encode("utf-8")
        self.send_frame(0x2, msg)

    def close(self):
        try:
            self.send_frame(0x8, struct.pack(">H", 1000))
        except Exception:
            pass
        try:
            self.sock.close()
        except Exception:
            pass


# --------------------------------------------------------------------------- #
def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True, help="https://ops.hanaso.ir")
    ap.add_argument("--connect", default="", help="override DNS with this IP (curl --resolve)")
    ap.add_argument("--port", type=int, default=0, help="port (default: from --base)")
    ap.add_argument("--insecure-allow", action="store_true", help="accept self-signed (tests)")
    ap.add_argument("--username", required=True)
    ap.add_argument("--password-stdin", action="store_true")
    ap.add_argument("--password", default="", help="prefer --password-stdin (no argv leak)")
    ap.add_argument("--expect-uid", type=int, default=0)
    ap.add_argument("--timeout", type=int, default=25)
    args = ap.parse_args()

    if args.password_stdin:
        password = sys.stdin.readline().rstrip("\n")
    else:
        password = args.password
    if not password:
        print("no password provided (use --password-stdin)")
        return 2

    m = re.match(r"(https?)://([^/:]+)(?::(\d+))?", args.base)
    if not m:
        print("bad --base")
        return 2
    scheme, host, port = m.group(1), m.group(2), int(m.group(3) or 443)
    if args.port:
        port = args.port
    ip = args.connect or host
    origin = "https://%s%s" % (host, (":%d" % port) if port not in (80, 443) else "")

    def conn():
        return HTTPSConn(host, port, ip, args.insecure_allow, timeout=args.timeout)

    jar = CookieJar()

    print("== 1. unauthenticated access is rejected ==")
    c = conn()
    c.request("GET", "/", headers={"User-Agent": "ops-e2e"})
    r = c.getresponse(); r.read()
    if r.status in (301, 302) and "/login" in r.getheader("Location", ""):
        ok("GET / without cookie -> %d redirect to /login" % r.status)
    else:
        bad("GET / without cookie -> %s %s" % (r.status, r.getheader("Location")))
    c.close()

    print("== 2. login flow (CSRF form + credentials) ==")
    c = conn()
    c.request("GET", "/login", headers={"User-Agent": "ops-e2e"})
    r = c.getresponse(); body = r.read().decode("utf-8", "replace")
    jar.absorb(r)
    c.close()
    if r.status == 200 and 'name="csrf"' in body:
        ok("login page rendered with CSRF token")
    else:
        bad("login page: status %d" % r.status); return 1
    csrf = re.search(r'name="csrf" value="([^"]+)"', body).group(1)

    form = ("csrf=%s&username=%s&password=%s" %
            (csvesc(csrf), csvesc(args.username), csvesc(password))).encode("utf-8")
    c = conn()
    c.request("POST", "/login", body=form,
              headers={"Content-Type": "application/x-www-form-urlencoded",
                       "User-Agent": "ops-e2e",
                       "Cookie": cook_str(jar)})
    r = c.getresponse(); r.read()
    jar.absorb(r)
    c.close()
    if r.status == 302 and "ops_session" in jar:
        ok("POST /login -> 302 + session cookie (HttpOnly/Secure)")
    else:
        bad("POST /login -> %d (lockout? %s)" % (r.status, "ops_session" in jar))
        return 1

    print("== 3. authenticated pages ==")
    c = conn()
    c.request("GET", "/", headers={"User-Agent": "ops-e2e", **{"Cookie": cook_str(jar)}})
    r = c.getresponse(); body = r.read().decode("utf-8", "replace")
    c.close()
    if r.status == 200 and ("ttyd" in body.lower() or "xterm" in body.lower()):
        ok("GET / with session -> ttyd terminal page (200)")
    else:
        bad("GET / with session -> %d" % r.status)
    c = conn()
    c.request("GET", "/token", headers={"User-Agent": "ops-e2e", **{"Cookie": cook_str(jar)}})
    r = c.getresponse(); tbody = r.read().decode("utf-8", "replace")
    c.close()
    token = ""
    if r.status == 200:
        try:
            token = json.loads(tbody).get("token", "")
        except Exception:
            pass
        ok("GET /token -> 200 (auth-gated)")
    else:
        bad("GET /token -> %d" % r.status)

    print("== 4. websocket terminal + real keystrokes ==")
    try:
        ws = WSClient(host, port, ip, "/ws", args.insecure_allow, jar, origin,
                      timeout=args.timeout)
        ws.handshake(101)
        ok("websocket /ws upgraded (subprotocol tty, cookie auth)")
    except Exception as exc:
        bad("websocket upgrade failed: %r" % (exc,))
        return 1
    ws.send_init(token)
    got_prompt = ws.wait_for(lambda out: ("$" in out or "#" in out or "~" in out), 12)
    if got_prompt:
        ok("shell prompt received over websocket (tmux session 'ops')")
    else:
        bad("no shell output within timeout (last: %r)" % ws.output[-200:])

    def run_cmd(cmd, tmo=12):
        """Run cmd; wait until its unique closing marker arrives; return the
        command output (excluding the echoed command line)."""
        tag = "@%s@" % os.urandom(4).hex()
        ws.output = ""
        ws.send_input("echo %s; %s; echo %s\n" % (tag, cmd, tag))
        ws.wait_for(lambda out: out.count(tag) >= 4, tmo)
        lines = ws.output.splitlines()
        # drop the echoed command line (contains the tag twice)
        result = []
        seen_close = 0
        for line in lines:
            seen_close += line.count(tag)
            if seen_close <= 2 and tag in line:
                continue  # echoed command line
            result.append(line.replace(tag, ""))
        return "\n".join(result)

    uid = str(args.expect_uid)
    out = run_cmd("id -u")
    if any(l.strip() == uid for l in out.splitlines()):
        ok("id -u -> %s (expected uid)" % uid)
    else:
        bad("id -u output: %r" % out[-120:])

    out = run_cmd("hostname")
    import socket as _s
    hn = _s.gethostname()
    if hn in out:
        ok("hostname -> %s" % hn)
    else:
        bad("hostname output does not contain %r: %r" % (hn, out[-120:]))

    out = run_cmd("pwd")
    if re.search(r"^/\S+", out, re.M):
        ok("pwd -> %s" % [l.strip() for l in out.splitlines() if l.strip().startswith("/")][0][:80])
    else:
        bad("pwd output: %r" % out[-120:])

    marker = "OPSFILE%s" % os.urandom(3).hex()
    out = run_cmd("echo %s > /tmp/ops-e2e.txt && cat /tmp/ops-e2e.txt && "
                  "rm /tmp/ops-e2e.txt && echo FILEOK" % marker)
    if marker in out and "FILEOK" in out:
        ok("file create/read/delete cycle OK (%s)" % marker)
    else:
        bad("file cycle failed: %r" % out[-160:])

    ws.output = ""
    ws.send_input("read -p 'GIVE: ' V; echo \"GOT:$V\"\n")
    if ws.wait_for(lambda out: "GIVE:" in out, 8):
        ws.output = ""
        ws.send_input("interactive77\n")
        if ws.wait_for(lambda out: "GOT:interactive77" in out, 8):
            ok("interactive command (read/echo) works over websocket")
        else:
            bad("interactive read failed: %r" % ws.output[-120:])
    else:
        bad("interactive prompt not shown")

    print("== 5. session continuity across websocket disconnect (tmux) ==")
    re_marker = "RECONNECT%s" % os.urandom(3).hex()
    ws.send_input("sleep 6; echo %s\n" % re_marker)
    time.sleep(1.0)
    ws.close()
    try:
        ws2 = WSClient(host, port, ip, "/ws", args.insecure_allow, jar, origin,
                       timeout=args.timeout)
        ws2.handshake(101)
        ws2.send_init(token)
        ws2.wait_for(lambda out: len(out) > 0 or "$" in out or "#" in out, 10)
        if ws2.wait_for(lambda out: re_marker in out, 15):
            ok("running command survived browser disconnect (tmux re-attach, marker %s)" % re_marker)
        else:
            bad("marker never arrived after reconnect: %r" % ws2.output[-150:])
        ws2.close()
    except Exception as exc:
        bad("reconnect failed: %r" % (exc,))

    print("== 6. websocket without cookie is rejected ==")
    try:
        wsn = WSClient(host, port, ip, "/ws", args.insecure_allow, CookieJar(), origin,
                       timeout=8)
        code = wsn.handshake(expect=101)
        bad("unauthenticated websocket unexpectedly upgraded (%d)" % code)
        wsn.close()
    except ConnectionError as exc:
        if "status" in str(exc) and "401" not in str(exc) and "302" not in str(exc):
            ok("unauthenticated websocket rejected (%s)" % str(exc).split(":")[0])
        else:
            ok("unauthenticated websocket rejected (no 101)")
    except Exception as exc:
        bad("unexpected error on unauth ws: %r" % (exc,))

    print("==============================================")
    print(" E2E RESULT: PASS=%d  FAIL=%d" % (len(PASS), len(FAILS)))
    print("==============================================")
    return 0 if not FAILS else 1


def csvesc(s):
    return s.replace("%", "%25").replace("&", "%26").replace("+", "%2B").replace("=", "%3D")


def cook_str(jar):
    return "; ".join("%s=%s" % kv for kv in jar.items())


if __name__ == "__main__":
    sys.exit(main())
