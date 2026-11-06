import { test } from '@e2e-dev/web';
import { expect } from 'e2e';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { createContext, runInContext } from 'node:vm';

test('marketing navigation, release links, privacy and terms', async ({ app, browser, screen }) => {
  await app.open('/');
  // The headline wording is still placeholder copy, so check the place, not the words.
  await expect(browser.locator('.hero h1')).toBeVisible();
  // The main action is the tap that exists, and the command copies as shown.
  await expect(browser.locator('#brew-cmd')).toHaveText('brew install --cask gshost1/keysrs/keysrs');
  await expect(browser.locator('[data-copy="brew-cmd"]')).toBeVisible();
  await expect(browser.locator('html')).toHaveAttribute('data-platform', /^(mac|windows|linux|ios|android|other)$/);
  // The mock prompts read exactly as macOS shows the app's Touch ID reasons.
  const importPrompt = 'Keysrs is trying to import and wrap 2 keys for project evals: openai, anthropic.';
  const relayPrompt = 'Keysrs is trying to connect the relay to keysrs-relay.you.workers.dev.';
  await expect(browser.locator('.touch p:first-of-type')).toHaveCount(3);
  await expect(browser.locator('.touch p:first-of-type').nth(0)).toHaveText(importPrompt);
  await expect(browser.locator('.touch p:first-of-type').nth(1)).toHaveText(importPrompt);
  await expect(browser.locator('.touch p:first-of-type').nth(2)).toHaveText(relayPrompt);
  await expect(browser.locator('#relay')).toBeVisible();
  await expect(browser.locator('body')).not.toContainText('is trying to Grant');
  // The tool table lists the server's fifteen tools; none of them reads or copies a key.
  await expect(browser.locator('#tools tr')).toHaveCount(16);
  await expect(browser.locator('#tools table')).not.toContainText('reveal');
  await expect(browser.locator('a.btn.star').first()).toHaveAttribute('href', 'https://github.com/gshost1/Keysreallysafe');
  const download = browser.locator('a[href$="Keysrs-arm64.dmg"]');
  await expect(download.first()).toHaveAttribute('href', 'https://github.com/gshost1/Keysreallysafe/releases/latest/download/Keysrs-arm64.dmg');
  await expect(download).toHaveCount(3);
  await browser.locator('.nav a[href="#tools"]').click();
  await expect(browser.locator('#tools')).toBeVisible();
  await browser.locator('.nav a[href="#faq"]').click();
  await expect(browser.locator('#faq')).toBeVisible();
  await browser.locator('footer a[href="/privacy"]').click();
  await expect(screen.getByRole('heading', 'Privacy', { exact: true })).toBeVisible();
  // The site's analytics are consent-gated; the privacy page must say what OK turns on.
  await expect(browser.locator('#website')).toBeVisible();
  await expect(browser.locator('body')).toContainText('All text on the page and everything typed into inputs is masked');
  await browser.locator('footer a[href="/terms"]').click();
  await expect(screen.getByRole('heading', 'Terms', { exact: true })).toBeVisible();
  await browser.locator('footer a[href="/"]').click();
  await expect(browser.locator('#brew-cmd')).toBeVisible();
});

test('install tabs: brew, curl and DMG, with keyboard arrows and a copy button each', async ({ app, browser }) => {
  await app.open('/');
  const tab = (name: string) => browser.locator(`#tab-${name}`);
  const panel = (name: string) => browser.locator(`#panel-${name}`);
  await expect(browser.locator('[role=tablist]')).toHaveCount(2);
  await expect(browser.locator('[role=tab]')).toHaveCount(6);
  // brew is the default: selected, its command shown, the others hidden.
  await expect(tab('brew')).toHaveAttribute('aria-selected', 'true');
  await expect(panel('brew')).toBeVisible();
  await expect(panel('curl')).toBeHidden();
  await expect(panel('dmg')).toBeHidden();
  await expect(browser.locator('#panel-brew .icopy')).toBeVisible();
  await expect(panel('brew')).toContainText('--adopt');
  // Click: curl shows its command, a copy button and the script link.
  await tab('curl').click();
  await expect(tab('curl')).toHaveAttribute('aria-selected', 'true');
  await expect(tab('brew')).toHaveAttribute('aria-selected', 'false');
  await expect(panel('curl')).toBeVisible();
  await expect(panel('brew')).toBeHidden();
  await expect(browser.locator('#curl-cmd')).toHaveText('curl -fsSL https://keysrs.com/install | bash');
  await expect(browser.locator('#panel-curl .icopy')).toBeVisible();
  await expect(browser.locator('#panel-curl a[href="/install"]')).toBeVisible();
  // Keyboard: arrows move the selection and wrap, Home and End jump.
  await tab('curl').focus();
  await tab('curl').press('ArrowRight');
  await expect(tab('dmg')).toHaveAttribute('aria-selected', 'true');
  await expect(tab('dmg')).toBeFocused();
  await expect(panel('dmg')).toBeVisible();
  await tab('dmg').press('ArrowRight');
  await expect(tab('brew')).toHaveAttribute('aria-selected', 'true');
  await tab('brew').press('End');
  await expect(tab('dmg')).toBeFocused();
  await tab('dmg').press('Home');
  await expect(tab('brew')).toBeFocused();
  // DMG: the download link keeps its frozen name and URL.
  await tab('dmg').click();
  await expect(browser.locator('#panel-dmg a.idl')).toHaveAttribute('href', 'https://github.com/gshost1/Keysreallysafe/releases/latest/download/Keysrs-arm64.dmg');
  await expect(panel('dmg')).toContainText('macOS 14+, Apple Silicon');
  // Agent tabs operate independently of the install method.
  await expect(panel('claude')).toBeVisible();
  await expect(browser.locator('#panel-claude .icopy')).toHaveCount(2);
  await expect(browser.locator('#claude-cmd-0')).toHaveText('/plugin marketplace add gshost1/Keysreallysafe');
  await expect(browser.locator('#claude-cmd-1')).toHaveText('/plugin install keysrs@keysrs');
  await tab('claude').focus();
  await tab('claude').press('ArrowRight');
  await expect(panel('codex')).toBeVisible();
  await expect(panel('claude')).toBeHidden();
  await expect(panel('dmg')).toBeVisible();
  await expect(browser.locator('#codex-cmd-0')).toHaveText('codex plugin marketplace add gshost1/Keysreallysafe');
  await expect(browser.locator('#codex-cmd-1')).toHaveText('codex plugin add keysrs@keysrs');
  await expect(browser.locator('#panel-codex .icopy')).toHaveCount(2);
  await tab('codex').press('End');
  await expect(panel('other')).toBeVisible();
  await expect(browser.locator('#other-cmd-0')).toHaveText('keys setup mcp');
  await expect(browser.locator('#panel-other .icopy')).toHaveCount(1);
  await tab('other').press('ArrowRight');
  await expect(tab('claude')).toBeFocused();
  // The installer is served from the same site, as plain text.
  await app.open('/install');
  await expect(browser.locator('body')).toContainText('curl -fsSL https://keysrs.com/install | bash');
});

// posthog.js runs here in a bare VM: the PostHog snippet only queues its
// calls, so the recording config can be read without loading array.js or
// sending anything. The notify form puts the visitor's address in a fetch body
// while a consented recording runs; privacy.html says the address never reaches
// PostHog and lists no network entries, so the recorder must capture no bodies
// or headers whatever the project's remote setting, and keep no network entry.
function loadPosthog(consent: string | null) {
  const noop = () => {};
  const buttons: any[] = [];
  const element = () => {
    const el: any = { setAttribute: noop, appendChild: noop, remove: noop, addEventListener: (_: string, fn: () => void) => { el.click = fn; } };
    buttons.push(el);
    return el;
  };
  const ctx: any = {
    URLSearchParams,
    location: { search: '' },
    localStorage: { getItem: (k: string) => (k === 'keysrs-analytics-consent' ? consent : null), setItem: noop, removeItem: noop },
    getSelection: () => ({ anchorNode: null }),
    document: {
      readyState: 'complete',
      createElement: element,
      createTextNode: () => ({}),
      getElementsByTagName: () => [{ parentNode: { insertBefore: noop } }],
      getElementById: () => null,
      querySelectorAll: () => [],
      addEventListener: noop,
      body: { appendChild: noop },
      documentElement: { getAttribute: () => null },
    },
  };
  ctx.window = ctx;
  createContext(ctx);
  runInContext(readFileSync(fileURLToPath(new URL('../../Site/posthog.js', import.meta.url)), 'utf8'), ctx);
  return { ctx, ok: () => buttons.find((b) => b.textContent === 'OK').click() };
}

function expectNoNetworkCapture(sr: any) {
  expect(sr.recordBody).toBe(false);
  expect(sr.recordHeaders).toBe(false);
  expect(typeof sr.maskCapturedNetworkRequestFn).toBe('function');
  expect(sr.maskCapturedNetworkRequestFn({
    name: 'https://keysrs.com/api/notify', requestBody: '{"email":"notify-test@example.invalid"}',
  })).toBeNull();
  expect(sr.maskCapturedNetworkRequestFn({ name: 'https://keysrs.com/', requestBody: 'a' })).toBeNull();
}

test('consented session recording never captures network entries or the notify address', async () => {
  // Consent stored on an earlier visit: init gets the full config.
  const returning = loadPosthog('yes').ctx;
  const config = returning.posthog._i[0][1];
  expect(config.disable_session_recording).toBe(false);
  expectNoNetworkCapture(config.session_recording);

  // First visit: OK in the banner switches recording on through set_config.
  const first = loadPosthog(null);
  expect(first.ctx.posthog._i[0][1].disable_session_recording).toBe(true);
  first.ok();
  const call = first.ctx.posthog.find((c: any[]) => c[0] === 'set_config');
  expect(call[1].disable_session_recording).toBe(false);
  expectNoNetworkCapture(call[1].session_recording);
});
