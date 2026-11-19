#!/usr/bin/env node
/**
 * HANASO OPS Web Terminal — REAL browser test (Playwright/Chromium).
 *
 * The "most important test" of the mission: a real browser opens the panel,
 * logs in, gets a REAL terminal, types commands and proves the results.
 * Proofs are renderer-independent:
 *   * SIDE-CHANNEL: commands typed in the browser write marker files which
 *     this script verifies on the filesystem — proves browser keystrokes
 *     really executed in the shell, independent of how xterm renders text.
 *   * BUFFER API: when ttyd exposes the xterm instance (window.term) the
 *     terminal text is also read directly from the xterm buffer.
 *   * SCREENSHOTS at every stage (visual evidence).
 *
 * Usage:
 *   node browser-test.js --url https://ops.hanaso.ir:8443 \
 *        --username ops-admin --password-file /tmp/pwfile \
 *        --map-host ops.hanaso.ir --expect-uid 1001 --out /tmp/shots
 * Password is read from a FILE (never argv / logs).
 */
const fs = require('fs');
const path = require('path');
const os = require('os');
const { chromium } = require('playwright');

function arg(name, def) {
  const i = process.argv.indexOf('--' + name);
  return i > -1 ? process.argv[i + 1] : def;
}
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

(async () => {
  const url = arg('url', 'https://ops.hanaso.ir:8443');
  const username = arg('username', 'ops-admin');
  const pwFile = arg('password-file', '');
  const mapHost = arg('map-host', '');
  const expectUid = arg('expect-uid', '0');
  const outDir = arg('out', '/tmp/ops-browser-shots');
  // CP13: the shell writes proof files INSIDE the clean VM; the checker runs
  // on the sandbox side — --file-root prefixes the CHECK paths with the VM's
  // rootfs (the command strings keep the raw /tmp paths the shell sees).
  const fileRoot = arg('file-root', '');
  const pf = (p) => (fileRoot ? (fileRoot.replace(/\/$/, '') + p) : p);
  fs.mkdirSync(outDir, { recursive: true });

  if (!pwFile || !fs.existsSync(pwFile)) {
    console.error('[browser-test] password file missing');
    process.exit(2);
  }
  const password = fs.readFileSync(pwFile, 'utf-8').trim();

  const stamp = Date.now().toString(36);
  const RAW = {
    uid: `/tmp/ops-browser-uid-${stamp}.txt`,
    host: `/tmp/ops-browser-host-${stamp}.txt`,
    file: `/tmp/ops-browser-file-${stamp}.txt`,
    disconnect: `/tmp/ops-browser-disc-${stamp}.txt`,
  };
  const PROOF = Object.fromEntries(Object.entries(RAW).map(([k, v]) => [k, pf(v)]));
  for (const f of Object.values(PROOF)) { try { fs.unlinkSync(f); } catch (e) {} }

  const results = [];
  const ok = (m) => { results.push(['PASS', m]); console.log('  [PASS] ' + m); };
  const bad = (m) => { results.push(['FAIL', m]); console.log('  [FAIL] ' + m); };

  const launchArgs = [];
  if (mapHost) launchArgs.push(`--host-resolver-rules=MAP ${mapHost} 127.0.0.1`);
  // CP13: self-signed TLS mode — accept the panel's own certificate in the
  // clean-VM battery (the production ACME path is NOT affected; the flag is
  // opt-in and test-only).
  const insecure = process.argv.indexOf('--insecure') > -1;
  const browser = await chromium.launch({
    headless: true,
    args: launchArgs,
    ...(insecure ? { ignoreHTTPSErrors: true } : {}),
  });

  // ---- renderer-independent terminal text reader ----
  const readTerminal = async (page) => page.evaluate(() => {
    try {
      const t = (typeof window.term !== 'undefined' && window.term) ||
               (typeof window.terminal !== 'undefined' && window.terminal);
      if (t && t.buffer && t.buffer.active && typeof t.buffer.active.getLine === 'function') {
        const out = [];
        for (let i = 0; i < t.rows; i++) {
          const line = t.buffer.active.getLine(i);
          out.push(line ? line.translateToString(true) : '');
        }
        return out.join('\n');
      }
    } catch (e) { /* fall through */ }
    const rows = document.querySelector('.xterm-rows');
    if (rows) return Array.from(rows.children).map(c => c.textContent).join('\n');
    return '';
  });

  // ---- filesystem side-channel helpers ----
  const waitFileEq = async (f, expected, timeoutMs = 9000) => {
    const t0 = Date.now();
    while (Date.now() - t0 < timeoutMs) {
      try { if (fs.readFileSync(f, 'utf-8').trim() === String(expected).trim()) return true; } catch (e) {}
      await sleep(200);
    }
    return false;
  };
  const waitFileGone = async (f, timeoutMs = 9000) => {
    const t0 = Date.now();
    while (Date.now() - t0 < timeoutMs) {
      if (!fs.existsSync(f)) return true;
      await sleep(200);
    }
    return false;
  };

  let domTextAvailable = false;

  try {
    // ---------- 1. fresh context: no credentials -> login redirect ----------
    let ctx = await browser.newContext({ ignoreHTTPSErrors: true });
    let page = await ctx.newPage();
    await page.goto(url + '/', { waitUntil: 'domcontentloaded' });
    const redirected = page.url().endsWith('/login');
    redirected ? ok('unauthenticated browser redirected to /login (' + page.url() + ')')
               : bad('expected /login redirect, got ' + page.url());
    await page.screenshot({ path: path.join(outDir, '01-login.png') });

    // ---------- 2. login ----------
    await page.fill('#u', username);
    await page.fill('#p', password);
    await Promise.all([
      page.waitForNavigation({ waitUntil: 'domcontentloaded', timeout: 15000 }),
      page.click('button[type=submit]'),
    ]);
    const landed = !page.url().endsWith('/login');
    landed ? ok('login accepted -> terminal page (' + page.url() + ')')
           : bad('login failed, still on ' + page.url());

    // ---------- 3. real terminal appears ----------
    await page.waitForSelector('.xterm', { timeout: 15000 });
    ok('xterm terminal rendered in browser');
    await sleep(2000); // let tmux/bash draw the prompt
    const probe = await readTerminal(page);
    domTextAvailable = probe.trim().length > 0;
    console.log('  [info] terminal text readable via xterm buffer API: ' +
                (domTextAvailable ? 'YES' : 'NO (proofs continue via side-channel files + screenshots)'));

    const typeCmd = async (cmd) => {
      await page.click('.xterm');
      await page.keyboard.type(cmd, { delay: 12 });
      await page.keyboard.press('Enter');
      await sleep(800);
      return readTerminal(page);
    };

    // ---------- 4. type commands; verify via filesystem side-channel ----------
    await typeCmd('id -u > ' + RAW.uid + '; cat ' + RAW.uid);
    const uidFileOk = await waitFileEq(PROOF.uid, expectUid);
    let out = await readTerminal(page);
    const uidDomOk = out.split('\n').some(l => l.trim() === String(expectUid).trim());
    if (uidFileOk || uidDomOk) {
      ok(`id -u -> ${expectUid} (side-channel file proof=${uidFileOk}, terminal text=${uidDomOk})`);
    } else {
      const got = fs.existsSync(PROOF.uid) ? fs.readFileSync(PROOF.uid, 'utf-8').trim() : '(no file)';
      bad(`id -u -> expected ${expectUid}, got ${got}`);
    }
    await page.screenshot({ path: path.join(outDir, '02-terminal.png') });

    await typeCmd('hostname > ' + RAW.host);
    const hostOk = await waitFileEq(PROOF.host, os.hostname());
    hostOk ? ok('hostname -> ' + os.hostname() + ' (side-channel file proof)')
           : bad('hostname file proof failed');

    const marker = 'BROWSER' + Date.now().toString(36);
    await typeCmd('echo ' + marker + ' > ' + RAW.file);
    if (await waitFileEq(PROOF.file, marker)) {
      await typeCmd('rm ' + RAW.file);
      const gone = await waitFileGone(PROOF.file);
      gone ? ok('file create/read/delete proven via side-channel (' + marker + ')')
           : bad('file delete failed (still present)');
    } else {
      bad('file create proof failed (' + PROOF.file + ')');
    }

    // ---------- 5. browser disconnect + reconnect (cookie + tmux survive) ----------
    const stayMarker = 'STAY' + Date.now().toString(36);
    await typeCmd('echo ' + stayMarker + '; sleep 6; echo AFTER_DISCONNECT > ' + RAW.disconnect);
    await page.close();            // tab closed = browser "disconnect"
    await sleep(2500);
    page = await ctx.newPage();    // new tab, same profile (cookie kept)
    await page.goto(url + '/', { waitUntil: 'domcontentloaded' });
    const stillIn = !page.url().endsWith('/login');
    stillIn ? ok('browser reconnect (new tab): session cookie still valid (no re-login)')
            : bad('reconnect required re-login');
    await page.waitForSelector('.xterm', { timeout: 15000 });
    await sleep(2000);
    const discOk = await waitFileEq(PROOF.disconnect, 'AFTER_DISCONNECT', 15000);
    if (discOk) {
      ok('long-running command survived browser disconnect (tmux kept running, side-channel proof)');
    } else {
      out = await readTerminal(page);
      bad('AFTER_DISCONNECT not proven: ' + JSON.stringify(out.slice(-200)));
    }
    await page.screenshot({ path: path.join(outDir, '03-reconnect.png') });

    await ctx.close();
  } catch (e) {
    bad('exception: ' + (e && e.message));
  } finally {
    await browser.close();
    for (const f of Object.values(PROOF)) { try { fs.unlinkSync(f); } catch (e) {} }
  }

  const fails = results.filter(r => r[0] === 'FAIL').length;
  console.log('==============================================');
  console.log(` BROWSER TEST RESULT: PASS=${results.length - fails} FAIL=${fails}`);
  console.log('==============================================');
  process.exit(fails ? 1 : 0);
})();
