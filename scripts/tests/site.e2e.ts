import { test } from '@e2e-dev/web';
import { expect } from 'e2e';

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
  await expect(browser.locator('[role=tablist]')).toHaveCount(1);
  await expect(browser.locator('[role=tab]')).toHaveCount(3);
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
  // The installer is served from the same site, as plain text.
  await app.open('/install');
  await expect(browser.locator('body')).toContainText('curl -fsSL https://keysrs.com/install | bash');
});
