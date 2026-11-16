# نصب HANASO OPS Web Terminal (Production — روی VPS)

راهنمای نصب واقعی روی سرور. برای روش آزمایش در Sandbox، [`tests/SANDBOX_TEST_REPORT.md`](../tests/SANDBOX_TEST_REPORT.md) را ببینید.

## معماری

```
مرورگر (Agent/Owner)
   │  HTTPS/wss — پورت 443 موجود nginx
   ▼
nginx (Virtual Host اختصاصی ops.hanaso.ir — auth_request + limit_req + WS proxy)
   ├──► 127.0.0.1:7682  ops-terminal-gateway  (احراز هویت مستقل — کاربر ops-gw)
   └──► 127.0.0.1:7681  ttyd 1.7.7 (root) → tmux session «ops» → ROOT Shell واقعی
```

## پیش‌نیازها (Preflight خودکار همه را بررسی می‌کند)

| نیاز | توضیح |
|------|------|
| دسترسی root به VPS | نصب سرویس root + تغییر nginx |
| Debian/Ubuntu + systemd | سرویس‌های پایدار پس از Reboot |
| nginx موجود با `http_auth_request_module` | بسته‌های استاندارد nginx دیبیان/اوبونتو دارند |
| python3 >= 3.8 | Gateway (فقط stdlib — بدون pip) |
| tmux | اگر نباشد، Installer خودش `apt-get install -y tmux` می‌کند |
| curl | بررسی سلامت + صدور گواهی |

## رکورد DNS مورد نیاز

| فیلد | مقدار |
|------|------|
| نوع Record | **A** |
| نام | **ops** |
| مقدار | **IP عمومی VPS** |
| حالت Proxy | **DNS Only** (خاکستری — نه Proxied) |

- Proxied نکنید: TLS روی خود VPS خاتمه می‌یابد و ACME HTTP-01 باید مستقیم به VPS برسد.
- در زمان نگارش، `ops.hanaso.ir` از قبل با A Record و حالت DNS Only به IP عمومی VPS اشاره می‌کند؛ Preflight در زمان نصب دوباره اعتبارسنجی می‌کند.

## پورت‌ها — هیچ پورت جدیدی باز نمی‌شود

| پورت | نقش |
|------|------|
| 443 (موجود) | vhost جدید nginx برای ops.hanaso.ir — WebSocket proxy |
| 80 (موجود) | redirect به HTTPS + مسیر ACME HTTP-01 |
| 7681 / 7682 | فقط **127.0.0.1** (ttyd / gateway) — از بیرون قابل دسترسی نیستند |

## دستور نصب (Owner — به‌عنوان root روی VPS)

```bash
rm -rf /tmp/hanaso-ops-install
git clone --depth 1 --branch v1.0.0 https://github.com/AbolfazlProg/hanaso-ops-terminal.git /tmp/hanaso-ops-install
cd /tmp/hanaso-ops-install
sha256sum -c SHA256SUMS        # بررسی یکپارچگی فایل‌ها
bash scripts/install.sh --yes
```

- اگر Repository خصوصی است، ابتدا آن را عمومی کنید (این پروژه Secret ندارد):
  `gh repo edit AbolfazlProg/hanaso-ops-terminal --visibility public` یا از Settings در وب.
- **رمز پنل یک بار در پایان نصب نمایش داده می‌شود** — همان لحظه ذخیره کنید و خروجی را به فایل نریزید.

پس از نصب: `https://ops.hanaso.ir` → ورود → ترمینال ROOT واقعی.

## Installer چه کار می‌کند (به ترتیب)

1. **Preflight فقط-خواندنی**: توپولوژی 80/443 (`ss -tlnp`)، ماژول auth_request، پورت‌های آزاد، DNS، گواهی موجود، تداخل vhost.
2. **Backup** از وضعیت فعلی → `/var/backups/ops-terminal/<timestamp>/`.
3. نصب ttyd 1.7.7 (SHA256-verified) + Gateway + ابزارها در `/opt/ops-terminal`.
4. کاربر سیستمی `ops-gw` (بدون shell) برای Gateway؛ فقط ttyd با root اجرا می‌شود.
5. تولید Credential تصادفی ۲۴ کاراکتری (PBKDF2، فایل 0600) + کلید Session مستقل.
6. سرویس‌های systemd (`ops-terminal-gateway` و `ops-terminal`) — `enable --now` (پایدار پس از Reboot).
7. **TLS**: گواهی موجود پوشش‌دهنده → استفاده مجدد؛ وگرنه certbot (HTTP-01 webroot) برای ops.hanaso.ir.
8. **vhost nginx**: فایل مستقل `ops-terminal.conf` + symlink؛ `nginx -t` → فقط **reload** (بدون Restart؛ vhostهای موجود HANASO/KOTODAMA دست نمی‌خورند).
9. **تست انتها-به-انتهای خودکار** (login → WebSocket → اجرای `id -u` با انتظار خروجی `0`)؛ در صورت شکست: **Rollback خودکار**.
10. اگر DNS یا TLS آماده نباشد: **توقف امن** در حالت loopback-only با پیام روشن — هیچ سطح اینترنتی بدون HTTPS معتبر فعال نمی‌شود.

## بعد از نصب

```bash
bash /opt/ops-terminal/health-check.sh          # سلامت سرویس‌ها + loopback-only بودن
systemctl status ops-terminal ops-terminal-gateway
journalctl -u ops-terminal-gateway -n 20        # رویدادهای LOGIN/LOGOUT + IP
```

- دستورات داخل ترمینال **دوام دارند** (tmux session «ops»): قطع مرورگر → دوباره باز کنید → همان Session ادامه می‌یابد.
- برای Session تازه: داخل پنل `exit` بزنید یا tmux را ریست کنید (به TROUBLESHOOTING مراجعه کنید).

## چرخش رمز

```bash
ops-terminal-passwd --generate --print-once   # رمز تصادفی جدید — یک‌بار نمایش
```
یا از خود پنل: `/change-password`. هر دو روش Sessionهای قبلی را بی‌اعتبار می‌کنند.

## توقف / شروع / حذف

```bash
systemctl stop ops-terminal ops-terminal-gateway      # توقف (tmux session زنده می‌ماند)
systemctl start ops-terminal-gateway ops-terminal      # شروع (tmux دوباره attach می‌شود)
bash /tmp/hanaso-ops-install/scripts/uninstall.sh --yes   # حذف کامل (nginx -t + reload)
```

## نصب مجدد (Idempotent)

اجرای مجدد Installer فقط فایل‌ها را به‌روز می‌کند؛ Credentialهای موجود حفظ می‌شوند مگر `--reset-credentials` بدهید.

## توپولوژی غیر nginx-direct (مثلاً HAProxy جلوی 443)

Installer **متوقف می‌شود** و خروجی `scripts/preflight.sh` را می‌خواهد تا وصله HAProxy با بازبینی انسانی آماده شود — ویرایش کور زنجیره مشترک انجام نمی‌شود.
