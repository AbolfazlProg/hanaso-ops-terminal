# عیب‌یابی HANASO OPS Web Terminal

## اولین دستورات

```bash
bash /opt/ops-terminal/health-check.sh           # وضعیت کلی (آگاه از توپولوژی)
systemctl status ops-terminal ops-terminal-gateway
# در توپولوژی HAProxy این را هم اضافه کنید:
systemctl status ops-terminal-nginx haproxy
journalctl -u ops-terminal-gateway -n 50         # رویدادها + خطاها
tail -50 /var/log/ops-terminal/gateway.log      # LOGIN_OK/FAIL/BLOCKED
ss -tlnp | grep -E ':(7680|7681|7682)'           # باید فقط 127.0.0.1 باشند
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

## حادثه 2026-11-16 — درس‌های ثبت‌شده (در این نسخه رفع شده)

### ۱) «172.18.0.1: command not found» در میانه نصب

**نشانه:** نصب بعد از Preflight با FATAL و rollback زودهنگام متوقف شد؛ در لاگ: `/tmp/ops-preflight.env: line 22: 172.18.0.1: command not found`.

**ریشه:** فایل env قبلاً با مقادیر UNQUOTED نوشته می‌شد و Installer آن را `source` می‌کرد؛ مقدار چندکلمه‌ای `PREFLIGHT_HOST_IPS="87.107.129.210 172.18.0.1"` کلمه دومش به‌عنوان دستور اجرا می‌شد.

**رفع:** فایل env حالا با سریال‌سازی امن single-quote نوشته می‌شود (`scripts/ops-env.sh`) و Installer آن را **هرگز source/eval نمی‌کند** — پارسر خط‌به‌خط با whitelist سخت‌گیرانه و fail-closed برای کلید ناشناخته.

### ۲) مرورگر به `http://ops.hanaso.ir:7680/login` می‌رود (فقط توپولوژی HAProxy)

**نشانه:** مراجعه به پنل → ریدایرکت به یک URL روی پورت 7680 که فقط loopback است → اتصال از بیرون ممکن نیست.

**ریشه:** پیش‌فرض `absolute_redirect` در nginx `return 302 /login` را با پورت خودِ listener داخلی مطلق می‌کند؛ پشت HAProxy این پورت عمومی نیست.

**رفع:** `absolute_redirect off;` در قالب nginx داخلی — ریدایرکت‌ها relative می‌مانند و مرورگر روی همان scheme/host/port اصلی می‌ماند.

### ۳) «unsupported crt style on the :443 bind: crt»

**نشانه:** نصب مجدد روی توپولوژی HAProxy با FATAL همان پیام.

**ریشه:** تحلیل مجدد bind، کلیدواژه خام (`crt`) را به‌جای سبک رزولوشن‌شده (`file/dir/crt-list`) به case می‌داد.

**رفع:** رزولوشن سبک از وضعیت فایل‌سیستم (دایرکتوری/فایل/کلیدواژه crt-list) دقیقاً مطابق Preflight، قبل از case؛ برای bind بدون crt هم پیام صریح.

### ۴) HAProxy — «config is already broken» یا شکست reload

- اگر `haproxy -c` روی config فعلی (قبل از تغییر) شکست بخورد، Installer **بدون هیچ تغییری** متوقف می‌شود — config را از backup اپراتور برگردانید.
- ویرایش‌های پنل فقط داخل بلوک‌های `# BEGIN/END ops-terminal` هستند؛ برای بازگشت دستی، مراحل `docs/ROLLBACK.md` (بخش haproxy-front) را اجرا کنید.
- Reload فقط با `systemctl reload haproxy` یا SIGUSR2 به pid خط اول `/run/haproxy.pid` انجام می‌شود — **هرگز restart**، چون restart همه اتصال‌های تونل سایت‌های دیگر را می‌بندد.

## حادثه 2026-11-17 (CP10) — درس‌های ثبت‌شده (در این نسخه رفع شده)

### ۱) «preflight env file failed strict validation» با `PREFLIGHT_CERT_PATH=''`

**نشانه:** روی VPS بدون گواهی موجود، Preflight مقدار خالی می‌نویسد و Installer با ردِ validation می‌میرد — با اینکه regex کلید با `*` خالی را مجاز می‌دانست.

**ریشه:** اعتبارسنج با `printf '%s' "$val" | grep -qE` کار می‌کرد؛ grep روی **ورودی صفر-بایتی هیچ خطی برای match ندارد** و هرگز rc=0 نمی‌دهد — حتی برای `^...*$`. یعنی هیچ مقدار خالی در هیچ کلیدی هرگز قابل قبول نبود.

**رفع:** مقدار با یک newline اضافه به grep داده می‌شود تا خالی = یک خطِ خالی باشد؛ regexهای `*`-دار مقدار خالی را می‌پذیرند و `+`/لیترال‌ها همچنان رد می‌کنند (fail-closed دست‌نخورده — مسیر نامعتبر/دستکاری‌شده باز هم رد می‌شود).

### ۲) «http-request use-backend» — عبارت نامعتبر در HAProxy 2.x/3.x

**نشانه:** اولین تلاش واقعیِ افزودن مسیر ACME روی :80، در `haproxy -c` شکست خورد (اکشن `use-backend` در http-request وجود ندارد؛ فرم درست، کلیدواژه سطح frontend یعنی `use_backend ... if ...` است).

**رفع:** بلوک مدیریت‌شده ACME با `use_backend` بازنویسی شد؛ باتری CP10 (`tests/cp10-battery.sh`) حالا مسیر صدور گواهی را **واقعاً** اجرا می‌کند تا این کلاس باگ دیگر پنهان نماند.

### ۳) گم‌شدن مسیر ACME در نصب مجدد (renewal آینده می‌شکست)

**ریشه:** پاس idempotency بلوک‌های مدیریت‌شده را — شامل بلوک‌های acme نصب قبلی — حذف و فقط بلوک‌های اصلی را بازمی‌ساخت.

**رفع:** بعد از پاس idempotency، بلوک‌های ACME (در صورت وجود قبلی یا صدور در همین اجرا) بازافزوده می‌شوند؛ ریدایرکت idempotent دیگر renewal را silently نمی‌شکند.

### ۴) دو باگ نهفته دیگر در همان زنجیره

- بعد از صدور موفق، چک نهایی `[ -r "$TLS_CERT" ]` روی متغیر خالی می‌مرد (در توپولوژی haproxy متریال در `PANEL_PEM_SRC_*` است) — حتی نصب موفق هم die می‌شد.
- اعتبارسنجی جفت گواهی اکنون در **همه مسیرها** انجام می‌شود (خوانایی + انقضا ≥ ۲۴ ساعت + پوشش SAN دامنه + تطابق کلید) و صدور ناموفق → **TLS GATE** امن فقط-loopback.

## حادثه 2026-11-17 (CP11) — شکست Systemd/Nginx در Production (در این نسخه رفع شده)

سه یافته از Diagnostic واقعی VPS — هر سه در نسخه v1.2.2 رفع شده‌اند:

### ۱. «pid directive is duplicate in nginx.conf:5»

**علت ریشه‌ای:** Unit سرویس PID را دو جا تعریف می‌کرد — داخل خود nginx.conf (خط ۵) و روی خط فرمان ExecStart با `-g 'pid …;'`. nginx هنگام parse دومی را duplicate می‌بیند و بلافاصله خارج می‌شود.

**رفع:** PID فقط یک مرجع دارد — `pid` فقط در nginx.conf. ExecStart/ExecReload دیگر `-g` ندارند:

```bash
# Unit فعلی (درست):
ExecStartPre=/usr/sbin/nginx -c /etc/ops-terminal/nginx/nginx.conf -e stderr -t
ExecStart=/usr/sbin/nginx     -c /etc/ops-terminal/nginx/nginx.conf -e stderr
ExecReload=/usr/sbin/nginx    -c /etc/ops-terminal/nginx/nginx.conf -e stderr -s reload
```

**درس تست:** `nginx -t` بدون آرگومان‌های systemd (حتی به‌عنوان root) این باگ را «سبز» می‌کند — چون `-g` فقط در ExecStart است. معیار پذیرش Production-like فقط اجرای همان ExecStart با همان هویت سرویس است.

### ۲. «could not open error log file: open() "/var/log/nginx/error.log" failed (13: Permission denied)»

**علت ریشه‌ای:** nginx مسیر لاگ خطای کامپایل‌شده را **قبل از parse پیکربندی** باز می‌کند. با کاربر غیر-root (`ops-gw`) این باز شدن روی لاگ مشترک nginx شکست می‌خورد.

**رفع:** `-e stderr` در ExecStart/ExecReload — لاگ اولیه به stderr می‌رود و journald آن را ثبت می‌کند (`journalctl -u ops-terminal-nginx`). هیچ مجوزی به `/var/log/nginx` مشترک داده نمی‌شود. لاگ پس-از-parse فقط زیر `/var/log/ops-terminal` است. برای همان خطای زودهنگام روی unit، `journalctl -u ops-terminal-nginx -n 50` را ببینید.

### ۳. حلقه بی‌نهایت Restart (شمارنده ۹۷۲)

**علت ریشه‌ای:** `Restart=always` + `RestartSec=2` بدون `StartLimitIntervalSec`/`StartLimitBurst` → خطای پیکربندی دائمی = restart بی‌پایان هر ۲ ثانیه.

**رفع (هر سه unit):** `Restart=on-failure` + `RestartSec=3` + `StartLimitIntervalSec=120` + `StartLimitBurst=5` — بعد از ۵ شکست در بازه ۱۲۰ ثانیه، unit به حالت failed می‌رود و **DOWN می‌ماند**.

```bash
systemctl status ops-terminal-nginx        # NRestarts / Result
systemctl reset-failed ops-terminal-nginx  # فقط بعد از رفع علت!
journalctl -u ops-terminal-nginx --since -10min
```

### اصلاحات پشتیبانی در همین CP

* `daemon off;` در conf اصلی nginx داخلی → master در foreground می‌ماند و Type=simple واقعاً MainPID را دنبال می‌کند.
* `ExecStartPre` قبل از هر start همان پیکربندی را با هویت سرویس `nginx -t` می‌کند؛ پیکربندی خراب هرگز وارد حلقه restart نمی‌شود.
* مالکیت: `/etc/ops-terminal/nginx` → `root:ops-gw` (سرویس فقط می‌خواند)، `/var/lib/ops-terminal/nginx` و `/var/log/ops-terminal` → `ops-gw`.
* Rollback شکست نصب فقط unitهای خود پنل را متوقف می‌کند (`scripts/ops-systemd.sh`)، حلقه restart را می‌شکند (`kill` + `reset-failed`)، فایل‌های unit را حذف و بلوک‌های مدیریت‌شده HAProxy را state-independent جارو می‌کند — سرویس‌های مشترک KOTODAMA/HANASO دست‌نخورده می‌مانند.

## نکته درباره قطع و وصل

قطع مرورگر Session را نمی‌بندد: tmux session «ops» روی سرور زنده می‌ماند و با بازگشت، همان‌جا ادامه می‌یابد. اگر Session تازه می‌خواهید داخل ترمینال `exit` بزنید.

## وقتی هیچ‌کارات جواب نداد

`docs/ROLLBACK.md` را اجرا کنید (حذف کامل پنل، بدون دست زدن به سرویس‌های مشترک) و لاگ نصب را نگه دارید: `/var/backups/ops-terminal/`.
