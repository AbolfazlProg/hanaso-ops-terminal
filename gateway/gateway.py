#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
HANASO OPS Terminal — Auth Gateway
===================================
Independent authentication layer in front of ttyd (root web terminal).

Design goals (see docs/SECURITY.md):
  * Panel account is SEPARATE from any system account.
  * Passwords stored as PBKDF2-HMAC-SHA256 (parameterized iterations), never plaintext.
  * Sessions: HMAC-signed stateless tokens in an HttpOnly+Secure+SameSite=Strict cookie.
  * Brute-force: per-IP failure counting with persistent progressive lockout
    (nginx limit_req adds an outer rate cap; see nginx/ops-terminal.conf.template).
  * Event logging (LOGIN_OK / LOGIN_FAIL / LOCKOUT / LOGOUT / PASSWORD_CHANGED)
    with client IP. Passwords/cookies/terminal content are NEVER logged.
  * Python standard library ONLY (runs on a stock Ubuntu/Debian VPS, no pip).

Listens on 127.0.0.1 only. TLS is terminated by the reverse proxy (nginx).

CLI subcommands:
  gateway.py                 serve (foreground)
  gateway.py passwd          rotate credentials interactively (run as root)
  gateway.py passwd --generate [--print-once] [--username NAME]
  gateway.py passwd --rotate-session-key
  gateway.py verify          prompt for user/password, exit 0 if valid
"""
import base64
import hashlib
import hmac
import json
import os
import secrets
import sys
import threading
import time
from http import cookies as http_cookies
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs
import html as html_mod

VERSION = "1.0.0"
DEFAULT_CONF = "/etc/ops-terminal/env"
MAX_BODY = 16384
SESSION_COOKIE = "ops_session"
CSRF_COOKIE = "ops_csrf"
PW_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz"


# --------------------------------------------------------------------------- #
# Config
# --------------------------------------------------------------------------- #
class Config(object):
    KEYS = {
        "OPS_DOMAIN": "ops.hanaso.ir",
        "GATEWAY_HOST": "127.0.0.1",
        "GATEWAY_PORT": "7682",
        "TTYD_PORT": "7681",
        "SESSION_TTL_HOURS": "8",
        "MAX_LOGIN_FAILURES": "5",
        "LOCKOUT_MINUTES": "15",
        "PBKDF2_ITERATIONS": "200000",
        "PANEL_USERNAME": "ops-admin",
        "CREDENTIALS_FILE": "/etc/ops-terminal/credentials",
        "SESSION_KEY_FILE": "/etc/ops-terminal/session.key",
        "STATE_FILE": "/var/lib/ops-terminal/state.json",
        "LOG_FILE": "/var/log/ops-terminal/gateway.log",
    }

    def __init__(self, path):
        self.path = path
        self.data = dict(self.KEYS)
        if path and os.path.exists(path):
            with open(path, "r", encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    k, v = line.split("=", 1)
                    k = k.strip()
                    if k in self.data:
                        self.data[k] = v.strip()
        for intkey in ("GATEWAY_PORT", "TTYD_PORT", "SESSION_TTL_HOURS",
                       "MAX_LOGIN_FAILURES", "LOCKOUT_MINUTES", "PBKDF2_ITERATIONS"):
            try:
                self.data[intkey] = int(self.data[intkey])
            except ValueError:
                self.data[intkey] = int(self.KEYS[intkey])

    def get(self, key, default=None):
        return self.data.get(key, default)

    @property
    def domain(self):        return self.data["OPS_DOMAIN"]
    @property
    def host(self):          return self.data["GATEWAY_HOST"]
    @property
    def port(self):          return self.data["GATEWAY_PORT"]
    @property
    def ttl_seconds(self):   return int(self.data["SESSION_TTL_HOURS"]) * 3600
    @property
    def max_failures(self):  return int(self.data["MAX_LOGIN_FAILURES"])
    @property
    def lockout_seconds(self): return int(self.data["LOCKOUT_MINUTES"]) * 60
    @property
    def iterations(self):    return int(self.data["PBKDF2_ITERATIONS"])
    @property
    def username(self):      return self.data["PANEL_USERNAME"]
    @property
    def creds_file(self):    return self.data["CREDENTIALS_FILE"]
    @property
    def key_file(self):      return self.data["SESSION_KEY_FILE"]
    @property
    def state_file(self):    return self.data["STATE_FILE"]
    @property
    def log_file(self):      return self.data["LOG_FILE"]


# --------------------------------------------------------------------------- #
# Event logger (events only — never secrets)
# --------------------------------------------------------------------------- #
def log_event(log_file, event, **kv):
    line = " ".join([time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                     event] +
                    ["%s=%s" % (k, str(v)[:120]) for k, v in kv.items() if v is not None])
    try:
        os.makedirs(os.path.dirname(log_file), exist_ok=True)
        with open(log_file, "a", encoding="utf-8", errors="backslashreplace") as fh:
            fh.write(line + "\n")
    except Exception as exc:  # pragma: no cover
        sys.stderr.write("log_event failed: %r\n" % (exc,))


# --------------------------------------------------------------------------- #
# Credentials (PBKDF2)
# --------------------------------------------------------------------------- #
def generate_password(length=24):
    rng = secrets.SystemRandom()
    return "".join(rng.choice(PW_ALPHABET) for _ in range(length))


def hash_password(password, salt, iterations):
    return hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)


def load_credentials(cfg):
    try:
        with open(cfg.creds_file, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return None


def write_credentials(cfg, cred):
    tmp = cfg.creds_file + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(cred, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.chmod(tmp, 0o640)
    os.replace(tmp, cfg.creds_file)


def make_credentials(username, password, iterations):
    salt = secrets.token_bytes(16)
    return {
        "algorithm": "pbkdf2-hmac-sha256",
        "username": username,
        "salt": base64.b64encode(salt).decode("ascii"),
        "hash": base64.b64encode(hash_password(password, salt, iterations)).decode("ascii"),
        "iterations": iterations,
        "version": 1,
        "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }


def verify_password(cfg, username, password):
    cred = load_credentials(cfg)
    if not cred or cred.get("algorithm") != "pbkdf2-hmac-sha256":
        return False
    if username != cred.get("username"):
        return False
    try:
        salt = base64.b64decode(cred["salt"])
        expected = base64.b64decode(cred["hash"])
        iters = int(cred["iterations"])
        actual = hash_password(password, salt, iters)
        return hmac.compare_digest(expected, actual)
    except Exception:
        return False


def load_session_key(cfg):
    with open(cfg.key_file, "rb") as fh:
        return fh.read().strip()


def rotate_session_key(cfg):
    key = secrets.token_hex(32)
    tmp = cfg.key_file + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(key)
    os.chmod(tmp, 0o640)
    os.replace(tmp, cfg.key_file)
    return key


# --------------------------------------------------------------------------- #
# Sessions (HMAC-signed tokens) and CSRF
# --------------------------------------------------------------------------- #
def b64u(data):
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def b64u_dec(data):
    pad = "=" * (-len(data) % 4)
    return base64.urlsafe_b64decode(data + pad)


def make_token(cfg, username, key_version):
    payload = json.dumps({"u": username, "v": key_version,
                          "e": int(time.time()) + cfg.ttl_seconds,
                          "j": secrets.token_hex(6)},
                         separators=(",", ":"), sort_keys=True).encode("utf-8")
    key = load_session_key(cfg)
    sig = hmac.new(key, payload, hashlib.sha256).digest()
    return b64u(payload) + "." + b64u(sig)


def check_token(cfg, token, revoked=None):
    """Returns dict payload or None. `revoked` is an optional dict of
    {jti: expiry_ts} from the persistent state (server-side logout)."""
    if not token or token.count(".") != 1:
        return None
    payload_b64, sig_b64 = token.split(".", 1)
    try:
        payload = b64u_dec(payload_b64)
        sig = b64u_dec(sig_b64)
    except Exception:
        return None
    key = load_session_key(cfg)
    want = hmac.new(key, payload, hashlib.sha256).digest()
    if not hmac.compare_digest(want, sig):
        return None
    try:
        data = json.loads(payload.decode("utf-8"))
    except Exception:
        return None
    cred = load_credentials(cfg)
    key_version = int(cred.get("version", 1)) if cred else 1
    if int(data.get("v", 0)) != key_version:
        return None
    if int(data.get("e", 0)) < time.time():
        return None
    if revoked is not None:
        jti = data.get("j", "")
        if jti and jti in revoked and int(revoked[jti]) > time.time():
            return None
    return data


# --------------------------------------------------------------------------- #
# State: per-IP failure counting + persistent lockout
# --------------------------------------------------------------------------- #
class StateStore(object):
    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()
        self.data = {"fail_counts": {}, "locked_until": {}, "revoked": {}}
        self._load()

    def _load(self):
        try:
            with open(self.path, "r", encoding="utf-8") as fh:
                d = json.load(fh)
            if isinstance(d.get("fail_counts"), dict) and isinstance(d.get("locked_until"), dict):
                self.data = {"fail_counts": d.get("fail_counts", {}),
                             "locked_until": d.get("locked_until", {}),
                             "revoked": d.get("revoked", {}) if isinstance(d.get("revoked"), dict) else {}}
        except Exception:
            pass

    def _save(self):
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(self.data, fh)
        os.replace(tmp, self.path)

    def locked_remaining(self, ip):
        with self.lock:
            until = int(self.data["locked_until"].get(ip, 0))
            if until > time.time():
                return int((until - time.time()) / 60) + 1
            if ip in self.data["locked_until"]:
                del self.data["locked_until"][ip]
                self._save()
            return 0

    def record_failure(self, ip, max_failures, lockout_seconds):
        """Returns True if this failure caused a lockout."""
        with self.lock:
            cnt = int(self.data["fail_counts"].get(ip, 0)) + 1
            self.data["fail_counts"][ip] = cnt
            engaged = False
            if cnt >= max_failures:
                self.data["locked_until"][ip] = time.time() + lockout_seconds
                self.data["fail_counts"][ip] = 0
                engaged = True
            self._prune()
            self._save()
            return engaged

    def reset(self, ip):
        with self.lock:
            self.data["fail_counts"].pop(ip, None)
            self._save()

    def revoke(self, jti, expires_ts):
        """Server-side session revocation (logout). Persisted."""
        with self.lock:
            self.data["revoked"][jti] = int(expires_ts)
            self._prune()
            self._save()

    def revoked_map(self):
        with self.lock:
            return dict(self.data["revoked"])

    def _prune(self):
        now = time.time()
        fc = {}
        for ip, cnt in self.data["fail_counts"].items():
            if cnt > 0:
                fc[ip] = cnt
        lu = {}
        for ip, until in self.data["locked_until"].items():
            if until > now:
                lu[ip] = until
        rv = {}
        for jti, exp in self.data.get("revoked", {}).items():
            if exp > now:
                rv[jti] = exp
        self.data = {"fail_counts": fc, "locked_until": lu, "revoked": rv}


# --------------------------------------------------------------------------- #
# HTML pages (inline, no external assets, no JS)
# --------------------------------------------------------------------------- #
BASE_CSS = """
body{font-family:system-ui,'Segoe UI',Tahoma,sans-serif;background:#101418;color:#e8ecef;
     display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0}
.card{background:#171d24;border:1px solid #2a3340;border-radius:12px;padding:34px 38px;
      width:340px;box-shadow:0 10px 40px rgba(0,0,0,.45)}
h1{font-size:19px;margin:0 0 4px;font-weight:600;color:#7fd1c8}
h2{font-size:13px;margin:0 0 22px;font-weight:400;color:#8a97a3}
label{display:block;font-size:13px;color:#aab6c2;margin:14px 0 6px}
input[type=text],input[type=password]{width:100%;box-sizing:border-box;padding:10px 12px;
     border-radius:8px;border:1px solid #2e3947;background:#0e1318;color:#e8ecef;font-size:14px}
input:focus{outline:1px solid #7fd1c8}
button{margin-top:22px;width:100%;padding:11px 0;border:0;border-radius:8px;background:#1d7a70;
       color:#fff;font-size:15px;cursor:pointer}
button:hover{background:#25948a}
.err{margin:0 0 14px;padding:10px 12px;border-radius:8px;background:#3a1f24;color:#ff9c9c;
     font-size:13px;border:1px solid #5c2a31}
.foot{margin-top:20px;font-size:11px;color:#5c6a76;text-align:center}
"""

PAGE_TMPL = """<!DOCTYPE html>
<html lang="fa" dir="rtl"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>{title}</title><style>{css}</style></head>
<body><div class="card">
<h1>HANASO OPS</h1><h2>{subtitle}</h2>
{body}
<div class="foot">ops terminal gateway · v{version}</div>
</div></body></html>"""

LOGIN_BODY = """{msg}
<form method="post" action="/login" autocomplete="off">
<input type="hidden" name="csrf" value="{csrf}">
<label for="u">نام کاربری پنل</label>
<input id="u" type="text" name="username" autocomplete="username" autofocus required>
<label for="p">رمز عبور پنل</label>
<input id="p" type="password" name="password" autocomplete="current-password" required>
<button type="submit">ورود</button>
</form>"""

LOGOUT_BODY = """{msg}
<form method="post" action="/logout">
<input type="hidden" name="csrf" value="{csrf}">
<p style="font-size:13px;color:#aab6c2">خروج از پنل؛ Session ترمینال (tmux) حفظ می‌شود.</p>
<button type="submit">خروج از پنل</button>
</form>"""

CHPASS_BODY = """{msg}
<form method="post" action="/change-password" autocomplete="off">
<input type="hidden" name="csrf" value="{csrf}">
<label>رمز فعلی</label><input type="password" name="current" required>
<label>رمز جدید (حداقل ۱۲ نویسه)</label><input type="password" name="new1" minlength="12" required>
<label>تکرار رمز جدید</label><input type="password" name="new2" minlength="12" required>
<button type="submit">تغییر رمز</button>
</form>
<p style="font-size:12px;color:#8a97a3">پس از تغییر، همه Session‌ها باطل می‌شوند.</p>"""


# --------------------------------------------------------------------------- #
# HTTP handler
# --------------------------------------------------------------------------- #
class GatewayHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "ops-terminal-gateway/" + VERSION
    sys_version = ""
    cfg = None
    state = None

    # ---- helpers ---------------------------------------------------------- #
    def log_message(self, fmt, *args):  # default per-request logging disabled
        pass

    def client_ip(self):
        xff = self.headers.get("X-Forwarded-For", "")
        if xff:
            return xff.split(",")[0].strip()[:64]
        return self.client_address[0]

    def send_html(self, code, body, extra_headers=None):
        payload = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy",
                         "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'")
        for k, v in (extra_headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    def send_text(self, code, text, ctype="text/plain; charset=utf-8"):
        payload = text.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    def redirect(self, location, set_cookies=None):
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        for c in (set_cookies or []):
            self.send_header("Set-Cookie", c)
        self.end_headers()

    def cookie_val(self, name):
        raw = self.headers.get("Cookie", "")
        try:
            jar = http_cookies.SimpleCookie(raw)
            if name in jar:
                return jar[name].value
        except Exception:
            pass
        return None

    def session(self):
        return check_token(self.cfg, self.cookie_val(SESSION_COOKIE),
                           revoked=self.state.revoked_map() if self.state else None)

    def new_session_cookie(self, username):
        cred = load_credentials(self.cfg) or {}
        token = make_token(self.cfg, username, int(cred.get("version", 1)))
        return "%s=%s; Path=/; Max-Age=%d; HttpOnly; Secure; SameSite=Strict" % (
            SESSION_COOKIE, token, self.cfg.ttl_seconds)

    def clear_session_cookie(self):
        return "%s=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Strict" % SESSION_COOKIE

    def csrf_cookie(self, nonce):
        return "%s=%s; Path=/; Max-Age=1800; HttpOnly; Secure; SameSite=Strict" % (
            CSRF_COOKIE, nonce)

    def render(self, title, subtitle, body, code=200, msg_html="", extra_headers=None):
        page = PAGE_TMPL.format(title=html_mod.escape(title), subtitle=html_mod.escape(subtitle),
                                body=body, css=BASE_CSS, version=VERSION)
        self.send_html(code, page, extra_headers)

    def read_form(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return None
        if length <= 0 or length > MAX_BODY:
            return None
        raw = self.rfile.read(length)
        try:
            fields = parse_qs(raw.decode("utf-8"), keep_blank_values=True)
            return {k: v[0][:256] for k, v in fields.items()}
        except Exception:
            return None

    def csrf_ok(self, form):
        if not form:
            return False
        sent = form.get("csrf", "")
        cookie = self.cookie_val(CSRF_COOKIE) or ""
        return bool(sent) and hmac.compare_digest(sent, cookie)

    # ---- routing ---------------------------------------------------------- #
    def route(self, method):
        try:
            if method == "HEAD":
                method = "GET"  # headers-only variant of GET (curl -I etc.)
            path = self.path.split("?", 1)[0]
            if path == "/health":
                return self.send_text(200, "ok: ops-terminal-gateway %s\n" % VERSION)
            if path == "/auth-check":
                if self.session():
                    return self.send_text(202, "authorized\n")
                return self.send_text(401, "unauthorized\n")
            if path == "/login" and method == "GET":
                return self.handle_login_page()
            if path == "/login" and method == "POST":
                return self.handle_login_post()
            if path == "/logout" and method == "GET":
                return self.handle_logout_page()
            if path == "/logout" and method == "POST":
                return self.handle_logout_post()
            if path == "/change-password" and method == "GET":
                return self.handle_chpass_page()
            if path == "/change-password" and method == "POST":
                return self.handle_chpass_post()
            if path == "/whoami":
                sess = self.session()
                if not sess:
                    return self.send_text(401, "unauthorized\n")
                return self.send_text(200, json.dumps(
                    {"user": sess.get("u"), "expires": sess.get("e")}) + "\n",
                    ctype="application/json")
            if path == "/":
                return self.redirect("/login")
            return self.send_text(404, "not found\n")
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as exc:
            log_event(self.cfg.log_file, "GATEWAY_ERROR", error=repr(exc)[:200])
            try:
                self.send_text(500, "internal error\n")
            except Exception:
                pass

    def do_GET(self):
        self.route("GET")

    def do_HEAD(self):
        self.route("HEAD")

    def do_POST(self):
        self.route("POST")

    # ---- pages ------------------------------------------------------------ #
    def handle_login_page(self):
        if self.session():
            return self.redirect("/")
        nonce = secrets.token_urlsafe(24)
        body = LOGIN_BODY.format(csrf=html_mod.escape(nonce), msg="")
        self.render("ورود — HANASO OPS", "پنل ترمینال مدیریت", body,
                    extra_headers={"Set-Cookie": self.csrf_cookie(nonce)})

    def handle_login_post(self):
        cfg, state = self.cfg, self.state
        ip = self.client_ip()
        # ALWAYS drain the request body first: leaving unread bytes on a
        # keep-alive upstream connection desyncs the next request (nginx
        # upstream keepalive would see the leftovers as a request line).
        form = self.read_form()
        proto = self.headers.get("X-Forwarded-Proto", "")
        if proto and proto != "https":
            return self.send_text(400, "login must go over https\n")

        remaining = state.locked_remaining(ip)
        if remaining > 0:
            log_event(cfg.log_file, "LOGIN_BLOCKED", ip=ip, remaining_min=remaining)
            body = ('<p class="err">تلاش‌های ناموفق زیاد — این IP برای %d دقیقه قفل شده است.</p>' % remaining)
            nonce = secrets.token_urlsafe(24)
            body += LOGIN_BODY.format(csrf=html_mod.escape(nonce), msg="")
            return self.render("قفل موقت — HANASO OPS", "تلاش ناموفق", body, code=423,
                               extra_headers={"Set-Cookie": self.csrf_cookie(nonce)})

        if not self.csrf_ok(form):
            return self.send_text(400, "bad request\n")
        username = form.get("username", "")
        password = form.get("password", "")
        if verify_password(cfg, username, password):
            state.reset(ip)
            log_event(cfg.log_file, "LOGIN_OK", ip=ip, user=username,
                      ua=self.headers.get("User-Agent", "")[:80])
            return self.redirect("/", set_cookies=[self.new_session_cookie(username)])
        engaged = state.record_failure(ip, cfg.max_failures, cfg.lockout_seconds)
        log_event(cfg.log_file, "LOGIN_FAIL", ip=ip, engaged_lockout=engaged,
                  ua=self.headers.get("User-Agent", "")[:80])
        if engaged:
            remaining = state.locked_remaining(ip)
            msg = '<p class="err">تلاش‌های ناموفق زیاد — این IP برای %d دقیقه قفل شد.</p>' % remaining
            code = 423
        else:
            msg = '<p class="err">نام کاربری یا رمز عبور نامعتبر است.</p>'
            code = 401
        nonce = secrets.token_urlsafe(24)
        body = LOGIN_BODY.format(csrf=html_mod.escape(nonce), msg=msg)
        self.render("ورود — HANASO OPS", "پنل ترمینال مدیریت", body, code=code,
                    extra_headers={"Set-Cookie": self.csrf_cookie(nonce)})

    def handle_logout_page(self):
        sess = self.session()
        nonce = secrets.token_urlsafe(24)
        if not sess:
            return self.redirect("/login")
        body = LOGOUT_BODY.format(csrf=html_mod.escape(nonce), msg="")
        self.render("خروج — HANASO OPS", "پایان Session پنل", body,
                    extra_headers={"Set-Cookie": self.csrf_cookie(nonce)})

    def handle_logout_post(self):
        # drain body first (keep-alive safety, see handle_login_post)
        form = self.read_form()
        sess = self.session()
        if not sess:
            return self.redirect("/login", set_cookies=[self.clear_session_cookie()])
        if not self.csrf_ok(form):
            return self.send_text(400, "bad request\n")
        # server-side revocation: the token itself becomes unusable
        self.state.revoke(sess.get("j", ""), int(sess.get("e", 0)))
        log_event(self.cfg.log_file, "LOGOUT", ip=self.client_ip(), user=sess.get("u"),
                  session=sess.get("j"))
        self.redirect("/login", set_cookies=[self.clear_session_cookie()])

    def handle_chpass_page(self):
        sess = self.session()
        if not sess:
            return self.redirect("/login")
        nonce = secrets.token_urlsafe(24)
        body = CHPASS_BODY.format(csrf=html_mod.escape(nonce), msg="")
        self.render("تغییر رمز — HANASO OPS", "چرخش Credential پنل", body,
                    extra_headers={"Set-Cookie": self.csrf_cookie(nonce)})

    def handle_chpass_post(self):
        cfg = self.cfg
        # drain body first (keep-alive safety, see handle_login_post)
        form = self.read_form()
        sess = self.session()
        if not sess:
            return self.redirect("/login")
        if not self.csrf_ok(form):
            return self.send_text(400, "bad request\n")
        current = form.get("current", "")
        new1 = form.get("new1", "")
        new2 = form.get("new2", "")
        err = None
        if not verify_password(cfg, sess.get("u", ""), current):
            err = "رمز فعلی نادرست است."
        elif new1 != new2:
            err = "رمز جدید و تکرار آن یکسان نیستند."
        elif len(new1) < 12:
            err = "رمز جدید باید حداقل ۱۲ نویسه باشد."
        elif new1 == sess.get("u", ""):
            err = "رمز نباید با نام کاربری یکسان باشد."
        if err:
            nonce = secrets.token_urlsafe(24)
            body = CHPASS_BODY.format(csrf=html_mod.escape(nonce),
                                      msg='<p class="err">%s</p>' % html_mod.escape(err))
            return self.render("تغییر رمز — HANASO OPS", "چرخش Credential پنل", body, code=400,
                               extra_headers={"Set-Cookie": self.csrf_cookie(nonce)})
        cred = load_credentials(cfg)
        if not cred:
            return self.send_text(500, "credentials store unavailable\n")
        salt = secrets.token_bytes(16)
        cred["salt"] = base64.b64encode(salt).decode("ascii")
        cred["hash"] = base64.b64encode(hash_password(new1, salt, cfg.iterations)).decode("ascii")
        cred["iterations"] = cfg.iterations
        cred["version"] = int(cred.get("version", 1)) + 1
        cred["changed"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        write_credentials(cfg, cred)
        log_event(cfg.log_file, "PASSWORD_CHANGED", ip=self.client_ip(), user=sess.get("u"),
                  sessions_invalidated=True)
        self.redirect("/login",
                      set_cookies=[self.clear_session_cookie()])


# --------------------------------------------------------------------------- #
# Server
# --------------------------------------------------------------------------- #
def serve(conf_path):
    cfg = Config(conf_path)
    state = StateStore(cfg.state_file)
    GatewayHandler.cfg = cfg
    GatewayHandler.state = state
    try:
        os.makedirs(os.path.dirname(cfg.state_file), exist_ok=True)
        os.makedirs(os.path.dirname(cfg.log_file), exist_ok=True)
    except Exception:
        pass
    httpd = ThreadingHTTPServer((cfg.host, cfg.port), GatewayHandler)
    httpd.daemon_threads = True
    log_event(cfg.log_file, "GATEWAY_START", host=cfg.host, port=cfg.port,
              domain=cfg.domain, version=VERSION)
    sys.stderr.write("ops-terminal-gateway %s listening on %s:%d\n" % (VERSION, cfg.host, cfg.port))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    log_event(cfg.log_file, "GATEWAY_STOP")


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def cli_passwd(cfg, args):
    import getpass
    changed = False
    if "--rotate-session-key" in args:
        rotate_session_key(cfg)
        cred = load_credentials(cfg) or {"version": 1}
        cred["version"] = int(cred.get("version", 1)) + 1
        write_credentials(cfg, cred)
        print("session key rotated; all sessions invalidated")
        log_event(cfg.log_file, "SESSION_KEY_ROTATED", by="cli")
        changed = True
    if "--generate" in args:
        username = cfg.username
        for i, a in enumerate(args):
            if a == "--username" and i + 1 < len(args):
                username = args[i + 1]
        password = generate_password()
        cred = make_credentials(username, password, cfg.iterations)
        old = load_credentials(cfg)
        cred["version"] = int(old.get("version", 1)) if old else 1
        write_credentials(cfg, cred)
        log_event(cfg.log_file, "PASSWORD_SET", by="cli-generate", user=username)
        if "--print-once" in args:
            print("PANEL_USERNAME=%s" % username)
            print("PANEL_PASSWORD=%s" % password)
            print("(shown once — store it now; run again with --generate to rotate)")
        changed = True
    if not changed:
        username = cfg.username
        print("Rotating panel password for user: %s" % username)
        p1 = getpass.getpass("New password (min 12 chars): ")
        p2 = getpass.getpass("Repeat: ")
        if len(p1) < 12 or p1 != p2:
            sys.stderr.write("password policy failed (min 12 chars, must match)\n")
            return 2
        cred = make_credentials(username, p1, cfg.iterations)
        old = load_credentials(cfg)
        cred["version"] = (int(old.get("version", 1)) + 1) if old else 1
        write_credentials(cfg, cred)
        log_event(cfg.log_file, "PASSWORD_SET", by="cli-interactive", user=username)
        print("credentials updated; existing sessions invalidated")
    return 0


def cli_verify(cfg):
    import getpass
    username = input("username: ")
    password = getpass.getpass("password: ")
    if verify_password(cfg, username, password):
        print("VALID")
        return 0
    print("INVALID")
    return 1


def main():
    conf_path = os.environ.get("OPS_TERMINAL_CONF", DEFAULT_CONF)
    args = sys.argv[1:]
    if not args:
        serve(conf_path)
        return 0
    cmd = args[0]
    cfg = Config(conf_path)
    if cmd == "passwd":
        return cli_passwd(cfg, args[1:])
    if cmd == "verify":
        return cli_verify(cfg)
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
