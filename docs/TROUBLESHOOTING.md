# عیب‌یابی HANASO OPS Web Terminal

## اولین دستورات

```bash
bash /opt/ops-terminal/health-check.sh           # وضعیت کلی
systemctl status ops-terminal ops-terminal-gateway
journalctl -u ops-terminal-gateway -n 50         # رویدادها + خطاها
tail -50 /var/log/ops-terminal/gateway.log      # LOGIN_OK/FAIL/BLOCKED
ss -tlnp | grep -E ':(7681|7682)'               # باید فقط 127.0.0.1 باشند
```

## جدول نشانه → علت → راه‌حل

| نشانه | علت محتمل | راه‌حل |
|-------|-----------|--------|
| بعد از ورود، صفحه ترمینال خالی می‌ماند | WebSocket از nginx رد نشده | `nginx -t`؛ مطمئن شوید vhost ما reload شده؛ لاگ error پنل: `/var/log/nginx/ops-terminal.error.log` |
| خطای 423 هنگام ورود | IP در قفل Brute-force | ۱۵ دقیقه صبر؛ یا پاک‌سازی: در `/var/lib/ops-terminal/state.json` کلیدهای `locked_until`/`fail_counts` را صفر کنید و gateway را restart کنید |
| خطای 429 روی /login | محدودیت nginx rate-limit | چند ثانیه صبر (۲۴ درخواست در دقیقه با burst) |
| «login must go over https» | درخواست HTTP مستقیم به gateway | فقط از `https://ops.hanaso.ir` استفاده کنید |
| صدور گواهی شکست خورد (نصب) | DNS هنوز به VPS اشاره نمی‌کند یا پورت 80 بلاک | رکورد A → IP VPS (DNS Only)؛ `curl -I http://ops.hanaso.ir/.well-known/acme-challenge/test` از بیرون تست کنید؛ سپس Installer را دوباره اجرا کنید |
| پس از restart سرور پنل بالا نیست | systemd | `systemctl start ops-terminal-gateway ops-terminal`؛ journalctl را ببینید |
| Session ترمینال گیر/خراب شده | tmux session قدیمی | `TMUX_TMPDIR=/var/tmp/ops-terminal tmux kill-server` → اتصال بعدی Session تازه می‌سازد |
| ttyd بالا نیست | پورت 7681 مشغول بوده هنگام نصب | `ss -tlnp | grep 7681`؛ سرویس متعارف را پیدا کنید یا پورت را در env عوض کنید و vhost را دوباره رندر کنید |
| پنل باز است ولی دستور اجرا نمی‌شود | ترمینال readonly شده | سرویس باید با `-W` اجرا شود (unit ما دارد)؛ `systemctl cat ops-terminal` را چک کنید |

## نکته درباره قطع و وصل

قطع مرورگر Session را نمی‌بندد: tmux session «ops» روی سرور زنده می‌ماند و با بازگشت، همان‌جا ادامه می‌یابد. اگر Session تازه می‌خواهید داخل ترمینال `exit` بزنید.

## وقتی هیچ‌کارات جواب نداد

`docs/ROLLBACK.md` را اجرا کنید (حذف کامل پنل، بدون دست زدن به سرویس‌های مشترک) و لاگ نصب را نگه دارید: `/var/backups/ops-terminal/`.
