# CURRENT STATE — HANASO OPS Web Terminal

> آخرین به‌روزرسانی: 2026-11-19 — CP15 / v1.3.2 (رفع false-negative تست زنده auth_request + پاک‌سازی Backup منابع APT)
> این فایل وضعیت واقعی را در هر Checkpoint ثبت می‌کند. هیچ ادعای Push/Deploy بدون تأیید نمی‌شود.

## مأموریت

پنل Web Terminal با **ROOT Shell واقعی** برای VPS مشترک HANASO، پشت احراز هویت مستقل و HTTPS، روی 443 موجود nginx — بدون وابستگی عملیاتی به GitHub Actions / SSH از Sandbox / Cloudflare Tunnel. این Session فقط ساخت و آزمایش؛ **هیچ تغییری روی VPS واقعی انجام نشده است.**

## وضعیت DNS (تأییدشده)

- `ops.hanaso.ir` → IP عمومی VPS (رکورد A، DNS Only؛ NS: Cloudflare khloe/newt) — از قبل تنظیم شده.
- بازرسی خارجی: nginx روی 443 VPS مستقیماً TLS خاتمه می‌دهد (گواهی فعلی پیش‌فرض: CN=kotodama.ir).
- TCP egress پورت 22 از Sandbox مسدود → تشخیص توپولوژی کامل به preflight در زمان نصب (read-only) سپرده شده.

## محیط آزمایش Sandbox (تأییدشده)

Debian 13 trixie / x86_64 / کاربر uid 1001 بدون root / PID1=tini / nginx 1.26.3 (استخراج unprivileged، auth_request دارد) / tmux 3.5a / ttyd 1.7.7 vendored (SHA256 رسمی) / Playwright+Chromium / userns فعال برای شبیه‌سازی ROOT.

## تصمیم‌های ثبت‌شده

| # | تصمیم |
|---|--------|
| D1 | ابزار: **ttyd 1.7.7** (باینری استاتیک؛ WebSocket؛ ping 5s پیش‌فرض) |
| D2 | Session persistence: **tmux** (`tmux new -A -s ops`) |
| D3 | احراز هویت: **Gateway اختصاصی Python-stdlib + nginx auth_request + کوکی HMAC** |
| D4 | ttyd → 127.0.0.1:7681 (root)؛ Gateway → 127.0.0.1:7682 (ops-gw) |
| D5 | Brute-force: nginx limit_req + قفل پیش‌رونده پایدار Gateway |
| D6 | TLS: گواهی موجود یا Let's Encrypt (certbot HTTP-01 webroot)؛ توقف امن در نبود DNS/TLS |
| D7 | فقط vhost مستقل nginx + reload (هرگز restart)؛ rollback خودکار |
| D8 | اثبات مرورگر: Playwright + `window.term` (متن ترمینال خواندنی) + اثبات side-channel فایل |
| D9 | اثبات ROOT در Sandbox: userns `unshare -Ur` (id -u=0 از مرورگر واقعی + WS) |
| D10 | توپولوژی‌ها: nginx-direct + haproxy-front + haproxy-tcp-passthrough — تشخیص خودکار در Preflight |
| D11 | HAProxy: بلوک‌های مدیریت‌شده BEGIN/END + تبدیل برگشت‌پذیر crt→crt-list + فقط `haproxy -c` و reload (هرگز restart) |
| D12 | فایل env Preflight: سریال‌سازی امن KEY='VALUE' + پارسر سخت‌گیرانه؛ **هرگز source/eval نمی‌شود** (رفع حادثه 2026-11-16) |
| D13 | nginx داخلی پشت HAProxy: مستقل، loopback-only، `absolute_redirect off` (جلوگیری از ریدایرکت مطلق به پورت داخلی) |
| D14 | نصب تک‌خطی: بوت‌استرپ `quick-install.sh` (curl \| bash) — کلون مخزن + راستی‌آزمایی fail-closed مانیفست SHA256SUMS + پاس عیناً به Installer رسمی؛ **fd0 هرگز لمس نمی‌شود** (منبعِ خود اسکریپت در حالت curl \| bash) — درس تست واقعی 2026-11-17 |
| D15 | CP10: مقدار خالی `PREFLIGHT_CERT_PATH=''` وضعیت معمولیِ «بدون گواهی موجود» است (پارسر: newline اضافه برای grep تا خطِ خالی match شود؛ fail-closed دست‌نخورده)؛ صدور Let's Encrypt از مسیر ACME مدیریت‌شده :80 با `use_backend` (نه `http-request use-backend` که در HAProxy 2.x/3.x نامعتبر است)؛ اعتبارسنجی جفت گواهی در همه مسیرها؛ reinstall مسیر ACME را بازمی‌سازد |
| D16 | CP11: PID فایل دقیقاً «یک مرجع» دارد (فقط در nginx.conf؛ Unit هرگز با `-g 'pid …;'` آن را دوباره تعریف نمی‌کند) — علت خطای واقعی `"pid" directive is duplicate in nginx.conf:5` |
| D17 | CP11: لاگ خطای اولیه nginx با `-e stderr` به journald می‌رود (بدون دسترسی به لاگ مشترک `/var/log/nginx`)؛ لاگ پس-از-parse فقط زیر `/var/log/ops-terminal`؛ `daemon off;` در conf اصلی برای Type=simple؛ `ExecStartPre` هم `nginx -t` را با هویت سرویس اجرا می‌کند |
| D18 | CP11: سیاست Restart همه unitها: `Restart=on-failure` + `RestartSec=3` + `StartLimitIntervalSec=120`/`StartLimitBurst=5` — بعد از ۵ شکست متوالی unit به failed می‌رود و DOWN می‌ماند (حلقه ۹۷۲تایی Production دیگر ممکن نیست) |
| D19 | CP11: مالکیت پوشه‌ها: conf داخلی `root:ops-gw` (فقط-خواندنی برای سرویس)، pid/tmp و لاگ‌ها ops-gw — کاربر سرویس نمی‌تواند پیکربندی خودش را تغییر دهد |
| D21 | CP12: خط فرمان unit nginx **هیچ گزینه وابسته به نسخه‌ای ندارد** — سوییچ `-e` فقط از nginx 1.19.5 (2020-11-24) وجود دارد و باینری کلاس-VPS (Ubuntu LTS 1.18.0، error-log کامپایل‌شده = `/var/log/nginx/error.log`) آن را نمی‌شناسد (`nginx: invalid option: "e"` واقعی). alert اولیه لاگ خطا برای هویت غیر-root «بی‌خطر-طبق-طرح» است: یک خط → stderr → journald و nginx ادامه می‌دهد؛ لاگ پس-از-parse فقط زیر `/var/log/ops-terminal`؛ `/var/log/nginx` هرگز تغییر مجوز نمی‌دهد و اجرای root ممنوع |
| D22 | CP12: لینت unit فقط روی خطوط `Exec*` انجام می‌شود (کامنت‌های آموزشی unit شکل تاریخی باگ را به‌درستی توصیف می‌کنند)؛ باتری‌ها clean-room دارند (اسویپ بقایای باتری قبلی) و در محیط بازیافتی خودترمیم هستند (تولید CA آزمایشی/گواهی تست در صورت نبود) |
| D23 | CP12: معیار قبولی production = اجرای verbatim `ExecStart/ExecReload` روی **باینری هم‌کلاس VPS** + تراکنش واقعی systemd 257 (`systemd --user --test` روی unitهای واقعی) + پارسر واقعی (`systemd-analyze verify`). محدودیت ثبت‌شده: manager زنده در این کانتینر بالا نمی‌آید (نبود cgroup قابل‌نوشتن — شواهد ضبط‌شده در باتری)؛ روی VPS همان فایل‌ها بدون تغییر در manager واقعی بارگذاری می‌شوند |
| D24 | CP12: Installer هویت واقعی باینری nginx را در لاگ نصب ثبت می‌کند (`nginx -V` + error-log-path) تا هر ناهم‌نسخگی آینده بلافاصله قابل تشخیص باشد |
| D25 | CP13: توپولوژی **standalone** — سرور تازه با صفر پیش‌نیاز؛ Installer با apt بسته توزیع `nginx` را نصب می‌کند (auth_request با `nginx -V` fail-closed اثبات می‌شود؛ در noble بسته واقعی باینری `nginx` است) + certbot؛ دروازه DNS قبل از هر تغییر (ناهمخوانی = توقف با صفر اثر جانبی) |
| D26 | CP13: unit اختصاصی `ops-terminal-front` (:80/:443) با `User=ops-gw` و فقط `CAP_NET_BIND_SERVICE` (Ambient+Bounding) — بدون root؛ سرویس nginx توزیع disable می‌شود؛ PID فقط یک مرجع دارد (nginx.conf) و هیچ سوییچ وابسته به نسخه‌ای در خط فرمان نیست (قرارداد CP11/CP12) |
| D27 | CP13: صدور گواهی دو-فازی — فاز A فقط :80 (وب‌روت ACME + ریدایرکت) با include خالی، سپس فاز B رندر vhost :443 با مسیر گواهی واقعی + `nginx -t` + reload؛ شکست صدور = rollback کامل (fail-closed) |
| D28 | CP13: حالت `--tls-mode self-signed` فقط محیط بسته/آزمایش (هشدار صریح) + تایمر `ops-terminal-tls-renew.timer` (بازتولید زیر ۳۰ روز مانده + فقط reload خود front)؛ حالت acme: certbot.timer + هوک deploy فقط-front |
| D29 | CP13: front با `$http_host` پورت اصلی را به لایه داخلی می‌رساند — ttyd با `-O` (check-origin) پورت را مقایسه می‌کند و Host بدون پورت هر WS را پشت لبه با پورت غیراستاندارد می‌کشت (باگ واقعی که با مرورگر واقعی در باتری CP13 کشف و رفع شد) |
| D30 | CP13: uninstall فقط منابع خود پروژه را حذف می‌کند (units/wants/فایل‌ها/وب‌روت/هوک LE/گواهی LE این دامنه با certbot delete/ops-gw)؛ بسته‌های توزیع پیش‌فرض می‌مانند و `--purge-packages` اختیاری است (بعد از uninstall هم قابل اجراست) |
| D31 | CP13: محیط آزمایش — VM واقعی Ubuntu 24.04 (rootfs از بسته‌های رسمی archive.ubuntu.com؛ Python 3.12.3، tmux 3.4، systemd 255 = همان کلاس VPS) داخل userns؛ محدودیت پلتفرم (بدون cgroup قابل‌نوشتن، بدون KVM، بدون root) مثل CP12 مستند است؛ unitها با `systemd-analyze verify` واقعی Ubuntu 255 و تراکنش‌ها با supervisor وفادار به policy + shim systemctl اجرا و اثبات می‌شوند |
| D32 | CP13: باتری CP13 = ۵ سناریو (C منفی DNS / D rollback / B مسیر ACME با stub-certbot + ACME round-trip از لبه واقعی :80 / A نصب کامل self-signed با ۵۶ چک / E uninstall) — جمعاً ۱۱۳ PASS و ۰ FAIL + مرورگر واقعی Playwright از پشت رله‌ها: ورود واقعی، `id -u` = 0، side-channel فایل، بقای session — ۸/۸ PASS |
| D33 | CP14: فاز apt standalone فقط با «موفقیت واقعی APT» داوری می‌شود (واکشی InRelease + apt-get update ایزوله با اعتبارسنجی امضای apt-secure + وجود Candidate همه بسته‌های موردنیاز از فهرست تازه) — کد خروج `apt-get update` هرگز مدرک نیست (بازتولید تجربی: rc=0 با W: Failed to fetch، سپس E: Unable to locate package). کاندیدها به ترتیب: پیکربندی فعلی → mirrors.ubuntu.com (Mirror Discovery رسمی) → رجیستری Launchpad → فهرست ثابت رسمی/ثبت‌شده. تغییر فقط روی مخازن Ubuntu (hostهای استاندارد + file:/copy: + hostهای اعلامی OPS_APT_EXTRA_UBUNTU_HOSTS)؛ third-party هرگز لمس نمی‌شود؛ backup قبل از تغییر؛ rollback، apt sources را برمی‌گرداند؛ deb822 و تک‌خطی هر دو؛ گزارش کامل `[apt-mirror]` + apt-mirror-report.txt؛ تست زنده auth_request (subrequest 401 → deny، 200 → allow) |
| D34 | CP15: تست زنده auth_request دو لایه است — (1) تشخیص Built-in از `nginx -V` (هیچ load_module/`.so`/بسته اضافه‌ای در کار نیست)، (2) اثبات واقعی روی nginx دورریز با دو Listener فقط-loopback و کانفیگ/pid/log موقت: 401-stub باید Deny واقعی بدهد، 200-stub باید Allow واقعی با تحویل محتوا بدهد. ریشه حادثه v1.3.1 (بازتولید تجربی با باینری production nginx/1.24.0): docroot موقت 700 برای worker با privilege-drop ناخوانا بود → مسیر Allow پاسخ 403 → false negative؛ فیکسچر VM آن را نمی‌دید چون rootfs آزمایشی www-data/nobody را uid 0 می‌بیند. Fix: docroot 0755/0644 + body-proof + تشخیص گام‌به‌گام (`_ARL_REASON`) + fallbackهای probe (wget/dev-tcp، ss/dev-tcp) + انتظار خروج تمیز nginx قبل از پاک‌سازی. همچنین: فایل deb822 غیرفعال‌شده از `sources.list.d` به Backup منتقل می‌شود (رفع هشدار واقعی `Ignoring file ...`)، بقایای نسخه‌های قبلی sweep می‌شوند و rollback بایت‌به‌بایت restore می‌کند |
| D20 | CP11: Rollback شکست نصب: `die()` بعد از اولین تغییر → rollback کامل؛ شاخه production فقط unitهای خود پروژه را متوقف می‌کند (`scripts/ops-systemd.sh`: disable --now + TERM/KILL + reset-failed + حذف فایل‌های unit) و بلوک‌های مدیریت‌شده HAProxy را state-independent می‌جارو (بقایای runهای قبلی هم حذف و reload اعتبارسنجی‌شده) |

## Checkpoints

| CP | شرح | Commit | وضعیت |
|----|------|-------|-------|
| CP0 | Repository + baseline | d7f12d2 | ✅ Push شده |
| CP1 | معماری/مقایسه راهکارها (README + مستندات) | d7f12d2..6f3f3b6 | ✅ Push شده |
| CP2 | پیاده‌سازی کامل (gateway/units/vhost/scripts) | 6f3f3b6 | ✅ Push شده |
| CP3/4 | استقرار Sandbox + ۱۴ e2e سبز | a3f469a | ✅ Push شده |
| CP5 | تست مرورگر واقعی + باتری کامل + ROOT-proof + هاردنینگ (session revocation و...) | f1e40d0 | ✅ |
| CP6 | مستندات کامل + SHA256SUMS + Tag v1.0.0 + Installer تست‌شده | e1fb8a1 | ✅ |
| — | Release (SHA256SUMS + tag v1.0.0) | v1.0.0 | ✅ |
| CP7 | پشتیبانی HAProxy (3 توپولوژی) + رفع باگ Preflight (پارسر امن) + باتری HAProxy + رگرسیون کامل | 08858af (tag v1.1.0) | ✅ Push شده — در انتظار نصب Production |
| CP8 | نصب تک‌خطی `quick-install.sh` (curl \| bash) + رفع باگ fd0 + مستندسازی | 5e20327 / e5401ab | ✅ Push و تست‌شده |
| CP9 | Release v1.2.0: CURRENT_STATE + مستندات one-liner تگ‌دار + SHA256SUMS نهایی | v1.2.0 | ✅ Push شده |
| CP10 | HOTFIX: پذیرش `PREFLIGHT_CERT_PATH=''` + شاخه صدور certbot واقعی + مسیر ACME صحیح + بازسازی مسیر ACME در reinstall + اعتبارسنجی جفت گواهی + باتری CP10 (سناریوی دقیق VPS) | tag v1.2.1 | ✅ تست و Push شده — در انتظار نصب Production |
| CP11 | HOTFIX Systemd/Nginx: PID یکتا + `daemon off` + سیاست Restart محدود + مالکیت پوشه‌ها + rollback قطع‌کننده حلقه + باتری CP11 | f437c4d (tag v1.2.2) | ✅ Push شده — `-e stderr` آن روی باینری واقعی VPS می‌مرد → CP12 |
| CP12 | FIX نهایی سازگاری systemd/nginx: حذف `-e stderr` از unit و Installer (D21) + ثبت هویت باینری nginx در لاگ نصب (D24) + باتری CP12 (ماتریس باینری + اجرای verbatim روی Ubuntu 1.18.0 + تراکنش واقعی systemd + ۱۱ گام پذیرش + rollback + leftover-reinstall + quick-install واقعی) | 8351927 (tag v1.2.3) | ✅ ۱۰۱ PASS + رگرسیون‌ها سبز + نصب واقعی تک‌خطی از تگ GitHub (SHA OK، e2E، uninstall پاک) — Push شده |
| CP13 | نصب مستقل Ubuntu تازه (standalone): preflight گسترش‌یافته + apt nginx/certbot + دروازه DNS + unit front با CAP_NET_BIND_SERVICE + صدور دو-فازی + self-signed/ACME + uninstall project-only + باتری ۵ سناریویی (۱۱۳ PASS/۰ FAIL) + مرورگر واقعی ۸/۸ + رفع باگ واقعی `$http_host` (check-origin ttyd) | tag v1.3.0 | ✅ Push شده |
| CP14 | حادثه Production (`E: Unable to locate package nginx/certbot` روی VPS تازه): بازتولید تجربی ریشه روی Ubuntu 24.04 (update خراب با rc=0) + موتور کشف/Fallback آینه‌ها (scripts/ops-apt-mirror.sh: سه سرویس کشف + probe ایزوله با apt-secure + candidate check + بازنویسی deb822/تک‌خطی فقط-مخازن-Ubuntu + backup/rollback + گزارش کامل) + تست زنده auth_request + باتری موتور ۹ سناریویی (۷۰ PASS/۰ FAIL: بازپخش حادثه، fallback، index ناقص، امضای دستکاری‌شده، universe غیرفعال، DNS/TLS خراب، fail-closed همه-ناموفق، deb822، رگرسیون طبیعی) + رگرسیون CP13 کامل (۱۱۴ PASS/۰ FAIL) + مرورگر واقعی ۸/۸ + شواهد شبکه واقعی (archive.ubuntu.com timeout از شبکه آزمایش، mirrors.ubuntu.com unreachable، ir.archive.ubuntu.com 200 OK، رجیستری Launchpad با ۴۸۶ Mirror) | tag v1.3.1 | ✅ تست‌شده — Push شده |
| CP15 | حادثه Production (`auth_request LIVE test FAILED` با nginx سالم): بازتولید تجربی false-negative با باینری production-class (nginx/1.24.0 Ubuntu — Deny=401، Allow=403 با EACCES؛ بعد از fix: 401/200+محتوا) + بازنویسی تست LIVE (docroot 0755/0644، اثبات محتوا، تشخیص دقیق، probe fallback، خروج تمیز) + تشخیص Built-in صریح + پاک‌سازی Backup APT (انتقال deb822 به disabled/ + sweep legacy + rollback بایت‌به‌بایت) + باتری اختصاصی ۶ سناریویی (۴۸ PASS/۰ FAIL: sanity باینری، LIVE ایزوله در VM، deb822+rollback دقیق، sweep legacy دقیقاً حالت Production، third-party دست‌نخورده، fail-closed باینری خراب) + رگرسیون CP14 کامل (۷۵ PASS/۰ FAIL) + رگرسیون CP13 کامل (۱۱۴ PASS/۰ FAIL) + مرورگر واقعی ۸/۸ | tag v1.3.2 | ✅ تست‌شده — Push شده |

## نتایج آزمون (خلاصه)

- باتری nginx-direct ۱۰ مرحله‌ای: **TOTAL FAILED STEPS: 0** (۴۶ PASS / ۰ FAIL) — `tests/SANDBOX_TEST_REPORT.md`
- باتری HAProxy ۱۶ مرحله‌ای: **TOTAL FAILED STEPS: 0** (۸۱ PASS / ۰ FAIL) — شامل install، تبدیل برگشت‌پذیر crt→crt-list، e2e کامل از پشت TLS+SNI، مرورگر واقعی، brute-force، XFF spoof-proofing، rollback تحمیلی (شکست e2e بعد از سیم‌کشی HAProxy → بازگشت دقیق)، idempotent reinstall، uninstall و نصب نهایی — `tests/haproxy-battery.sh`
- نصب تک‌خطی واقعی از GitHub (2026-11-17): `curl -fsSL .../main/quick-install.sh \| bash -s -- --sandbox ...` → clone از github.com (commit e5401ab) → **SHA256SUMS: OK** → نصب کامل + e2e داخلی Installer → health-check **HEALTHY** → uninstall پاک — rc=0. نکته: CDN خام تا ~۵ دقیقه بعد از Push نسخه قبلی را سرو می‌کند؛ برای VPS از URL تگ‌دار (v1.2.0) استفاده کنید.
- باتری CP10 (`tests/cp10-battery.sh`) — سناریوی دقیق VPS (`PREFLIGHT_CERT_PATH=''` + certbot موجود + clean install بدون گواهی اولیه): **TOTAL FAILED STEPS: 0** (۹۱ PASS) — پذیرش fixture پارسر + فعال‌شدن شاخه certbot + round-trip چالش ACME از لبه واقعی :80 + صدور شبیه‌سازی‌شده با certbot stub + جایگزینی مسیر + اعتبار HAProxy + HTTPS/SNI/WS + مرورگر واقعی + **id -u=0 از مرورگر** + rollback تحمیلی + uninstall (حفظ state LE) + مسیر منفی صدور شکست → TLS GATE فقط-loopback
- باتری CP12 (`tests/cp12-battery.sh`): **TOTAL FAILED CHECKS: 0** (۱۰۱ PASS) — ماتریس باینری: trixie 1.26.3 سوییچ `-e` را می‌پذیرد (چرا CP11 سبز ماند) و Ubuntu 1.18.0 دقیقاً `nginx: invalid option: "e"` می‌دهد (مکانیسم حادثه) + unit lint روی خطوط Exec + نصب واقعی + اجرای verbatim ExecStart/ExecReload روی nginx 1.18.0 (گوش‌دادن 127.0.0.1:7680، سلامت، alert بی‌خطر ثبت‌شده، master زنده) + قرارداد هویت ops-gw (unit User=ops-gw، مالکیت root:ops-gw 0750، کاربر nologin، اجرا با CapEff=0) + ۱۱ گام پذیرش CP12 (auth 302، e2e کامل از پشت SNI، مرورگر واقعی، id -u، دستور تعاملی، restart کنترل‌شده، شکست تحمیلی → StartLimit → failed بدون حلقه، rollback فقط-پنل با پورت‌های آزاد و بلوک‌های پاک و HAProxy master ثابت و KOTODAMA/HANASO سالم و Backupهای حفظ‌شده) + leftover-reinstall (unitهای حذف‌شده + فایل‌ها/Backupهای باقی‌مانده → مذاکره idempotent با حفظ credential قدیمی) + تراکنش واقعی systemd 257 روی unitهای واقعی + quick-install واقعی
- باتری CP11 (`tests/cp11-battery.sh`): **TOTAL FAILED CHECKS: 0** (۱۲۶ PASS پس از لینت CP12) — بازتولید سه یافته Production از آرتیفکت‌های واقعی v1.2.1 (خطای دقیق `"pid" directive is duplicate in nginx.conf:5` با ExecStart واقعی و هویت سرویس؛ alert واقعی `could not open error log file /var/log/nginx/error.log` با nginx کلاس-VPS اوبونتو 1.18؛ حلقه Restart بی‌کران با Restart=always: شمارنده ۳→۵ در ۴.۵ ثانیه) + `systemd-analyze verify` روی unitهای واقعی + اجرای unitها با supervisor وفادار به پالیسی (گوش‌دادن 127.0.0.1:7680، MainPID==pidfile، reload/restart کنترل‌شده) + StartLimit (NRestarts≤5، شمارنده منجمد، failed state) + auth/websocket/مرورگر واقعی از پشت SNI + sweep مالکیت‌خصوصی unitها با decoy سالم + die-path rollback دوبار (بقایای HAProxy هم پاک) + uninstall + clean reinstall + اجرای واقعی quick-install.sh
- محدودیت محیط (مستندشده): systemd واقعی به‌عنوان Manager در این کانتینر بالا نمی‌آید (PID1=tini؛ cgroup v1 فقط-خواندنی — پیام ضبط‌شده manager واقعی: `Failed to create /k8s.io/.../init.scope control group: Read-only file system`)؛ پالیسی unitها با پارسر خود systemd (`systemd-analyze verify`) و supervisor وفادار به پالیسی آزموده می‌شود و روی VPS همان فایل‌ها بدون تغییر در systemd واقعی بارگذاری می‌شوند. بازسازی ابزار: `tests/setup-sandbox-toolchain.sh`
- رگرسیون CP7 پس از تغییرات install.sh: باتری HAProxy **۰ FAILED** — رگرسیون baseline: باتری nginx-direct **۰ FAILED**
- مرورگر واقعی (Playwright) در هر دو توپولوژی: ✅ — متن ترمینال از `window.term` + اثبات فایل side-channel
- ROOT-proof (userns): `id -u -> 0` از مرورگر واقعی و WS ✅
- باتری موتور Mirror CP14 (`tests/cp-mirror-battery.sh` روی VM تمیز Ubuntu 24.04): **۹ سناریو — ۷۰ PASS / ۰ FAIL** — M1 بازپخش دقیق حادثه (sources خالی + فهرست خالی + update بی‌صدا rc=0 → موتور نجات می‌دهد) / M2 Mirror اول مرده → دومی / M3 index ناقص (بدون universe → certbot=(none) → رد) / M4 InRelease دستکاری‌شده → رد توسط apt-secure / M5 فقط-main فعلی → رد + افزودن universe در بازنویسی / M6 DNS و TLS خراب با دلیل دقیق / M7 همه ناموفق → fail-closed با صفر اثر جانبی (sources دست‌نخورده، هیچ بسته‌ای نصب نشده، گزارش دلایل) / M8 پشتیبانی deb822 (ubuntu.sources غیرفعال، فایل .sources با Signed-By پین‌شده) / MA جریان طبیعی (current-config سالم → بدون بازنویسی)
- رگرسیون CP13 پس از تغییرات install.sh: **۱۱۴ PASS / ۰ FAIL** (C/D/B/A/E)
- مرورگر واقعی CP14: **۸/۸ PASS** (Chromium واقعی از پشت رله‌ها: ریدایرکت، ورود، xterm، id -u=0، hostname، side-channel فایل، کوکی re-connect، بقای tmux)
- شواهد شبکه واقعی Sandbox (گزارش Owner): `archive.ubuntu.com` timeout، `mirrors.ubuntu.com/mirrors.txt` unreachable، `ir.archive.ubuntu.com/ubuntu/dists/noble/InRelease` → 200 OK در 2.1s، رجیستری Launchpad → ۴۸۶ Mirror ثبت‌شده
- گزارش کامل: `tests/SANDBOX_TEST_REPORT.md`

## امنیت

هیچ Secret/IP/Token/رمزی در Repository نیست (اسکن pre-push خودکار). رمز پنل فقط یک‌بار در کنسول نصب نمایش داده می‌شود؛ Credential با PBKDF2 (200k) در فایل 0600.
