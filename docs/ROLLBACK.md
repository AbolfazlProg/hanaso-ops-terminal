# برنامه Rollback

## سطح ۱ — Rollback خودکار Installer

Installer با `trap ERR` کار می‌کند: هر شکست → توقف سرویس‌های خودش، حذف vhost نصب‌شده (یا بازگردانی Backup آن)، `nginx -t` → reload، حذف فایل‌های ساخته‌شده. Backupها در `/var/backups/ops-terminal/<timestamp>/` می‌مانند.

## سطح ۲ — حذف کامل پنل (Uninstaller)

```bash
bash scripts/uninstall.sh --yes          # یا --purge برای لاگ‌ها/Backupها هم
```
فقط فایل‌ها/سرویس‌های خود پنل را حذف می‌کند (systemd units، /opt/ops-terminal، /etc/ops-terminal، vhost nginx + symlink، کاربر ops-gw، tmux socket خودش) و در پایان `nginx -t` → reload. **هیچ سرویس مشترکی Restart نمی‌شود و هیچ vhost دیگری دست نمی‌خورد.**

## سطح ۳ — بازیابی دستی nginx در بدترین حالت

1. `rm /etc/nginx/sites-enabled/ops-terminal.conf` (و sites-available در صورت تمایل)
2. Backup قبلی لازم نیست (فایل مستقل بود) — ولی در `/var/backups/ops-terminal/` موجود است.
3. `nginx -t` → فقط در صورت OK: `systemctl reload nginx`
4. سایر vhostها (HANASO/KOTODAMA) از همان فایلهای خودشان سرویس می‌گیرند — تغییری در آن‌ها نداده‌ایم.

**اگر nginx اصلاً بالا نیامد (سناریوی فرضی):** فایل vhost پنل مستقل است؛ حذف آن کافی است. در ۱۲ سال nginx Debian، reload بعد از `nginx -t` موفق هرگز سرویس را نمی‌اندازد — ما هرگز Restart کامل نمی‌کنیم.

## سناریوهای خاص

| سناریو | اقدام |
|--------|-------|
| پس از نصب مشکل پیدا شد | `uninstall.sh --yes` → بررسی `nginx -t` → reload |
| صدور گواهی شکست خورد | Installer خودش در حالت loopback-only متوقف شده — چیزی عمومی نشده؛ DNS/وب‌روت را درست کنید و Installer را دوباره اجرا کنید |
| رمز گم شد | روی VPS: `ops-terminal-passwd --generate --print-once` |
| Session tmux خراب/گریزان شد | `TMUX_TMPDIR=/var/tmp/ops-terminal tmux kill-server` → اتصال بعدی Session تازه می‌سازد |
| کامل بازگشت به قبل از مأموریت | uninstall + حذف `/var/backups/ops-terminal` + حذف کلون `/tmp/hanaso-ops-install` — همین |
