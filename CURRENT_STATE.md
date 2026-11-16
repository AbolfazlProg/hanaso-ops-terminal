# CURRENT STATE — HANASO OPS Web Terminal

> آخرین به‌روزرسانی: 2026-11-16 — Sandbox session
> این فایل وضعیت واقعی پروژه را در هر Checkpoint ثبت می‌کند. هرگز ادعای Push/Deploy بدون تأیید نمی‌شود.

## مأموریت

ساخت پنل Web Terminal با ROOT واقعی برای VPS مشترک HANASO، پشت احراز هویت مستقل و HTTPS،
بدون وابستگی به GitHub Actions / SSH از Sandbox / Cloudflare Tunnel. محصول نهایی: Installer
تست‌شده که Owner روی VPS اجرا می‌کند. **هیچ تغییری روی VPS واقعی در این مأموریت انجام نمی‌شود.**

## وضعیت محیط Sandbox (تأییدشده)

- Debian 13 (trixie), x86_64, کاربر غیر root (uid 1001), PID1=tini (بدون systemd فعال)
- **TCP/22 خروجی به VPS مسدود است** → بررسی زیرساخت واقعی از Sandbox ممکن نیست؛
  تشخیص Topology به `scripts/preflight.sh` در زمان نصب روی خود VPS واگذار شده است (read-only، قبل از هر تغییر).
- Playwright + Chromium برای Browser Automation موجود است.
- اجزای تست (بدون نیاز به root):
  - ttyd 1.7.7 (x86_64) — دانلود از Release رسمی + **تأیید SHA256 با فایل رسمی SHA256SUMS** → `vendor/`
  - nginx 1.26.3 (بسته باینری Debian trixie، شامل `http_auth_request_module`) — استخراج unprivileged
  - tmux 3.5a + libevent-core — استخراج unprivileged

## وضعیت DNS (تأییدشده از Sandbox)

- `ops.hanaso.ir` هم‌اکنون رکورد A دارد و به IP عمومی VPS اشاره می‌کند (بررسی با dig + Cloudflare DoH،
  TTL 300، مقدار IP در این فایل ثبت نمی‌شود). یعنی DNS از قبل آماده است؛ در زمان نصب دوباره اعتبارسنجی می‌شود.
- NS دامنه hanaso.ir روی Cloudflare است (khloe/newt).

## تصمیم‌های ثبت‌شده

| # | تصمیم | وضعیت |
|---|-------|-------|
| D1 | ابزار Web Terminal: **ttyd 1.7.7** (binary استاتیک، WebSocket، بدون وابستگی) | تأیید |
| D2 | Session persistence: **tmux** (`tmux new -A -s ops`) — ادامه Session پس از قطع مرورگر/ری‌استارت سرویس | تأیید |
| D3 | احراز هویت: **Auth Gateway اختصاصی (Python stdlib)** + nginx `auth_request` + کوکی امضاشده HMAC | تأیید |
| D4 | ترمینال فقط روی `127.0.0.1:7681` (ttyd) و Gateway روی `127.0.0.1:7682`؛ دسترسی خارجی فقط از طریق Reverse Proxy فعلی روی 443 | تأیید |
| D5 | Gateway با کاربر سیستمی اختصاصی `ops-gw` اجرا می‌شود؛ فقط ttyd با root اجرا می‌شود (لازم برای ROOT Shell) | تأیید |
| D6 | Brute-force: nginx `limit_req` روی /login + قفل پیش‌رونده سمت Gateway با ذخیره پایدار | تأیید |
| D7 | TLS: استفاده از گواهی موجود در صورت پوشش دامنه؛ در غیر این صورت Let's Encrypt (certbot) در زمان نصب | تأیید |

## Checkpoints

| CP | شرح | وضعیت |
|----|------|--------|
| CP0 | ساخت Repository + CURRENT_STATE + Push اولیه | ✅ انجام شد |
| CP1 | سند مقایسه راهکارها و معماری نهایی (ARCHITECTURE.md) | ⏳ |
| CP2 | پیاده‌سازی کامل (gateway/systemd/nginx/scripts/docs) | ⏳ |
| CP3 | استقرار Sandbox (nginx+TLS آزمایشی+سرویس‌ها) | ⏳ |
| CP4 | اجرای ۱۶ تست اجباری + شواهد (SANDBOX_TEST_REPORT.md) | ⏳ |
| CP5 | Browser Automation واقعی (Playwright) — ورود + اجرای دستور در ترمینال | ⏳ |
| CP6 | Release/Tag + Bootstrap + دستور نهایی نصب تست‌شده | ⏳ |

## نکات امنیتی رعایت‌شده

- هیچ Secret/Token/Password/IP در Repository قرار نمی‌گیرد (pre-push scan خودکار).
- رمز اولیه پنل توسط Installer به‌صورت تصادفی تولید و فقط یک‌بار در کنسول Owner نمایش داده می‌شود.
- Credentialها با PBKDF2-HMAC-SHA256 (200k iteration) ذخیره می‌شوند؛ فایل با مجوز 0600.
