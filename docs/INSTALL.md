# نصب HANASO OPS Web Terminal (Production — روی VPS)

راهنمای نصب واقعی روی سرور. برای روش آزمایش در Sandbox، [`tests/SANDBOX_TEST_REPORT.md`](../tests/SANDBOX_TEST_REPORT.md) و باتری HAProxy (`tests/haproxy-battery.sh`) را ببینید.

## معماری

Installer توپولوژی Reverse Proxy را در Preflight خودکار تشخیص می‌دهد:

```
nginx-direct — nginx مستقیماً روی 443 TLS خاتمه می‌دهد:
مرورگر → nginx (vhost اختصاصی ops.hanaso.ir)
   ├──► 127.0.0.1:7682  ops-terminal-gateway
   └──► 127.0.0.1:7681  ttyd (root) → tmux «ops»

haproxy-front — HAProxy مالک 443 عمومی است (توپولوژی واقعی VPS):
مرورگر → HAProxy (bind ssl مشترک — دست‌نخورده)
   │  ACL مدیریت‌شده SNI/Host فقط برای ops.hanaso.ir
   ▼
nginx داخلی مستقل (127.0.0.1:7680، فقط loopback)
   ├──► 127.0.0.1:7682  ops-terminal-gateway
   └──► 127.0.0.1:7681  ttyd (root) → tmux «ops»
```

## پیش‌نیازها (Preflight خودکار همه را بررسی می‌کند)

| نیاز | توضیح |
|------|------|
| دسترسی root به VPS | نصب سرویس root + تغییر nginx/HAProxy |
| Debian/Ubuntu + systemd | سرویس‌های پایدار پس از Reboot |
| nginx **یا** HAProxy مالک 443 | Installer توپولوژی را تشخیص می‌دهد؛ nginx باید `http_auth_request_module` داشته باشد (بسته استاندارد دیبیان/اوبونتو دارد) |
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
| 443 (موجود) | nginx-direct: vhost جدید nginx — یا HAProxy: ACL مدیریت‌شده SNI/Host |
| 80 (موجود) | redirect به HTTPS + مسیر ACME HTTP-01 (در HAProxy: ACL مدیریت‌شده acme در صورت نیاز به صدور) |
| 7680 / 7681 / 7682 | فقط **127.0.0.1** (nginx داخلی / ttyd / gateway) — از بیرون قابل دسترسی نیستند |

## دستور نصب (Owner — به‌عنوان root روی VPS)

```bash
rm -rf /tmp/hanaso-ops-install
git clone --depth 1 --branch v1.1.0 https://github.com/AbolfazlProg/hanaso-ops-terminal.git /tmp/hanaso-ops-install
cd /tmp/hanaso-ops-install
sha256sum -c SHA256SUMS        # بررسی یکپارچگی فایل‌ها
bash scripts/install.sh --yes
```

- اگر Repository خصوصی است، ابتدا آن را عمومی کنید (این پروژه Secret ندارد):
  `gh repo edit AbolfazlProg/hanaso-ops-terminal --visibility public` یا از Settings در وب.
- **رمز پنل یک بار در پایان نصب نمایش داده می‌شود** — همان لحظه ذخیره کنید و خروجی را به فایل نریزید.

پس از نصب: `https://ops.hanaso.ir` → ورود → ترمینال ROOT واقعی.

## Installer چه کار می‌کند (به ترتیب)

1. **Preflight فقط-خواندنی**: توپولوژی 80/443 (`ss -tlnp`)، ماژول auth_request، پورت‌های آزاد، DNS، گواهی موجود، تداخل vhost. خروجی machine-readable با فرمت امن KEY='VALUE' نوشته و با پارسر سخت‌گیرانه خوانده می‌شود (**هرگز source نمی‌شود** — درس حادثه 2026-11-16).
2. **Backup** از وضعیت فعلی → `/var/backups/ops-terminal/<timestamp>/` (در توپولوژی HAProxy شامل کپی مستقل `haproxy.cfg`).
3. نصب ttyd 1.7.7 (SHA256-verified) + Gateway + ابزارها در `/opt/ops-terminal`.
4. کاربر سیستمی `ops-gw` (بدون shell) برای Gateway و nginx داخلی؛ فقط ttyd با root اجرا می‌شود.
5. تولید Credential تصادفی ۲۴ کاراکتری (PBKDF2، فایل 0600) + کلید Session مستقل.
6. سرویس‌های systemd (`ops-terminal-gateway`، `ops-terminal` و در توپولوژی HAProxy `ops-terminal-nginx`) — `enable --now`.
7. **TLS**: گواهی موجود پوشش‌دهنده → استفاده مجدد؛ وگرنه certbot (HTTP-01 webroot) برای ops.hanaso.ir.
8. **سیم‌کشی Reverse Proxy** — بر اساس توپولوژی:
   - *nginx-direct*: فایل vhost مستقل + symlink؛ `nginx -t` → فقط **reload**.
   - *haproxy-front*: گواهی پنل به HAProxy (crt-dir / crt-list / تبدیل برگشت‌پذیر crt→crt-list) + بلوک‌های مدیریت‌شده `# BEGIN/END ops-terminal` (ACL SNI/Host + backend با حذف XFF جعلی و HSTS)؛ `haproxy -c` → فقط **reload** (هرگز restart)؛ nginx مشترک HANASO/KOTODAMA دست نمی‌خورد.
9. **تست انتها-به-انتهای خودکار** (login → WebSocket → اجرای `id -u` با انتظار خروجی `0`)؛ در صورت شکست: **Rollback خودکار** (حذف جراحی بلوک‌ها + بازگردانی bind گواهی + reload اعتبارسنجی‌شده).
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
systemctl stop ops-terminal ops-terminal-gateway                # توقف (tmux session زنده می‌ماند)
systemctl start ops-terminal-gateway ops-terminal               # شروع (tmux دوباره attach می‌شود)
# در توپولوژی HAProxy این دو را هم اضافه کنید:
systemctl stop ops-terminal-nginx && systemctl start ops-terminal-nginx
bash /tmp/hanaso-ops-install/scripts/uninstall.sh --yes          # حذف کامل هر دو توپولوژی
```

## نصب مجدد (Idempotent)

اجرای مجدد Installer فقط فایل‌ها را به‌روز می‌کند؛ Credentialهای موجود حفظ می‌شوند مگر `--reset-credentials` بدهید.

## توپولوژی HAProxy (توپولوژی واقعی این VPS)

اگر HAProxy روی 443 باشد، Installer به‌جای توقف، مسیر امن HAProxy را اجرا می‌کند:

| مرحله | رفتار |
|--------|-------|
| تحلیل config | frontend/listen مالک `:443`، نوع bind (ssl یا TCP passthrough)، سبک `crt` (dir/file/crt-list)، مکانیزم reload (systemd یا pidfile SIGUSR2) |
| شرط اکید | `haproxy -c` روی config فعلی باید **قبل از هر تغییری** پاس شود؛ اگر reload امن وجود نداشته باشد، نصب بدون هیچ تغییر متوقف می‌شود |
| گواهی پنل | `dir`: PEM در دایرکتوری crt موجود (بدون ویرایش bind) — `crt-list`: append به لیست موجود — `file`: تبدیل **برگشت‌پذیر** `crt FILE` → `crt-list` که خط اول آن گواهی اصلی است |
| مسیریابی | بلوک مدیریت‌شده در همان frontend: `acl OPS_TERM_SNI ssl_fc_sni` + `hdr(host)` + `use_backend OPS_TERM_BACKEND` — فقط دامنه پنل؛ بقیه دامنه‌ها همان مسیر قبلی خود را می‌روند |
| backend | `127.0.0.1:7680` (nginx داخلی) + `http-request del-header/add-header X-Forwarded-For` (حذف XFF جعلی کاربر) + HSTS + timeout تونل ۷ روز برای WebSocket |
| اعمال تغییر | `haproxy -c` → reload (systemd یا SIGUSR2) → اثبات اینکه پورت 443 هنوز پاسخ می‌دهد |
| ACME | اگر certbot لازم شود و :80 هم HAProxy باشد، ACL مدیریت‌شده `acme-challenge` + backend موقت وب‌روت اضافه و پس از صدور، هوک تمدید گواهی نصب می‌شود |
| Rollback/Uninstall | حذف جراحی بلوک‌های `BEGIN/END ops-terminal`، بازگردانی bind به گواهی اصلی، حذف PEM/crtlist خود پنل، `haproxy -c` و reload مجدد |

پورت‌های پنل در این توپولوژی فقط روی 127.0.0.1 هستند (7680/7681/7682) و هیچ پورت عمومی جدیدی باز نمی‌شود.
