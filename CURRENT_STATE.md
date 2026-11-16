# CURRENT STATE — HANASO OPS Web Terminal

> آخرین به‌روزرسانی: 2026-11-16 — پایان CP6 (Release-ready)
> این فایل وضعیت واقعی را در هر Checkpoint ثبت می‌کند. هیچ ادعای Push/Deploy بدون تأیید نمی‌شود.

## مأموریت

پنل Web Terminal با **ROOT Shell واقعی** برای VPS مشترک HANASO، پشت احراز هویت مستقل و HTTPS، روی 443 موجود nginx — بدون وابستگی عملیاتی به GitHub Actions / SSH از Sandbox / Cloudflare Tunnel. این Session فقط ساخت و آزمایش؛ **هیچ تغییری روی VPS واقعی انجام نشده است.**

## وضعیت DNS (تأییدشده)

- `ops.hanaso.ir` → IP عمومی VPS (رکورد A، DNS Only؛ NS: Cloudflare khloe/newt) — از قبل تنظیم شده.
- بازرسی خارجی: nginx روی 443 VPS مستقیماً TLS خاتمه می‌دهد (گواهی فعلی پیش‌فرض: CN=kotodama.ir).
- TCP egress پورت 22 از Sandbox مسدود → تشخیص توپولوژی کامل به preflight در زمان نصب (read-only) سپرده شده.

## محیط آزمایش Sandbox (تأییدشده)

Debian 13 trixie / x86_64 / کاربر uid 1001 بدون root / PID1=tini / nginx 1.26.3 (استخراج unprivileged، auth_request دارد) / tmux 3.5a / ttyd 1.7.7 vendored (SHA256 رسمی) / Playwright+Chromium / userns فعال برای شبیه‌سازی ROOT.

## تصمیم‌های ثبت‌شده

| # | تصمیم |
|---|--------|
| D1 | ابزار: **ttyd 1.7.7** (باینری استاتیک؛ WebSocket؛ ping 5s پیش‌فرض) |
| D2 | Session persistence: **tmux** (`tmux new -A -s ops`) |
| D3 | احراز هویت: **Gateway اختصاصی Python-stdlib + nginx auth_request + کوکی HMAC** |
| D4 | ttyd → 127.0.0.1:7681 (root)؛ Gateway → 127.0.0.1:7682 (ops-gw) |
| D5 | Brute-force: nginx limit_req + قفل پیش‌رونده پایدار Gateway |
| D6 | TLS: گواهی موجود یا Let's Encrypt (certbot HTTP-01 webroot)؛ توقف امن در نبود DNS/TLS |
| D7 | فقط vhost مستقل nginx + reload (هرگز restart)؛ rollback خودکار |
| D8 | اثبات مرورگر: Playwright + `window.term` (متن ترمینال خواندنی) + اثبات side-channel فایل |
| D9 | اثبات ROOT در Sandbox: userns `unshare -Ur` (id -u=0 از مرورگر واقعی + WS) |

## Checkpoints

| CP | شرح | Commit | وضعیت |
|----|------|-------|-------|
| CP0 | Repository + baseline | d7f12d2 | ✅ Push شده |
| CP1 | معماری/مقایسه راهکارها (README + مستندات) | d7f12d2..6f3f3b6 | ✅ Push شده |
| CP2 | پیاده‌سازی کامل (gateway/units/vhost/scripts) | 6f3f3b6 | ✅ Push شده |
| CP3/4 | استقرار Sandbox + ۱۴ e2e سبز | a3f469a | ✅ Push شده |
| CP5 | تست مرورگر واقعی + باتری کامل + ROOT-proof + هاردنینگ (session revocation و...) | f1e40d0 | ✅ |
| CP6 | مستندات کامل + SHA256SUMS + Tag v1.0.0 + Installer تست‌شده | e1fb8a1 | ✅ |
| — | Release (SHA256SUMS + tag v1.0.0) | v1.0.0 | ✅ |

## نتایج آزمون (خلاصه)

- باتری کامل ۱۰ مرحله‌ای: **TOTAL FAILED STEPS: 0** (۴۶ PASS / ۰ FAIL) — `tests/SANDBOX_TEST_REPORT.md`
- مرورگر واقعی (Playwright): ۸/۸ ✅ — متن ترمینال از `window.term` + اثبات فایل side-channel
- ROOT-proof (userns): `id -u -> 0` از مرورگر واقعی و WS ✅
- گزارش کامل: `tests/SANDBOX_TEST_REPORT.md`

## امنیت

هیچ Secret/IP/Token/رمزی در Repository نیست (اسکن pre-push خودکار). رمز پنل فقط یک‌بار در کنسول نصب نمایش داده می‌شود؛ Credential با PBKDF2 (200k) در فایل 0600.
