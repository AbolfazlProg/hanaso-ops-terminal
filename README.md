# HANASO OPS Web Terminal

پنل ترمینال تحت وب با **ROOT Shell واقعی** برای VPS مشترک HANASO — پشت احراز هویت مستقل،
قفل Brute-Force و HTTPS — بدون وابستگی عملیاتی به GitHub Actions، SSH از بیرون یا Cloudflare Tunnel.

```
مرورگر (Agent/Owner)
   │  HTTPS (wss) — پورت 443 موجود Reverse Proxy
   ▼
Reverse Proxy فعلی سرور (Virtual Host اختصاصی ops.hanaso.ir)
   │  auth_request → کوکی Session امضاشده
   │  limit_req    → قفل Brute-Force
   ├──► 127.0.0.1:7682  ops-terminal-gateway  (Auth Gateway — Python stdlib، کاربر ops-gw)
   └──► 127.0.0.1:7681  ttyd 1.7.7 (کاربر root) → tmux session «ops» → ROOT Shell واقعی
```

## اجزای پروژه

| مسیر | شرح |
|------|------|
| `gateway/gateway.py` | احراز هویت مستقل (Login/Logout/Change-Password) + قفل IP + لاگ رویداد — فقط Python stdlib |
| `vendor/` | باینری ttyd 1.7.7 + SHA256SUMS رسمی upstream |
| `systemd/` | سرویس‌های `ops-terminal.service` (ttyd/root) و `ops-terminal-gateway.service` (ops-gw) |
| `nginx/` | قالب Virtual Host با auth_request، WebSocket proxy، timeout طولانی، limit_req |
| `scripts/install.sh` | Installer مستقل، Idempotent، با Preflight + Backup + Rollback خودکار |
| `scripts/uninstall.sh` | حذف کامل و مستقل بدون آسیب به سرویس‌های مشترک |
| `scripts/preflight.sh` | بررسی سازگاری VPS قبل از نصب (فقط-خواندنی) |
| `scripts/ops-terminal-passwd` | تولید/چرخش Credential بدون افشا در argv |
| `scripts/e2e-test.py` | تست انتها-به-انتها: Login → WebSocket → اجرای دستور → Assertion |
| `docs/` | مستندات نصب/حذف/عیب‌یابی/Rollback/Security |

## نصب سریع (Owner)

 دستور نهایی و تست‌شده در [`docs/INSTALL.md`](docs/INSTALL.md) ارائه شده است.
پیش‌نیاز: رکورد A برای `ops.hanaso.ir` به IP عمومی VPS (حالت DNS Only).

> ⚠️ این پنل ROOT Shell واقعی ارائه می‌کند. امنیت آن به کیفیت Credential، HTTPS و
> دسترسی محدود بستگی دارد. مستندات [`docs/SECURITY.md`](docs/SECURITY.md) را بخوانید.

## وضعیت

وضعیت لحظه‌ای پروژه: [`CURRENT_STATE.md`](CURRENT_STATE.md)
گزارش کامل تست Sandbox: [`tests/SANDBOX_TEST_REPORT.md`](tests/SANDBOX_TEST_REPORT.md)
