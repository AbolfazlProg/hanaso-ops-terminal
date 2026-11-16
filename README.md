# HANASO OPS Web Terminal

پنل ترمینال تحت وب با **ROOT Shell واقعی** برای VPS مشترک HANASO — پشت احراز هویت مستقل،
قفل Brute-Force و HTTPS روی Reverse Proxy موجود — بدون وابستگی عملیاتی به GitHub Actions، SSH از Sandbox یا Cloudflare Tunnel.

## نصب تک‌خطی (VPS — به‌عنوان root)

```bash
curl -fsSL https://raw.githubusercontent.com/AbolfazlProg/hanaso-ops-terminal/main/quick-install.sh \
  | bash -s -- --domain ops.hanaso.ir --acme-email admin@hanaso.ir
```

- همه آرگومان‌ها عیناً به `scripts/install.sh` پاس می‌شوند (`--yes`، `--tls-cert/--tls-key`، پورت‌ها و …).
- بوت‌استرپ `quick-install.sh` مخزن را می‌گیرد (git یا tarball)، مانیفست `SHA256SUMS` را **fail-closed** راستی‌آزمایی می‌کند و سپس Installer رسمی را اجرا می‌کند؛ بدون root اجرا نمی‌شود (مگر `--sandbox`).
- **توصیه‌شده برای VPS — پین به نسخه منتشرشده:**
  ```bash
  curl -fsSL https://raw.githubusercontent.com/AbolfazlProg/hanaso-ops-terminal/v1.2.3/quick-install.sh \
    | bash -s -- --domain ops.hanaso.ir --acme-email admin@hanaso.ir
  ```
- پین‌کردن شاخه: `... | QUICK_INSTALL_REF=v1.0.0 bash -s -- --domain ops.hanaso.ir` — نکته: CDN خام تا ~۵ دقیقه بعد از Push ممکن است نسخه قبلی شاخه `main` را سرو کند؛ URL تگ‌دار (بالا) این مسئله را ندارد.
- برای نصب قابل‌بازبینی، مخزن را Clone کنید و `SHA256SUMS` را خودتان چک کنید — راهنمای کامل: [`docs/INSTALL.md`](docs/INSTALL.md)

## معماری — هر دو توپولوژی Reverse Proxy پشتیبانی می‌شود

```
nginx-direct (nginx مستقیماً TLS را روی 443 خاتمه می‌دهد):

مرورگر (Agent/Owner)
   │  HTTPS (wss) — پورت 443 موجود nginx
   ▼
nginx فعلی سرور (Virtual Host اختصاصی ops.hanaso.ir)
   │  auth_request → کوکی Session امضاشده
   │  limit_req    → قفل Brute-Force
   ├──► 127.0.0.1:7682  ops-terminal-gateway  (Auth Gateway — Python stdlib، کاربر ops-gw)
   └──► 127.0.0.1:7681  ttyd 1.7.7 (کاربر root) → tmux session «ops» → ROOT Shell واقعی
```

```
haproxy-front (HAProxy مالک 443 عمومی است — توپولوژی واقعی VPS):

مرورگر (Agent/Owner)
   │  HTTPS (wss) — پورت 443 موجود HAProxy
   ▼
HAProxy (bind ssl مشترک kotodama.ir/hanaso.ir — دست‌نخورده باقی می‌ماند)
   │  ACL مدیریت‌شده SNI/Host فقط برای ops.hanaso.ir
   ▼
nginx داخلی مستقل (127.0.0.1:7680 — کاربر ops-gw، فقط loopback)
   │  auth_request + limit_req + WS proxy
   ├──► 127.0.0.1:7682  ops-terminal-gateway
   └──► 127.0.0.1:7681  ttyd 1.7.7 (root) → tmux «ops» → ROOT Shell واقعی
```

- در توپولوژی HAProxy، گواهی پنل با یکی از روش‌های **بدون‌خرابی** به HAProxy اضافه می‌شود:
  drop-in در دایرکتوری `crt` موجود، append به `crt-list` موجود، یا تبدیل برگشت‌پذیر
  `crt FILE` → `crt-list` (گواهی اصلی عیناً حفظ می‌شود).
- HAProxy هرگز Restart نمی‌شود — فقط `haproxy -c` و سپس **reload**؛ ویرایش‌ها داخل
  بلوک‌های `# BEGIN/END ops-terminal` هستند و حذف آن‌ها جراحی است.
- توپولوژی سوم (`haproxy-tcp-passthrough`) هم پشتیبانی می‌شود: HAProxy فقط TCP جلو
  می‌گذارد و nginx داخلی خودش TLS را خاتمه می‌دهد.

## اجزای پروژه

| مسیر | شرح |
|------|------|
| `gateway/gateway.py` | احراز هویت مستقل (Login/Logout/Change-Password) + قفل IP + لاگ رویداد — فقط Python stdlib |
| `vendor/` | باینری ttyd 1.7.7 + SHA256SUMS رسمی upstream |
| `systemd/` | `ops-terminal.service` (ttyd/root)، `ops-terminal-gateway.service` (ops-gw)، `ops-terminal-nginx.service` (nginx داخلی توپولوژی HAProxy) |
| `nginx/ops-terminal.conf.template` | vhost مشترک nginx (توپولوژی nginx-direct) |
| `nginx/ops-terminal-internal.conf.template` | nginx داخلی loopback برای پشت HAProxy |
| `scripts/install.sh` | Installer مستقل، Idempotent — تشخیص خودکار توپولوژی + Preflight + Backup + Rollback خودکار |
| `scripts/uninstall.sh` | حذف کامل و مستقل (هر دو توپولوژی — شامل بازگردانی دقیق بلوک‌های HAProxy) |
| `scripts/preflight.sh` | بررسی سازگاری VPS قبل از نصب (فقط-خواندنی؛ خروجی KEY='VALUE' امن) |
| `scripts/ops-env.sh` | سریال‌سازی/پارسر سخت‌گیرانه فایل env — هرگز source/eval نمی‌شود (درس حادثه 2026-11-16) |
| `scripts/ops-haproxy.sh` | کتابخانه تحلیل/ویرایش جراحی haproxy.cfg (بلوک‌های مدیریت‌شده + اعتبارسنجی) |
| `scripts/ops-terminal-passwd` | تولید/چرخش Credential بدون افشا در argv |
| `scripts/e2e-test.py` | تست انتها-به-انتها: Login → WebSocket → اجرای دستور → Assertion |
| `scripts/health-check.sh` | بررسی سلامت سرویس‌ها + loopback-only (آگاه از توپولوژی) |
| `tests/` | باتری nginx-direct + باتری HAProxy + باتری CP10/CP11/CP12 + مرورگر واقعی (Playwright) + آزمون ROOT (userns) |
| `docs/` | مستندات نصب/امنیت/حذف/عیب‌یابی/Rollback |

## نصب سریع (Owner)

دستور نهایی و تست‌شده در [`docs/INSTALL.md`](docs/INSTALL.md) ارائه شده است.
پیش‌نیاز: رکورد A برای `ops.hanaso.ir` به IP عمومی VPS (حالت DNS Only).
Installer توپولوژی (nginx یا HAProxy) را خودش در Preflight تشخیص می‌دهد.

> ⚠️ این پنل ROOT Shell واقعی ارائه می‌کند. [`docs/SECURITY.md`](docs/SECURITY.md) را بخوانید.

## وضعیت

- وضعیت لحظه‌ای: [`CURRENT_STATE.md`](CURRENT_STATE.md)
- گزارش کامل تست Sandbox: [`tests/SANDBOX_TEST_REPORT.md`](tests/SANDBOX_TEST_REPORT.md)
- باتری nginx-direct: `bash tests/run-battery.sh` — آخرین نتیجه: **0 FAILED**
- باتری HAProxy: `bash tests/haproxy-battery.sh` — آخرین نتیجه: **0 FAILED**
- باتری CP12 (سازگاری نهایی systemd/nginx): `bash tests/cp12-battery.sh` — آخرین نتیجه: **0 FAILED (۱۰۱ PASS)** — شامل اجرای verbatim unit روی باینری هم‌کلاس VPS (Ubuntu 1.18.0) و اثبات تراکنش واقعی systemd 257 روی unitهای واقعی
