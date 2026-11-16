# CURRENT STATE — HANASO OPS Web Terminal

> آخرین به‌روزرسانی: 2026-11-17 — CP10 (HOTFIX گواهی خالی + صدور Let's Encrypt از مسیر ACME واقعی)
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
| D10 | توپولوژی‌ها: nginx-direct + haproxy-front + haproxy-tcp-passthrough — تشخیص خودکار در Preflight |
| D11 | HAProxy: بلوک‌های مدیریت‌شده BEGIN/END + تبدیل برگشت‌پذیر crt→crt-list + فقط `haproxy -c` و reload (هرگز restart) |
| D12 | فایل env Preflight: سریال‌سازی امن KEY='VALUE' + پارسر سخت‌گیرانه؛ **هرگز source/eval نمی‌شود** (رفع حادثه 2026-11-16) |
| D13 | nginx داخلی پشت HAProxy: مستقل، loopback-only، `absolute_redirect off` (جلوگیری از ریدایرکت مطلق به پورت داخلی) |
| D14 | نصب تک‌خطی: بوت‌استرپ `quick-install.sh` (curl \| bash) — کلون مخزن + راستی‌آزمایی fail-closed مانیفست SHA256SUMS + پاس عیناً به Installer رسمی؛ **fd0 هرگز لمس نمی‌شود** (منبعِ خود اسکریپت در حالت curl \| bash) — درس تست واقعی 2026-11-17 |
| D15 | CP10: مقدار خالی `PREFLIGHT_CERT_PATH=''` وضعیت معمولیِ «بدون گواهی موجود» است (پارسر: newline اضافه برای grep تا خطِ خالی match شود؛ fail-closed دست‌نخورده)؛ صدور Let's Encrypt از مسیر ACME مدیریت‌شده :80 با `use_backend` (نه `http-request use-backend` که در HAProxy 2.x/3.x نامعتبر است)؛ اعتبارسنجی جفت گواهی در همه مسیرها؛ reinstall مسیر ACME را بازمی‌سازد |

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
| CP7 | پشتیبانی HAProxy (3 توپولوژی) + رفع باگ Preflight (پارسر امن) + باتری HAProxy + رگرسیون کامل | 08858af (tag v1.1.0) | ✅ Push شده — در انتظار نصب Production |
| CP8 | نصب تک‌خطی `quick-install.sh` (curl \| bash) + رفع باگ fd0 + مستندسازی | 5e20327 / e5401ab | ✅ Push و تست‌شده |
| CP9 | Release v1.2.0: CURRENT_STATE + مستندات one-liner تگ‌دار + SHA256SUMS نهایی | v1.2.0 | ✅ Push شده |
| CP10 | HOTFIX: پذیرش `PREFLIGHT_CERT_PATH=''` + شاخه صدور certbot واقعی + مسیر ACME صحیح + بازسازی مسیر ACME در reinstall + اعتبارسنجی جفت گواهی + باتری CP10 (سناریوی دقیق VPS) | tag v1.2.1 | ✅ تست و Push شده — در انتظار نصب Production |

## نتایج آزمون (خلاصه)

- باتری nginx-direct ۱۰ مرحله‌ای: **TOTAL FAILED STEPS: 0** (۴۶ PASS / ۰ FAIL) — `tests/SANDBOX_TEST_REPORT.md`
- باتری HAProxy ۱۶ مرحله‌ای: **TOTAL FAILED STEPS: 0** (۸۱ PASS / ۰ FAIL) — شامل install، تبدیل برگشت‌پذیر crt→crt-list، e2e کامل از پشت TLS+SNI، مرورگر واقعی، brute-force، XFF spoof-proofing، rollback تحمیلی (شکست e2e بعد از سیم‌کشی HAProxy → بازگشت دقیق)، idempotent reinstall، uninstall و نصب نهایی — `tests/haproxy-battery.sh`
- نصب تک‌خطی واقعی از GitHub (2026-11-17): `curl -fsSL .../main/quick-install.sh \| bash -s -- --sandbox ...` → clone از github.com (commit e5401ab) → **SHA256SUMS: OK** → نصب کامل + e2e داخلی Installer → health-check **HEALTHY** → uninstall پاک — rc=0. نکته: CDN خام تا ~۵ دقیقه بعد از Push نسخه قبلی را سرو می‌کند؛ برای VPS از URL تگ‌دار (v1.2.0) استفاده کنید.
- باتری CP10 (`tests/cp10-battery.sh`) — سناریوی دقیق VPS (`PREFLIGHT_CERT_PATH=''` + certbot موجود + clean install بدون گواهی اولیه): **TOTAL FAILED STEPS: 0** (۹۱ PASS) — پذیرش fixture پارسر + فعال‌شدن شاخه certbot + round-trip چالش ACME از لبه واقعی :80 + صدور شبیه‌سازی‌شده با certbot stub + جایگزینی مسیر + اعتبار HAProxy + HTTPS/SNI/WS + مرورگر واقعی + **id -u=0 از مرورگر** + rollback تحمیلی + uninstall (حفظ state LE) + مسیر منفی صدور شکست → TLS GATE فقط-loopback
- رگرسیون CP7 پس از تغییرات install.sh: باتری HAProxy **۰ FAILED** — رگرسیون baseline: باتری nginx-direct **۰ FAILED**
- مرورگر واقعی (Playwright) در هر دو توپولوژی: ✅ — متن ترمینال از `window.term` + اثبات فایل side-channel
- ROOT-proof (userns): `id -u -> 0` از مرورگر واقعی و WS ✅
- گزارش کامل: `tests/SANDBOX_TEST_REPORT.md`

## امنیت

هیچ Secret/IP/Token/رمزی در Repository نیست (اسکن pre-push خودکار). رمز پنل فقط یک‌بار در کنسول نصب نمایش داده می‌شود؛ Credential با PBKDF2 (200k) در فایل 0600.
