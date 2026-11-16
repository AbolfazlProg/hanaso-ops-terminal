# گزارش کامل تست Sandbox — HANASO OPS Web Terminal

> تاریخ: 2026-11-16 — محیط Sandbox (بدون root). خروجی نهایی باتری: `BATTERY COMPLETE — TOTAL FAILED STEPS: 0` (۴۶ PASS / ۰ FAIL) + آزمون ROOT جداگانه: ۰ FAIL.

## محیط آزمایش

| جزء | مقدار |
|------|-------|
| سیستم | Debian 13 (trixie)، x86_64، کاربر غیر root (uid 1001)، PID1=tini (بدون systemd runtime) |
| nginx | 1.26.3 — بسته باینری Debian trixie، استخراج unprivileged، با `http_auth_request_module` |
| tmux | 3.5a — استخراج unprivileged (+ libevent) |
| ttyd | 1.7.7 vendored — SHA256 تأییدشده در برابر SHA256SUMS رسمی upstream |
| مرورگر | Playwright + Chromium واقعی (همان نوع Browser Automation که Agentهای آینده استفاده می‌کنند) |
| TLS آزمایشی | گواهی Self-Signed فقط برای آزمایشگاه (Production: Let's Encrypt) |
| پورت‌ها | 8080/8443 nginx آزمایشی؛ 7681/7682 loopback (در Production: 80/443 همان زنجیره) |

## جدول ۱۶ آزمون اجباری مأموریت

| # | آزمون مأموریت | نتیجه | شواهد |
|---|---------------|-------|--------|
| 1 | نصب کامل از صفر | PASS | باتری مرحله ۱۰ (reinstall از صفر) + مرحله نصب rootproof — هر دو با e2e سبز |
| 2 | اجرای Systemd Service | PASS (سطح Sandbox) | `systemd-analyze verify` روی هر دو Unit ساختاری معتبر؛ در Sandbox سرویس‌ها با nohup اجرا شدند (PID1=tini)؛ در Production با `systemctl enable --now` بالا می‌آیند و Installer خودش e2e می‌گیرد |
| 3 | باز شدن پنل از مرورگر واقعی | PASS | Playwright: `01-login.png` |
| 4 | ورود با Credential | PASS | فرم لاگین پر شد → 302 → صفحه ترمینال |
| 5 | باز شدن ترمینال واقعی | PASS | `.xterm` رندر شد؛ متن ترمینال از `window.term` buffer API خوانده شد |
| 6 | `id -u` → خروجی `0` | PASS | آزمون ROOT (userns): هم WS-e2e و هم مرورگر واقعی `id -u -> 0` (اثبات فایل side-channel + متن ترمینال) — در Production سرویس root واقعی است |
| 7 | `hostname` و `pwd` | PASS | هر دو در e2e و مرورگر |
| 8 | ایجاد/خواندن/حذف فایل | PASS | چرخه فایل با اثبات filesystem side-channel در مرورگر واقعی |
| 9 | دستورات تعاملی | PASS | `read -p ...` در e2e — خروجی تعاملی برگشت |
| 10 | WebSocket طولانی‌مدت | PASS | test_longws: ۶۲ ثانیه، ping/pong فعال، خروجی دیرهنگام دریافت شد |
| 11 | قطع/وصل مرورگر + رفتار Session | PASS | مرورگر: بستن Tab حین `sleep` → بازگشت بدون لاگین → خروجی پس از قطع رسید (tmux)؛ WS: reconnect همان |
| 12 | Restart سرویس و بازگشت | PASS | test_restart: gateway restart (کوکی ماند)، ttyd kill+restart (خروجی دستور ادامه‌یافت)، nginx restart |
| 13 | عدم دسترسی بدون Credential | PASS | GET / → 302 /login؛ WS بدون کوکی → بدون 101 |
| 14 | محدودسازی ورود ناموفق | PASS | nginx 429 دیده شد؛ Gateway 423 بعد از خطاها؛ قفل پس از restart پایدار؛ رمز درست هم در قفل رد شد؛ بازیابی بعد از پاک‌سازی state |
| 15 | TLS و عدم نشت HTTP | PASS | http→301 https (بدو پردازش بدنه)؛ HSTS؛ Canary رمز در لاگ‌ها ظاهر نشد؛ رمز پنل در هیچ لاگی نیست |
| 16 | Uninstaller | PASS | فقط فایل‌ها/پورت‌های پنل حذف شد؛ هیچ سرویس دیگری دست نخورد |

## مهم‌ترین آزمون: مرورگر واقعی + اجرای دستور Root

`tests/browser-test.js` (Playwright/Chromium) — همان الگوی تعاملی Agentهای آینده:
1. بدون کوکی → redirect به /login ✅
2. پر کردن فرم + ورود ✅
3. `.xterm` رندر ✅ (متن ترمینال از `window.term` — قابلیت API رسمی ttyd — خواندنی است)
4. تایپ `id -u > /tmp/...` → **اثبات side-channel**: فایل در filesystem واقعی ظاهر شد = دستور از راه مرورگر واقعاً اجرا شد ✅
5. چرخه فایل (ایجاد/خواندن/حذف) ✅
6. بستن Tab حین دستور طولانی → بازگشت بدون لاگین → دستور ادامه داشت (tmux) ✅

اسکرین‌شات‌ها: `shots/01-login.png`، `02-terminal.png`، `03-reconnect.png` (+ نسخه uid-0 در `shots-root/`).

## آزمون ROOT (userns) — tests/rootproof.sh

Sandbox اجازه root واقعی نمی‌دهد؛ همان کد مسیر Production (systemd unit با User=root) با **Unprivileged User Namespace** شبیه‌سازی شد (`unshare -Ur`): داخل namespace کاربر uid 0 گزارش می‌شود. نتیجه:
- e2e در سطح WebSocket: `id -u -> 0` ✅ (۱۴/۱۴)
- مرورگر واقعی Playwright: `id -u -> 0` — هم اثبات فایل و هم متن ترمینال ✅ (۸/۸)
- روی VPS واقعی، سرویس با rootِ واقعی اجرا می‌شود و Installer در پایان نصب خودش `--expect-uid 0` را می‌سنجد.

## تفاوت‌های محیط آزمایش با VPS واقعی (صادقانه)

| مورد | Sandbox | VPS واقعی |
|------|---------|-----------|
| systemd runtime | ندارد (tini) — Units با nohup + `systemd-analyze verify` | واقعی؛ `enable --now` + self-e2e |
| ROOT | شبیه‌سازی userns (uid 0 داخل ns) | root واقعی (unit بدون User=) |
| گواهی | Self-Signed آزمایشی | Let's Encrypt (موجود یا صدور certbot) |
| پورت‌های nginx | 8080/8443 | 80/443 همان زنجیره Reverse Proxy |
| DNS | `--resolve`/host-map به 127.0.0.1 | ops.hanaso.ir → IP VPS (DNS Only) |
| Egress TCP/22 به VPS | مسدود (بازرسی SSH از Sandbox ممکن نبود) | preflight روی خود VPS در زمان نصب (read-only) |

## بازرسی خارجی VPS (از Sandbox)

- `IP-VPS:443` → `Server: nginx` — nginx مستقیماً روی 443 TLS خاتمه می‌دهد؛ گواهی پیش‌فرض vhost فعلی: `CN=kotodama.ir` (Let's Encrypt).
- `ops.hanaso.ir` الان به همان VPS اشاره می‌کند و فعلاً به vhost پیش‌فرض می‌افتد (پنل هنوز نصب نشده) — پس از نصب، vhost اختصاصی فعال می‌شود.
- تشخیص عمیق توپولوژی (پروسه‌های 80/443، vhostهای موجود، HAProxy) به `scripts/preflight.sh` در زمان نصب روی خود VPS واگذار شده (read-only، قبل از هر تغییر).

## نکته عملیاتی

اجرای اول باتری پس از rootproof با ۴ مرحله ناموفق بود چون Sweep فرزندان کهنه install، ttyd سندباکس اصلی را متوقف کرده بود (مستند در سربرگ rootproof.sh). اجرای دوم بعد از restore کامل → **کاملاً سبز**. قاعده: بعد از rootproof، باتری را بعد از یک install/اجرای سرویس‌ها اجرا کنید.
