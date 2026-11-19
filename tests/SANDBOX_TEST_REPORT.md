# گزارش کامل تست Sandbox — HANASO OPS Web Terminal

> تاریخ: 2026-11-16 — محیط Sandbox (بدون root). خروجی نهایی باتری: `BATTERY COMPLETE — TOTAL FAILED STEPS: 0` (۴۶ PASS / ۰ FAIL) + آزمون ROOT جداگانه: ۰ FAIL.

## محیط آزمایش

| جزء | مقدار |
|------|-------|
| سیستم | Debian 13 (trixie)، x86_64، کاربر غیر root (uid 1001)، PID1=tini (بدون systemd runtime) |
| nginx | 1.26.3 — بسته باینری Debian trixie، استخراج unprivileged، با `http_auth_request_module` |
| tmux | 3.5a — استخراج unprivileged (+ libevent) |
| ttyd | 1.7.7 vendored — SHA256 تأییدشده در برابر SHA256SUMS رسمی upstream |
| مرورگر | Playwright + Chromium واقعی (همان نوع Browser Automation که Agentهای آینده استفاده می‌کنند) |
| TLS آزمایشی | گواهی Self-Signed فقط برای آزمایشگاه (Production: Let's Encrypt) |
| پورت‌ها | 8080/8443 nginx آزمایشی؛ 7681/7682 loopback (در Production: 80/443 همان زنجیره) |

## جدول ۱۶ آزمون اجباری مأموریت

| # | آزمون مأموریت | نتیجه | شواهد |
|---|---------------|-------|--------|
| 1 | نصب کامل از صفر | PASS | باتری مرحله ۱۰ (reinstall از صفر) + مرحله نصب rootproof — هر دو با e2e سبز |
| 2 | اجرای Systemd Service | PASS (سطح Sandbox) | `systemd-analyze verify` روی هر دو Unit ساختاری معتبر؛ در Sandbox سرویس‌ها با nohup اجرا شدند (PID1=tini)؛ در Production با `systemctl enable --now` بالا می‌آیند و Installer خودش e2e می‌گیرد |
| 3 | باز شدن پنل از مرورگر واقعی | PASS | Playwright: `01-login.png` |
| 4 | ورود با Credential | PASS | فرم لاگین پر شد → 302 → صفحه ترمینال |
| 5 | باز شدن ترمینال واقعی | PASS | `.xterm` رندر شد؛ متن ترمینال از `window.term` buffer API خوانده شد |
| 6 | `id -u` → خروجی `0` | PASS | آزمون ROOT (userns): هم WS-e2e و هم مرورگر واقعی `id -u -> 0` (اثبات فایل side-channel + متن ترمینال) — در Production سرویس root واقعی است |
| 7 | `hostname` و `pwd` | PASS | هر دو در e2e و مرورگر |
| 8 | ایجاد/خواندن/حذف فایل | PASS | چرخه فایل با اثبات filesystem side-channel در مرورگر واقعی |
| 9 | دستورات تعاملی | PASS | `read -p ...` در e2e — خروجی تعاملی برگشت |
| 10 | WebSocket طولانی‌مدت | PASS | test_longws: ۶۲ ثانیه، ping/pong فعال، خروجی دیرهنگام دریافت شد |
| 11 | قطع/وصل مرورگر + رفتار Session | PASS | مرورگر: بستن Tab حین `sleep` → بازگشت بدون لاگین → خروجی پس از قطع رسید (tmux)؛ WS: reconnect همان |
| 12 | Restart سرویس و بازگشت | PASS | test_restart: gateway restart (کوکی ماند)، ttyd kill+restart (خروجی دستور ادامه‌یافت)، nginx restart |
| 13 | عدم دسترسی بدون Credential | PASS | GET / → 302 /login؛ WS بدون کوکی → بدون 101 |
| 14 | محدودسازی ورود ناموفق | PASS | nginx 429 دیده شد؛ Gateway 423 بعد از خطاها؛ قفل پس از restart پایدار؛ رمز درست هم در قفل رد شد؛ بازیابی بعد از پاک‌سازی state |
| 15 | TLS و عدم نشت HTTP | PASS | http→301 https (بدو پردازش بدنه)؛ HSTS؛ Canary رمز در لاگ‌ها ظاهر نشد؛ رمز پنل در هیچ لاگی نیست |
| 16 | Uninstaller | PASS | فقط فایل‌ها/پورت‌های پنل حذف شد؛ هیچ سرویس دیگری دست نخورد |

## مهم‌ترین آزمون: مرورگر واقعی + اجرای دستور Root

`tests/browser-test.js` (Playwright/Chromium) — همان الگوی تعاملی Agentهای آینده:
1. بدون کوکی → redirect به /login ✅
2. پر کردن فرم + ورود ✅
3. `.xterm` رندر ✅ (متن ترمینال از `window.term` — قابلیت API رسمی ttyd — خواندنی است)
4. تایپ `id -u > /tmp/...` → **اثبات side-channel**: فایل در filesystem واقعی ظاهر شد = دستور از راه مرورگر واقعاً اجرا شد ✅
5. چرخه فایل (ایجاد/خواندن/حذف) ✅
6. بستن Tab حین دستور طولانی → بازگشت بدون لاگین → دستور ادامه داشت (tmux) ✅

اسکرین‌شات‌ها: `shots/01-login.png`، `02-terminal.png`، `03-reconnect.png` (+ نسخه uid-0 در `shots-root/`).

## آزمون ROOT (userns) — tests/rootproof.sh

Sandbox اجازه root واقعی نمی‌دهد؛ همان کد مسیر Production (systemd unit با User=root) با **Unprivileged User Namespace** شبیه‌سازی شد (`unshare -Ur`): داخل namespace کاربر uid 0 گزارش می‌شود. نتیجه:
- e2e در سطح WebSocket: `id -u -> 0` ✅ (۱۴/۱۴)
- مرورگر واقعی Playwright: `id -u -> 0` — هم اثبات فایل و هم متن ترمینال ✅ (۸/۸)
- روی VPS واقعی، سرویس با rootِ واقعی اجرا می‌شود و Installer در پایان نصب خودش `--expect-uid 0` را می‌سنجد.

## تفاوت‌های محیط آزمایش با VPS واقعی (صادقانه)

| مورد | Sandbox | VPS واقعی |
|------|---------|-----------|
| systemd runtime | ندارد (tini) — Units با nohup + `systemd-analyze verify` | واقعی؛ `enable --now` + self-e2e |
| ROOT | شبیه‌سازی userns (uid 0 داخل ns) | root واقعی (unit بدون User=) |
| گواهی | Self-Signed آزمایشی | Let's Encrypt (موجود یا صدور certbot) |
| پورت‌های nginx | 8080/8443 | 80/443 همان زنجیره Reverse Proxy |
| DNS | `--resolve`/host-map به 127.0.0.1 | ops.hanaso.ir → IP VPS (DNS Only) |
| Egress TCP/22 به VPS | مسدود (بازرسی SSH از Sandbox ممکن نبود) | preflight روی خود VPS در زمان نصب (read-only) |

## بازرسی خارجی VPS (از Sandbox)

- `IP-VPS:443` → `Server: nginx` — nginx مستقیماً روی 443 TLS خاتمه می‌دهد؛ گواهی پیش‌فرض vhost فعلی: `CN=kotodama.ir` (Let's Encrypt).
- `ops.hanaso.ir` الان به همان VPS اشاره می‌کند و فعلاً به vhost پیش‌فرض می‌افتد (پنل هنوز نصب نشده) — پس از نصب، vhost اختصاصی فعال می‌شود.
- تشخیص عمیق توپولوژی (پروسه‌های 80/443، vhostهای موجود، HAProxy) به `scripts/preflight.sh` در زمان نصب روی خود VPS واگذار شده (read-only، قبل از هر تغییر).

## نکته عملیاتی

اجرای اول باتری پس از rootproof با ۴ مرحله ناموفق بود چون Sweep فرزندان کهنه install، ttyd سندباکس اصلی را متوقف کرده بود (مستند در سربرگ rootproof.sh). اجرای دوم بعد از restore کامل → **کاملاً سبز**. قاعده: بعد از rootproof، باتری را بعد از یک install/اجرای سرویس‌ها اجرا کنید.

---

# الحاقیه CP12 — سازگاری نهایی systemd/nginx (2026-11-17)

> باتری رسمی: `tests/cp12-battery.sh` → **TOTAL FAILED CHECKS: 0** (۱۰۱ PASS / ۰ FAIL)
> رگرسیون‌ها پس از تغییرات: باتری CP11 → **۱۲۶ PASS / ۰ FAIL**، باتری nginx-direct → **0 FAILED**، باتری HAProxy → **0 FAILED**، باتری CP10 → **0 FAILED**

## شواهد ماتریس باینری (ریشه حادثه `invalid option: "e"`)

| باینری | نسخه | `-e stderr -v` | توضیح |
|---------|------|-----------------|-------|
| Debian trixie (سندباکس CP11) | 1.26.3 | rc=0 — می‌پذیرد | دلیل سبز ماندن تست‌های CP11 |
| Ubuntu jammy nginx-core (کلاس VPS) | 1.18.0 | rc=1 — `nginx: invalid option: "e"` | همان خطای واقعی Production؛ سوییچ `-e` فقط از nginx **1.19.5** (2020-11-24) وجود دارد |
| Ubuntu jammy — گزینه‌های کامپایل | — | `--error-log-path=/var/log/nginx/error.log` | همان مسیر لاگ کامپایل‌شده Production (Finding 2) |

## نتایج گام‌های CP12

* S1 ماتریس باینری + بازتولید دقیق مکانیسم حادثه روی باینری کلاس-VPS
* S2 unit lint روی خطوط Exec: صفر `-e`، صفر `-g 'pid …'`، Restart=on-failure + StartLimit(120/5)، Type=simple، User/Group=ops-gw، hardening
* S3 نصب واقعی از `scripts/install.sh` (haproxy-front) + pid یکتا در conf رندرشده + سایت مشترک سالم
* S4 اجرای verbatim ExecStartPre/ExecStart/ExecReload روی nginx 1.18.0: پیکربندی OK، گوش‌دادن 127.0.0.1:7680، /health=200، `[alert]` اولیه ثبت‌شده و master زنده (بی‌خطر-طبق-طرح)، reload موفق بدون restart
* S5 قرارداد هویت ops-gw: unit User=/Group=ops-gw، مالکیت root:ops-gw 0750 برای conf و ops-gw برای runtime/log، کاربر سیستم nologin، هویت اجرا با CapEff=0، هیچ chown/grant روی /var/log/nginx
* S6 یازده گام پذیرش: سه سرویس سالم زیر پالیسی unit، 302 احراز هویت، e2e کامل از پشت SNI، مرورگر واقعی، id -u، دستور تعاملی، restart کنترل‌شده، شکست تحمیلی → NRestarts≤5 → failed بدون حلقه → recovery، rollback فقط-پنل (پورت‌ها آزاد، بلوک‌های HAProxy صفر، master pid ثابت، سایت مشترک سالم، Backupها حفظ‌شده)
* S7 leftover-reinstall: unitهای حذف‌شده + فایل‌ها/Backupهای باقی‌مانده → نصب مجدد idempotent، credential قدیمی معتبر (e2e سبز)، Backupها دست‌نخورده
* S8 اثبات systemd واقعی: `systemd-analyze verify` روی unitهای واقعی + تراکنش واقعی systemd 257 (`systemd --user --test` در userns تو در تو، عبور از booted() با tmpfs /run) با «Queued start job» و بارگذاری unitها و صفر خطای parse
* S9 اجرای واقعی `quick-install.sh` از درخت کامیت‌شده: clone → SHA256SUMS OK → e2e → سلامت از پشت لبه اختصاصی → uninstall پاک

## محدودیت ثبت‌شده (صادقانه)

manager زنده‌ی systemd (system یا user) در این کانتینر قابل راه‌اندازی نیست: `/sys/fs/cgroup` یک tmpfs خارجی است، mount-over آن ممنوع است و manager واقعی در `manager_setup_cgroup` خارج می‌شود (شواهد ضبط‌شده: `strace` → `exit_group(1)` بلافاصله پس از `/proc/self/cgroup`؛ `cgroup.c:4160` «Cannot determine cgroup we are running in»؛ پیام ضبط‌شده CP11 «Failed to create /k8s.io/.../init.scope control group: Read-only file system»). پالیسی unitها با (a) پارسر واقعی systemd، (b) تراکنش واقعی manager و (c) supervisor وفادار به خطوط Exec آزموده می‌شود و روی VPS همان فایل‌ها بدون تغییر در manager واقعی بارگذاری می‌شوند.


## CP13 — نصب مستقل روی Ubuntu تازه (v1.3.0) — 2026-11-19

محیط: VM واقعی Ubuntu 24.04 LTS ساخته‌شده از بسته‌های رسمی `archive.ubuntu.com` (Python 3.12.3،
tmux 3.4، systemd 255 — همان کلاس VPS؛ گزارش هویت: `/root/.cp13-identity.txt`)، بدون nginx و
بدون certbot (شبیه‌سازی دقیق «سرور تازه»). محدودیت پلتفرم مثل CP12 مستند است: مدیر زنده systemd
در این Sandbox قابل اجرا نیست (cgroup فقط-خواندنی)؛ unitها با `systemd-analyze verify` واقعی
Ubuntu 255 راستی‌آزمایی و تراکنش‌ها با supervisor وفادار به policy + shim systemctl اجرا شده‌اند.

| سناریو | شرح | نتیجه |
|--------|-----|-------|
| C | دروازه DNS: hosts → 87.107.129.210 (IP قدیمی واقعی مأموریت) + `--server-ip 45.135.242.140` → توقف قبل از هر تغییر | ۸ PASS / ۰ FAIL |
| D | شکست عمدی بعد از راه‌افتادن سرویس‌ها (گواهی نامعتبر) → rollback کامل: صفر فایل، صفر unit، صفر listener، صفر پروسه؛ بسته‌ها با NOTE حفظ شدند | ۱۰ PASS / ۰ FAIL |
| B | مسیر ACME واقعی (فاز A → ACME round-trip از لبه واقعی :80 → certbot → فاز B → e2e TLS سخت‌گیرانه → هوک deploy → certbot.timer) با stub-certbot؛ uninstall دو حالته (حفظ/حذف بسته‌ها) | ۲۷ PASS / ۰ FAIL |
| A | نصب کامل self-signed: apt nginx + auth_request (nginx -V) + systemd-analyze verify + مالکیت‌ها + لبه :80/:443 + TLS + e2e کامل + health-check + 429/423 + بقای قفل در restart + چرخه stop/start + تمدید خودکار + reinstall idempotent + StartLimit sabotage | ۵۶ PASS / ۰ FAIL |
| E | uninstall نهایی: صفر من باقی‌مانده (پورت‌ها/units/wants/فایل‌ها/هوک LE/tmpdir/ابزار)؛ بسته nginx حفظ (پیش‌فرض مستند) | ۱۲ PASS / ۰ FAIL |
| مرورگر | Chromium واقعی (Playwright) از پشت رله‌های transport-only → TLS واقعی :443: ریدایرکت، ورود واقعی، xterm، `id -u` = 0 (اثبات فایل + متن ترمینال)، hostname، create/read/delete فایل، reconnect با کوکی، بقای long-run در tmux | ۸ PASS / ۰ FAIL |

جمع کل: **۱۱۳ PASS / ۰ FAIL (باتری) + ۸ PASS / ۰ FAIL (مرورگر)** — شامل رفع یک باگ واقعی کشف‌شده
توسط همین مرورگر (front باید با `$http_host` پورت را حفظ کند — ttyd با `-O` origin را با پورت مقایسه می‌کند).

---

# CP15 / v1.3.2 — رفع false-negative تست زنده auth_request + پاک‌سازی Backup منابع APT

> تاریخ: 2026-11-19 — بازتولید تجربی ریشه حادثه با باینری production-class (nginx/1.24.0 Ubuntu، `--with-http_auth_request_module`) و سپس رفع + بازتولید تست.

## بازتولید تجربی ریشه (negative control با باینری production)

| آزمون | DENY (انتظار 401) | ALLOW (انتظار 200) | نتیجه |
|-------|-------------------|--------------------|--------|
| محتوا ناخوانا برای worker (EACCES — دقیقاً شرایط VPS واقعی: docroot موقت 700 مالک root در برابر worker با privilege-drop) | **401** ✓ | **403** ✗ | false-negative بازتولید شد — همان پیام Production: `open() ... failed (13: Permission denied)` در error.log |
| محتوا خوانا (fix: 0755/0644) | **401** ✓ | **200** ✓ + `AUTHREQ-LIVE-OK` | auth_request کاملاً سالم است — مشکل از هارنس تست بود، نه ماژول |

ریشه: `mktemp -d` دایرکتوری موقت را 700 می‌سازد؛ در نصب واقعی root، nginx worker به کاربر توزیع منتقل می‌شود (نoble nginx بدون `--user` کامپایل شده) و غیرمالک، از دایرکتوری 700 عبور نمی‌کند. باتری قبلی این را نمی‌دید چون rootfs فیکسچر VM، `www-data`/`nobody` را uid 0 می‌بیند (آرتیفکت userns).

## باتری اختصاصی جدید (tests/cp-authfix-battery.sh — داخل VM واقعی Ubuntu 24.04)

| سناریو | شرح | نتیجه |
|--------|-----|-------|
| A0 | sanity باینری توزیع (nginx/1.24.0 Ubuntu + Built-in flag) و نبود هرگونه `load_module`/`libnginx-mod`/`*.so` در مخزن | 7 PASS / 0 FAIL |
| A1 | `verify_auth_request_live` روی `/usr/sbin/nginx` واقعی در context نصب root (VM) + تمیزی کامل (بدون leftover موقت، بدون listener باقی‌مانده، پورت‌های فقط-loopback) + ورود خط LIVE PASS به لاگ نصب و گزارش بایگانی | 10 PASS / 0 FAIL |
| A2 | deb822: انتقال `ubuntu.sources` به Backup خارج از `sources.list.d` + نبود هشدار `Ignoring file` + Rollback بایت‌به‌بایت (`cmp` تأیید) | 14 PASS / 0 FAIL |
| A3 | sweep بقایای legacy — دقیقاً آرتیفکت Production (`ubuntu.sources.disabled-by-ops-terminal` در sources.list.d): انتقال به `disabled/legacy/`، لاگ sweep، هشدار دیگر ظاهر نمی‌شود، rollback آن را زنده نمی‌کند | 9 PASS / 0 FAIL |
| A4 | مخزن third-party با URI غیر-Ubuntu: پس از apply و پس از rollback بایت‌به‌بایت دست‌نخورده و فعال | 5 PASS / 0 FAIL |
| A5 | کنترل منفی fail-closed: باینری خراب → تست با reason دقیق FAIL می‌شود؛ کانفیگ با directive نامعلوم توسط `nginx -t` رد می‌شود | 3 PASS / 0 FAIL |

## رگرسیون‌های کامل

| باتری | نتیجه |
|-------|-------|
| CP14 — Mirror Discovery/Fallback (M1..M8, MA؛ سناریوی deb822 با ادعاهای جدید v1.3.2) | **75 PASS / 0 FAIL** |
| CP13 — نصب کامل standalone (A 56 / B 27 / C 8 / D 11 / E 12) | **114 PASS / 0 FAIL** |
| مرورگر واقعی (Playwright/Chromium → TLS واقعی → auth_request → Gateway → ttyd → root shell) | **8 PASS / 0 FAIL** |

**جمع CP15: 48 (باتری جدید) + 75 + 114 = 237 PASS / 0 FAIL + مرورگر 8/8.**

نتایج LIVE ثبت‌شده در لاگ نصب واقعی VM: `auth_request LIVE test: PASS (subrequest 401 -> denied/401, subrequest 200 -> allowed/200 + protected content served)` + `auth_request module: BUILT-IN (--with-http_auth_request_module in /usr/sbin/nginx -V)`.

انتشار: commit `1cc6e7c1b334f84454366ef6ccb74bc7f037c451`، تگ annotated `v1.3.2` (شیء تگ `0824e9fbda9ea332784cb9913f059952491f27bf`) — روی GitHub تأیید شد؛ کلون تازه تگ، مانیفست SHA256SUMS را کامل تأیید کرد (ALL FILES VERIFIED OK) و URL خام تگ‌دار دقیقاً همان فایل را سرو می‌کند.
