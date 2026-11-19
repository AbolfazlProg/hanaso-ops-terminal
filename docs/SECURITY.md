# مدل امنیتی HANASO OPS Web Terminal

این پنل **ROOT Shell واقعی** ارائه می‌کند؛ امنیت آن چندلایه است و هر لایه مستقل کار می‌کند.

## مدل تهدید

| تهدید | لایه دفاع |
|--------|-----------|
| Sniffing / MITM | HTTPS اجباری (Let's Encrypt)؛ 80→301؛ HSTS یک‌ساله؛ بدون HTTPS هیچ ورودی پردازش نمی‌شود |
| Brute-force روی /login | nginx `limit_req` 24r/m burst=12 (429) + قفل Gateway: ۵ خطا → ۱۵ دقیقه قفل با رشد تصاعدی؛ قفل در state.json پایدار و بعد از restart هم معتبر |
| Session hijacking | کوکی امضاشده HMAC (SHA256) با کلید مستقل، `HttpOnly; Secure; SameSite=Strict`، TTL 8 ساعت، jti یکتا، Revocation سمت سرور در Logout |
| CSRF | فرم‌ها فقط با توکن CSRF معتبر پاسخ می‌گیرند (کوکی nonce) |
| دور زدن auth با WS مستقیم | ttyd فقط 127.0.0.1:7681 (از بیرون دسترسی ندارد)؛ nginx قبل از proxy (HTTP و WS) `auth_request` اجرا می‌کند؛ WS بدون کوکی → 401/302 |
| Cross-origin WS | ttyd با `-O` (check-origin) — Origin/Host باید دقیق مطابق vhost باشد |
| افشای Secret | رمز هرگز در argv / لاگ / git / URL نیست؛ PBKDF2-HMAC-SHA256 با 200000 iteration؛ فایل credentials و session.key با 0600/0640 و مالکیت root:ops-gw |
| Escalation از Gateway | Gateway با کاربر `ops-gw` (بدون shell) اجرا می‌شود + Hardening systemd (NoNewPrivileges, ProtectSystem=strict, ProtectHome, PrivateTmp, ...) |
| Logهای آلوده به Secret | فرمت لاگ nginx عمداً Query String ندارد؛ لاگ Gateway فقط رویداد/نتیجه است؛ محتوای تایپ‌شده در ترمینال به‌هیچ‌وجه لاگ نمی‌شود |
| Abuse منابع | `client_max_body_size 1m`؛ نبود هرگونه ثبت‌نام عمومی — فقط یک حساب مدیریتی |

## حساب پنل vs حساب Root سیستم

- حساب پنل (`ops-admin`) **جدا از root سیستم** است و فقط برای احراز هویت Gateway استفاده می‌شود؛ حتی ورود موفق به سیستم لاگین نمی‌کند.
- Shell داخل ترمینال پس از احراز هویت پنل، توسط سرویس root (ttyd) ارائه می‌شود — نه توسط کاربر پنل.

## لاگ رویداد

`/var/log/ops-terminal/gateway.log` (JSONL): LOGIN_OK / LOGIN_FAIL / LOGIN_BLOCKED / LOGOUT / PASSWORD_SET با IP و زمان + GATEWAY_START. **نکته کلیدی:** محتوای تایپ‌شده در ترمینال هرگز ثبت نمی‌شود (مسیر ترمینال از Gateway عبور نمی‌کند).

## توصیه‌های اختیاری سخت‌تر (در nginx vhost قابل افزودن)

- محدودیت IP (allow/deny) اگر Agent از IP ثابت می‌آید.
- HTTP Basic اضافی جلوی vhost (لایه دوم). MFA فعلاً پیاده نشده (کاندیدای نسخه بعد).
- Fail2ban سفارشی روی لاگ LOGIN_BLOCKED.

## محدودیت‌های صادقانه

- بدون MFA؛ قوت رمز تصادفی ۲۴ کاراکتری + قفل Brute-force جبران‌کننده است ولی جای MFA را نمی‌گیرد.
- Restart سرویس Gateway، Sessionهای فعال را باطل نمی‌کند (کوکی امضاشده stateless است) — Logout خودکار Server-side revocation دارد.


## توپولوژی standalone (v1.3.0) — نکات امنیتی اختصاصی

- **لبه اختصاصی بدون root**: unit `ops-terminal-front` با `User=ops-gw` اجرا می‌شود و تنها
  قابلیتِ اعطاشده `CAP_NET_BIND_SERVICE` است (Ambient + Bounding) — یعنی فقط اجازه bind به
  :80/:443؛ هیچ root و هیچ setuid‌ای در کار نیست و بقیه hardeningها (NoNewPrivileges،
  ProtectSystem=strict، …) مثل بقیه unitها فعال است.
- **سرویس nginx توزیع غیرفعال می‌شود** — مالک انحصاری لبه همان unit خود پنل است و در
  uninstall هم غیرفعال باقی می‌ماند؛ هیچ سرویس ناشناسی روی لبه اجرا نمی‌شود.
- **ضد جعل XFF**: front همیشه `X-Forwarded-For` را با `$remote_addr` واقعی بازنویسی می‌کند؛
  internal nginx فقط-loopback است؛ قفل per-IP گات‌وی قابل جعل نیست.
- **دروازه DNS قبل از هر تغییر**: A record باید به همین سرور اشاره کند، وگرنه نصب با صفر
  اثر جانبی متوقف می‌شود (بدون صدور گواهی، بدون باز کردن لبه).
- **self-signed فقط محیط بسته**: `--tls-mode self-signed` برای پنل عمومی توصیه نمی‌شود و در
  خروجی Installer با هشدار صریح اعلام می‌شود؛ مسیر پیش‌فرض (acme) گواهی واقعی Let's Encrypt
  می‌گیرد و تمدید آن با certbot.timer + هوک deploy (فقط reload خود front) انجام می‌شود.
- **پارتیشن خطا**: شکست صدور گواهی → rollback کامل (هیچ چیزی نصب یا exposed نمی‌ماند) —
  در باتری CP13 با سناریوی D اثبات شده است.
