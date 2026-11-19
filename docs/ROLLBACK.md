# برنامه Rollback

## سطح ۱ — Rollback خودکار Installer

Installer با `trap ERR` کار می‌کند: هر شکست → توقف سرویس‌های خودش، حذف vhost نصب‌شده (یا بازگردانی Backup آن)، `nginx -t` → reload، حذف فایل‌های ساخته‌شده. Backupها در `/var/backups/ops-terminal/<timestamp>/` می‌مانند.

**در توپولوژی HAProxy** rollback علاوه بر موارد بالا، ویرایش‌های `haproxy.cfg` را هم جراحی برمی‌گرداند:

1. حذف همه بلوک‌های `# BEGIN/END ops-terminal` (فقط خطوط خودِ پنل).
2. بازگردانی bind: اگر bind به `crt-list` تبدیل شده بود، به `crt <گواهی اصلی>` برمی‌گردد (خط اول crtlist همان گواهی اصلی است) و فایل crtlist/PEM پنل حذف می‌شود.
3. اگر PEM پنل به یک crt-list متعلق به اپراتور اضافه شده بود، فقط همان یک خط از لیست حذف می‌شود.
4. `haproxy -c` → در صورت OK فقط reload (systemd یا SIGUSR2)؛ در صورت شکست، بازگردانی کامل از `haproxy.cfg.bak` و reload.

Rollback **مستقل از metadata نسل فعلی نصب** است و وضعیت را از خود config جاری استخراج می‌کند — بنابراین روی «نصب مجدد روی تبدیل قبلی» هم صحیح کار می‌کند (تأییدشده در باتری HAProxy).

### CP11 — توقف قطعی unitهای خود پنل (قطع حلقه Restart)

از CP11 هر دو مسیر rollback (خودکار Installer و uninstaller) از `scripts/ops-systemd.sh` استفاده می‌کنند که **فقط unitهای متعلق به همین پنل** را با ترتیب امن متوقف می‌کند:

1. `systemctl disable --now ops-terminal.service ops-terminal-gateway.service ops-terminal-nginx.service`
2. اگر unit هنوز active بود (وسط RestartSec back-off): `kill --signal=SIGTERM` و در صورت نیاز `kill --signal=SIGKILL` — حلقه restart این‌جا قطع می‌شود.
3. `systemctl reset-failed` برای هر سه unit — حالت failed باقیمانده از StartLimit پاک می‌شود تا هیچ چیزی دوباره restart نکند.
4. حذف فایل‌های unit از `/etc/systemd/system` + `daemon-reload`.

سپس یک اظهار اطمینان (`systemd_panel_units_stopped`) چک می‌کند که هیچ unit پنل فعال نمانده است. سرویس‌های مشترک (nginx/haproxy مشترک، پنل‌های KOTODAMA/HANASO) در هیچ کدام از این گام‌ها لمس نمی‌شوند. همچنین بلوک‌های مدیریت‌شده HAProxy مستقل از وضعیت این run جارو می‌شوند — بقایای یک run قبلیِ کرش‌کرده هم حذف و با `haproxy -c` اعتبارسنجی و reload می‌شود.

## سطح ۲ — حذف کامل پنل (Uninstaller)

```bash
bash scripts/uninstall.sh --yes          # یا --purge برای لاگ‌ها/Backupها هم
```
فقط فایل‌ها/سرویس‌های خود پنل را حذف می‌کند (systemd units، /opt/ops-terminal، /etc/ops-terminal، vhost nginx + symlink، کاربر ops-gw، tmux socket خودش) و در پایان `nginx -t` → reload. **هیچ سرویس مشترکی Restart نمی‌شود و هیچ vhost دیگری دست نمی‌خورد.**

در توپولوژی HAProxy، uninstall همان رفتار rollback را روی `haproxy.cfg` دارد (حذف بلوک‌ها + بازگردانی bind + حذف PEM/crtlist + هوک تمدید گواهی + `haproxy -c` → reload) و unit `ops-terminal-nginx` را هم برمی‌دارد.

## سطح ۳ — بازیابی دستی reverse proxy در بدترین حالت

### nginx-direct

1. `rm /etc/nginx/sites-enabled/ops-terminal.conf` (و sites-available در صورت تمایل)
2. Backup قبلی لازم نیست (فایل مستقل بود) — ولی در `/var/backups/ops-terminal/` موجود است.
3. `nginx -t` → فقط در صورت OK: `systemctl reload nginx`
4. سایر vhostها (HANASO/KOTODAMA) از همان فایلهای خودشان سرویس می‌گیرند — تغییری در آن‌ها نداده‌ایم.

### haproxy-front

1. بلوک‌های بین `# BEGIN ops-terminal` تا `# END ops-terminal` را از `haproxy.cfg` حذف کنید (سه بلوک ممکن: ACL frontend، backend، ACME).
2. اگر bind به `crt-list /etc/haproxy/ops-terminal.crtlist` تبدیل شده: خط اول آن فایل گواهی اصلی است — bind را به `crt <همان مسیر>` برگردانید و فایل crtlist و `/etc/haproxy/certs/ops-terminal.pem` را حذف کنید.
3. `haproxy -c -f /etc/haproxy/haproxy.cfg` → فقط در صورت OK: `systemctl reload haproxy` (یا `kill -USR2 $(head -n1 /run/haproxy.pid)`).
4. نسخه قبل از تغییر همیشه در `/var/backups/ops-terminal/<timestamp>/haproxy.cfg.bak` موجود است.

**اگر nginx اصلاً بالا نیامد (سناریوی فرضی):** فایل vhost پنل مستقل است؛ حذف آن کافی است. در ۱۲ سال nginx Debian، reload بعد از `nginx -t` موفق هرگز سرویس را نمی‌اندازد — ما هرگز Restart کامل نمی‌کنیم. برای HAProxy هم همین اصل: ویرایش فقط بعد از `haproxy -c` و با reload.

## سناریوهای خاص

| سناریو | اقدام |
|--------|-------|
| پس از نصب مشکل پیدا شد | `uninstall.sh --yes` → بررسی `nginx -t` / `haproxy -c` → reload |
| صدور گواهی شکست خورد | Installer خودش در حالت loopback-only متوقف شده — چیزی عمومی نشده؛ DNS/وب‌روت را درست کنید و Installer را دوباره اجرا کنید |
| رمز گم شد | روی VPS: `ops-terminal-passwd --generate --print-once` |
| Session tmux خراب/گریزان شد | `TMUX_TMPDIR=/var/tmp/ops-terminal tmux kill-server` → اتصال بعدی Session تازه می‌سازد |
| قفل HAProxy: «config is already broken» | `haproxy.cfg` از قبل broken است — Installer دست نمی‌زند؛ config را اصلاح یا از backup برگردانید، بعد نصب |
| کامل بازگشت به قبل از مأموریت | uninstall + حذف `/var/backups/ops-terminal` + حذف کلون `/tmp/hanaso-ops-install` — همین |


### CP13 — رفتار Rollback در توپولوژی standalone

- ثبت کامل دایرکتوری‌های سطح‌بالا در `CREATED_PATHS` (اصلاح CP13): هر شکست بعد از اولین تغییر
  باعث حذف کامل `/opt/ops-terminal`، `/etc/ops-terminal`، `/var/{lib,log,tmp}/ops-terminal`،
  `/run/ops-terminal` و `/var/www/ops-terminal` می‌شود — باتری CP13 سناریوی D این را با
  «گواهی نامعتبر بعد از راه‌افتادن سرویس‌ها» اثبات می‌کند (پورت‌ها آزاد، unitها حذف، بدون هیچ
  پروسه باقی‌مانده).
- **بسته‌های توزیع** (nginx/certbot) عمداً نصب‌شده باقی می‌مانند و rollback با یک NOTE شفاف
  اعلام می‌کند (روی سرور اختصاصی بی‌ضرر است؛ حذف اختیاری: `apt-get purge nginx certbot`).
- ثبت هویت باینری nginx خارجیِ کنارگذاشته در `/var/backups/ops-terminal/<ts>/nginx-foreign/`.
