# نصب HANASO OPS Web Terminal (Production — روی VPS)

راهنمای نصب واقعی روی سرور. برای روش آزمایش در Sandbox، [`tests/SANDBOX_TEST_REPORT.md`](../tests/SANDBOX_TEST_REPORT.md) و باتری HAProxy (`tests/haproxy-battery.sh`) را ببینید.

## نصب تک‌خطی (Quick Install)

روی VPS به‌عنوان root:

```bash
curl -fsSL https://raw.githubusercontent.com/AbolfazlProg/hanaso-ops-terminal/main/quick-install.sh \
  | bash -s -- --domain ops.hanaso.ir --acme-email admin@hanaso.ir
```

بوت‌استرپ `quick-install.sh` (در ریشه مخزن) این کارها را انجام می‌دهد:

1. مخزن را با `git clone --depth 1` می‌گیرد (در نبود git، tarball از codeload.github.com).
2. مانیفست `SHA256SUMS` درختِ دریافتشده را راستی‌آزمایی می‌کند — ناهمخوانی = توقف (**fail-closed**).
3. بدون root اجرا نمی‌شود، مگر اینکه `--sandbox` (حالت آزمایش بدون دسترسی root) پاس شده باشد.
4. `scripts/install.sh` را با همه آرگومان‌ها **عیناً** اجرا می‌کند (پرسش تعاملی تأیید روی TTY کار می‌کند).

تنظیمات خود بوت‌استرپ فقط از طریق متغیرهای محیطی (هیچ فلگی را مصرف نمی‌کند):

| متغیر | پیش‌فرض | شرح |
|-------|---------|------|
| `QUICK_INSTALL_REPO` | مخزن رسمی پروژه | URL گیت یا `OWNER/REPO` |
| `QUICK_INSTALL_REF` | `main` | شاخه یا Tag (مثلاً `v1.0.0`) |
| `QUICK_INSTALL_SKIP_SHA` | خالی | `1` = رد شدن از راستی‌آزمایی SHA256SUMS (توصیه نمی‌شود) |

**پین‌کردن به نسخه منتشرشده (توصیه‌شده برای VPS)** — به‌جای شاخه `main`، خود URL خام را به Tag پین کنید:

```bash
curl -fsSL https://raw.githubusercontent.com/AbolfazlProg/hanaso-ops-terminal/v1.3.1/quick-install.sh \
  | bash -s -- --domain ops.hanaso.ir --acme-email admin@hanaso.ir
```

> نکته: CDN خام (`raw.githubusercontent.com`) تا ~۵ دقیقه بعد از یک Push جدید ممکن است نسخه قبلیِ شاخه `main` را سرو کند؛ URL تگ‌دار همیشه پایدار و تغییرناپذیر است.

> **نکته امنیتی:** `curl | bash` به GitHub و TLS اعتماد می‌کند. برای نصب کاملاً پین‌شده و قابل‌بازبینی، مخزن را Clone کنید، `SHA256SUMS` را خودتان چک کنید و `scripts/install.sh` را مستقیم اجرا کنید (ادامه همین سند).


## موتور کشف و Fallback آینه‌های APT (جدید در v1.3.1)

در نصب standalone، فاز نصب وابستگی‌ها (`nginx`، `certbot`، `tmux`) از `scripts/ops-apt-mirror.sh` استفاده می‌کند. درس حادثه Production: در Ubuntu 24.04 وقتی Mirror در دسترس نیست (یا sources خالی است)، `apt-get update` با **کد خروج 0** خارج می‌شود و `apt-get install` با `E: Unable to locate package` می‌میرد — پس کد خروج هرگز مدرک سلامت Mirror نیست.

ترتیب داوری Mirrorها (همه با «موفقیت واقعی APT»):

1. پیکربندی فعلی apt (اگر از آزمون واقعی عبور کند، هیچ تغییری انجام نمی‌شود)
2. سرویس رسمی Mirror Discovery — `https://mirrors.ubuntu.com/mirrors.txt` (مرتب بر اساس جغرافیای سرور)
3. رجیستری رسمی Launchpad — `https://launchpad.net/ubuntu/+archivemirrors`
4. فهرست ثابت fallback (فقط Mirrorهای رسمی Canonical و ثبت‌شده در Launchpad)

هر Mirror در سه گام واقعی آزموده می‌شود: واکشی `InRelease` → اجرای `apt-get update` **ایزوله** (فهرست‌های موقت؛ اعتبارسنجی امضا توسط خود apt-secure؛ بدون `trusted=yes` و بدون دورزدن GPG) → وجود Candidate همه بسته‌های موردنیاز از همان فهرست تازه. اولین Mirror سبز برنده است؛ دلیل رد شدن هر Mirror در گزارش ثبت می‌شود.

گزارش اجرا در انتهای لاگ نصب با پیشوند `[apt-mirror]` و در فایل `apt-mirror-report.txt` داخل دایرکتوری Backup بایگانی می‌شود (فهرست Mirrorهای آزموده‌شده، دلیل رد شدن هرکدام، Mirror انتخابی، زمان `apt-get update`، نسخه Candidateها و نتیجه تست زنده auth_request). هیچ Secretی در لاگ نمی‌رود.

تغییرات apt فقط روی مخازن Ubuntu انجام می‌شود (خطوط `archive.ubuntu.com`/`security.ubuntu.com`/`*.archive.ubuntu.com` و Mirrorهای محلی `file:`/`copy:` و hostهای اعلامی با متغیر زیر)؛ مخازن third-party (Docker و…) دست‌نخورده می‌مانند. از فایل‌های اصلی قبل از هر تغییری در `<backup>/apt-backup/` نسخه برداری می‌شود و Rollback نصب، apt sources را هم برمی‌گرداند. قالب deb822 (`ubuntu.sources` در Ubuntu 24.04+) و قالب تک‌خطی هر دو پشتیبانی می‌شوند؛ فایل نوشته‌شده هرگز `trusted=yes` ندارد و امضاها با keyring رسمی Ubuntu پین می‌شوند.

متغیرهای محیطی (فقط برای موارد خاص):

| متغیر | کاربرد |
|---|---|
| `OPS_APT_UPDATE_TIMEOUT` | Timeout هر `apt-get update` (پیش‌فرض ۱۲۰ ثانیه) |
| `OPS_APT_PROBE_TIMEOUT` | Timeout واکشی InRelease (پیش‌فرض ۱۲ ثانیه) |
| `OPS_APT_MAX_MIRRORS` | سقف کاندیدها پس از کشف (پیش‌فرض ۱۰) |
| `OPS_APT_EXTRA_UBUNTU_HOSTS="host1 host2"` | اگر Provider شما Mirror سفارشی Ubuntu با host غیراستاندارد دارد، آن را اعلام کنید تا مثل مخازن OS مدیریت شود (بدون اعلام، hostهای ناشناخته دست‌نخورده می‌مانند) |

## نصب مستقل روی Ubuntu تازه (standalone — v1.3.0؛ موتور Mirror از v1.3.1)

سرور مقصد فقط باید این‌ها را داشته باشد: Ubuntu 22.04/24.04، دسترسی root، systemd فعال و DNS که
`ops.hanaso.ir` به **همان سرور** اشاره می‌کند (A record — DNS Only). **هیچ‌کدام از این‌ها پیش‌نیاز نیست:**
nginx، ماژول auth_request، Certbot، Listener مناسب HTTPS، گواهی TLS موجود، وب‌روت موجود، tmux، curl.

دستور نصب (روی VPS، به‌عنوان root):

```bash
curl -fsSL https://raw.githubusercontent.com/AbolfazlProg/hanaso-ops-terminal/v1.3.1/quick-install.sh \
  | QUICK_INSTALL_REF=v1.3.1 bash -s -- --domain ops.hanaso.ir --yes
```

Installer در توپولوژی standalone این ۱۳ گام را خودش انجام می‌دهد:

1. **Preflight** — نسخه/معماری Ubuntu، آزاد بودن :80/:443/:7680/:7681/:7682، apt، systemd، python3 — و **دروازه DNS**:
   اگر دامنه به این سرور اشاره نکند، Installer **قبل از هر تغییری** متوقف می‌شود (بدون هیچ اثر جانبی).
2. **نصب وابستگی‌ها با apt** — بسته توزیع `nginx` (ماژول auth_request با `nginx -V` به‌صورت fail-closed اثبات می‌شود) و `certbot`؛ اگر یک باینری nginx «خارجی» بدون auth_request موجود باشد، فقط در صورت غیرفعال/تعلق‌نداشتن به dpkg کنار گذاشته می‌شود (Backup در `/var/backups/ops-terminal/`) وگرنه Installer می‌ایستد.
3. سرویس `nginx.service` توزیع **disable** می‌شود — مالک انحصاری لبه، unit اختصاصی خود پنل است.
4. دایرکتوری‌ها و مجوزها — `/opt/ops-terminal`، `/etc/ops-terminal`، `/var/{lib,log,tmp}/ops-terminal`، `/run/ops-terminal`، کاربر سیستم `ops-gw` (بدون shell)، وب‌روت `/var/www/ops-terminal`.
5. **Auth Gateway** — `ops-terminal-gateway.service` (کاربر ops-gw، hardening کامل).
6. **ttyd** — `ops-terminal.service` (root shell واقعی، فقط 127.0.0.1:7681، tmux «ops»).
7. **Systemd Units** — چهار unit (gateway/ttyd/nginx-داخلی/front) با سیاست Restart محدود (CP11: بعد از ۵ خطا در ۱۲۰ ثانیه unit می‌ایستد — حلقه Restart بی‌پایان غیرممکن است).
8. **nginx + WebSocket** — `ops-terminal-front.service` روی :80/:443 با `CAP_NET_BIND_SERVICE` (بدون root) و nginx داخلی روی 127.0.0.1:7680؛ upgrade طولانی‌مدت WS (timeout هفت‌روزه).
9. **صدور گواهی** — `certbot certonly --webroot -w /var/www/ops-terminal` از طریق Listener واقعی :80 خود پنل (فاز A) و سپس افزودن vhost :443 با یک reload اعتبارسنجی‌شده (فاز B).
10. **HTTPS فعال** — HSTS یک‌ساله، TLSv1.2/1.3، ریدایرکت 301 همه‌چیز به HTTPS.
11. **Renewal** — `certbot.timer` توزیع + هوک deploy که فقط `ops-terminal-front` را reload می‌کند.
12. **فعال‌سازی سرویس‌ها** — `systemctl enable --now` هر چهار unit (بقا بعد از reboot از طریق symlinkهای wants).
13. **Health Checks** — دروازه سلامت loopback، :80 → 301، :443 → 200 و در پایان **e2e کامل**: ورود واقعی → WebSocket → shell → خروجی `id -u` = 0.

حالت‌های جایگزین گواهی: `--tls-mode self-signed` (فقط محیط بسته/آزمایش — برای پنل عمومی استفاده نشود؛ با تایمر
`ops-terminal-tls-renew.timer` خودکار تمدید می‌شود) یا `--tls-cert/--tls-key` (جفت موجود).

Uninstall: `bash /root/hanaso-ops-terminal/scripts/uninstall.sh --yes` — فقط منابع متعلق به این پروژه را حذف می‌کند
(services/units/wants/فایل‌ها/وب‌روت/هوک LE/گواهی LE این دامنه/کاربر ops-gw). بسته‌های توزیع پیش‌فرض باقی می‌مانند؛
حذف آن‌ها اختیاری است: `--purge-packages`.

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
7. **TLS**: گواهی موجود پوشش‌دهنده → استفاده مجدد (با اعتبارسنجی مجدد در زمان نصب)؛ وگرنه certbot (HTTP-01 webroot) برای ops.hanaso.ir. **مقدار خالی `PREFLIGHT_CERT_PATH=''` (بدون گواهی موجود) یک وضعیت معمولی و معتبر است** — CP10.
   - مسیر صدور: مسیر مدیریت‌شده ACME روی frontend :80 HAProxy (`use_backend` داخل بلوک `# BEGIN/END ops-terminal acme`) → nginx داخلی → webroot؛ `haproxy -c` + reload قبل از فراخوانی certbot.
   - پس از صدور: خوانایی cert/key + انقضا ≥ ۲۴ ساعت + پوشش SAN دامنه + تطابق کلید با گواهی بررسی می‌شود؛ در webhook تمدید (renewal deploy hook) PEM مربوط به HAProxy خودکار بازسازی می‌شود.
   - نصب مجدد (idempotent) مسیر ACME را **بازمی‌سازد** تا renewalهای آینده silently نشکنند.
   - شکست صدور یا نبود certbot → **TLS GATE**: توقف امن فقط-loopback؛ هیچ بلوکی روی HAProxy باقی نمی‌ماند.
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
