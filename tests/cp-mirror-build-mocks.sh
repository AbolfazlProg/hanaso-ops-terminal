#!/usr/bin/env bash
# ==========================================================================
# CP v1.3.1 — build SIGNED mock Ubuntu mirrors for the mirror-engine battery.
#
# Runs on the SANDBOX HOST (has gpg + dpkg-scanpackages + the real noble pool
# from the CP13 VM build). The VM battery mounts the result at /opt/cp-mirrors
# and serves each mirror with python3 http.server INSIDE the VM netns.
#
# Layout (/home/z/my-project/vm-cp13/cp-mirrors/):
#   m1/ubuntu/         FULL mirror: main(nginx)+universe(certbot), VALID sig
#   m2/ubuntu/         identical fallback mirror, VALID sig
#   nouniverse/ubuntu/ main ONLY (certbot candidate missing -> engine rejects)
#   badsig/ubuntu/     m1 content with a TAMPERED InRelease (apt rejects)
#   tls-broken/        self-signed cert for a WRONG domain (curl rc=60)
#   cp-mirror-test-key.gpg   dearmored test key (VM installs into apt keyrings)
#
# The test key signs ONLY these mocks. apt-secure validation stays fully ON:
# the engine never writes trusted=yes and never disables signature checks;
# the VM trusts the test key exactly like a real server trusts the Ubuntu
# archive key.
# ==========================================================================
set -euo pipefail

BASE=/home/z/my-project/vm-cp13
OUT="$BASE/cp-mirrors"
KEYDIR="$BASE/cp-mirror-key"
POOL_SRC="$BASE/mirror/pool"
export GNUPGHOME="$KEYDIR"

mkdir -p "$OUT" "$KEYDIR"
chmod 700 "$KEYDIR"

# ---------------------------------------------------------------- test key --
if ! gpg --list-secret-keys "cp-mirror-test" >/dev/null 2>&1; then
  cat > "$KEYDIR/key-params" <<'EOF'
%no-protection
Key-Type: RSA
Key-Length: 2048
Name-Real: cp-mirror-test
Name-Email: cp-mirror-test@invalid
Expire-Date: 0
%commit
EOF
  gpg --batch --gen-key "$KEYDIR/key-params" >/dev/null 2>&1
  echo "[mock] test key generated"
fi
gpg --armor --export "cp-mirror-test@invalid" \
  | gpg --dearmor > "$OUT/cp-mirror-test-key.gpg"
chmod 0644 "$OUT/cp-mirror-test-key.gpg"

# ------------------------------------------------------------------ pool ----
mkdir -p "$OUT/pool-src" "$OUT/work"
cp -af "$POOL_SRC"/*.deb "$OUT/pool-src/"
ln -sfn "$OUT/pool-src" "$OUT/work/pool"

# ------------------------------------------------------ scan + split + build --
(cd "$OUT/work" && dpkg-scanpackages --arch amd64 pool /dev/null 2>/dev/null) > "$OUT/work/scan_raw.tmp"
[ -s "$OUT/work/scan_raw.tmp" ] || { echo "FATAL: dpkg-scanpackages produced nothing"; exit 1; }

python3 - "$OUT" <<'PYEOF'
import sys, os, re, hashlib, gzip, time, shutil, subprocess

out = sys.argv[1]

stanzas = open(os.path.join(out, "work", "scan_raw.tmp"), encoding="utf-8").read()
blocks = [b for b in stanzas.split("\n\n") if b.strip()]
main_b, uni_b = [], []
for b in blocks:
    m = re.search(r"^Package:\s*(\S+)", b, re.M)
    name = m.group(1) if m else ""
    (main_b if name.startswith("nginx") else uni_b).append(b)
print(f"[mock] stanzas: main={len(main_b)} universe={len(uni_b)}")
assert any("Package: nginx\n" in b for b in main_b), "nginx missing in main"
assert any("Package: certbot\n" in b for b in uni_b), "certbot missing in universe"

def link_pool(root, src):
    os.makedirs(os.path.join(root, "ubuntu", "pool"))
    for f in os.listdir(src):
        os.link(os.path.join(src, f), os.path.join(root, "ubuntu", "pool", f))

def write_repo(root, comp_blocks):
    dist = os.path.join(root, "ubuntu", "dists", "noble")
    for comp, blocks in comp_blocks:
        d = os.path.join(dist, comp, "binary-amd64")
        os.makedirs(d, exist_ok=True)
        data = ("\n\n".join(blocks) + "\n").encode()
        open(os.path.join(d, "Packages"), "wb").write(data)
        with gzip.open(os.path.join(d, "Packages.gz"), "wb") as f:
            f.write(data)
    md5_lines, sha256_lines, sha512_lines, rel_files = [], [], [], []
    for comp, _ in comp_blocks:
        for fn in ("Packages", "Packages.gz"):
            rel_files.append(f"{comp}/binary-amd64/{fn}")
    for rel in rel_files:
        data = open(os.path.join(dist, rel), "rb").read()
        md5_lines.append(" %s %8d %s" % (hashlib.md5(data).hexdigest(), len(data), rel))
        sha256_lines.append(" %s %8d %s" % (hashlib.sha256(data).hexdigest(), len(data), rel))
        sha512_lines.append(" %s %8d %s" % (hashlib.sha512(data).hexdigest(), len(data), rel))
    release = (
        "Origin: Ubuntu\n"
        "Label: Ubuntu\n"
        "Suite: noble\n"
        "Codename: noble\n"
        f"Date: {time.strftime('%a, %d %b %Y %H:%M:%S UTC', time.gmtime())}\n"
        "Architectures: amd64\n"
        "Components: " + " ".join(c for c, _ in comp_blocks) + "\n"
        "Description: Ubuntu 24.04 LTS (cp-mirror test mock)\n"
        "MD5Sum:\n" + "\n".join(md5_lines) + "\n"
        "SHA256:\n" + "\n".join(sha256_lines) + "\n"
        "SHA512:\n" + "\n".join(sha512_lines) + "\n"
    )
    open(os.path.join(dist, "Release"), "w").write(release)

def sign(root):
    dist = os.path.join(root, "ubuntu", "dists", "noble")
    subprocess.run(
        ["gpg", "--batch", "--yes", "--clearsign", "--digest-algo", "SHA256",
         "--local-user", "cp-mirror-test@invalid",
         "--output", os.path.join(dist, "InRelease"),
         os.path.join(dist, "Release")],
        check=True, capture_output=True)

fresh = [
    ("m1", [("main", main_b), ("universe", uni_b)], "full, valid sig"),
    ("m2", [("main", main_b), ("universe", uni_b)], "fallback, valid sig"),
    ("nouniverse", [("main", main_b)], "certbot candidate missing"),
]
for name, comps, desc in fresh:
    root = os.path.join(out, name)
    shutil.rmtree(os.path.join(root, "ubuntu"), ignore_errors=True)
    link_pool(root, os.path.join(out, "pool-src"))
    write_repo(root, comps)
    sign(root)
    print(f"[mock] {name} built ({desc})")

# badsig: m1 clone with TAMPERED InRelease (signature must fail in apt)
bs = os.path.join(out, "badsig")
shutil.rmtree(os.path.join(bs, "ubuntu"), ignore_errors=True)
shutil.copytree(os.path.join(out, "m1", "ubuntu"), os.path.join(bs, "ubuntu"))
with open(os.path.join(bs, "ubuntu", "dists", "noble", "InRelease"), "a") as f:
    f.write("TAMPERED-LINE-BY-BATTERY\n")
print("[mock] badsig built (tampered InRelease)")

# tls-broken: cert for a WRONG domain (curl rc=60 -> engine rejects)
os.makedirs(os.path.join(out, "tls-broken"), exist_ok=True)
subprocess.run(
    ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "30",
     "-sha256", "-keyout", os.path.join(out, "tls-broken", "key.pem"),
     "-out", os.path.join(out, "tls-broken", "cert.pem"),
     "-subj", "/CN=wrong.example.com",
     "-addext", "subjectAltName=DNS:wrong.example.com"],
    check=True, capture_output=True)
print("[mock] tls-broken cert built (CN=wrong.example.com)")

# flat offline mirror (/opt/mirror, CP13 legacy): give it SIGNED metadata too.
# The engine never honors trusted=yes — an unsigned flat repo can never pass
# a strict probe, so the CP13 image mirror gets a real signed Release/InRelease
# (same test key; the VM keyrings already trust it).
flat = "/home/z/my-project/vm-cp13/mirror"
pkgs = os.path.join(flat, "Packages")
if os.path.exists(pkgs):
    md5_l, s256_l, s512_l = [], [], []
    rels = ["Packages", "Packages.gz"]
    for rel in rels:
        f = os.path.join(flat, rel)
        if not os.path.exists(f):
            continue
        data = open(f, "rb").read()
        md5_l.append(" %s %8d %s" % (hashlib.md5(data).hexdigest(), len(data), rel))
        s256_l.append(" %s %8d %s" % (hashlib.sha256(data).hexdigest(), len(data), rel))
        s512_l.append(" %s %8d %s" % (hashlib.sha512(data).hexdigest(), len(data), rel))
    rel_txt = (
        "Origin: Ubuntu\n"
        "Label: Ubuntu\n"
        "Suite: ./\n"
        "Codename: ./\n"
        f"Date: {time.strftime('%a, %d %b %Y %H:%M:%S UTC', time.gmtime())}\n"
        "Architectures: amd64\n"
        "Components: main\n"
        "Description: Ubuntu 24.04 LTS (CP13 offline flat mirror, signed for the CP engine)\n"
        "MD5Sum:\n" + "\n".join(md5_l) + "\n"
        "SHA256:\n" + "\n".join(s256_l) + "\n"
        "SHA512:\n" + "\n".join(s512_l) + "\n"
    )
    open(os.path.join(flat, "Release"), "w").write(rel_txt)
    subprocess.run(
        ["gpg", "--batch", "--yes", "--clearsign", "--digest-algo", "SHA256",
         "--local-user", "cp-mirror-test@invalid",
         "--output", os.path.join(flat, "InRelease"),
         os.path.join(flat, "Release")],
        check=True, capture_output=True)
    print("[mock] flat /opt/mirror mirror signed (Release+InRelease)")

print("[mock] MOCKS_DONE")
PYEOF
