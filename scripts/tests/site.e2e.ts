import { test } from '@e2e-dev/web';
import { expect } from 'e2e';

test('marketing navigation, release links, privacy and terms', async ({ app, browser, screen }) => {
  await app.open('/');
  await expect(screen.getByRole('heading', /Agents get access/)).toBeVisible();
  // The mock prompts read exactly as macOS shows the app's Touch ID reasons.
  const importPrompt = 'Keysrs is trying to import and wrap 2 keys for project evals: openai, anthropic.';
  const relayPrompt = 'Keysrs is trying to connect the relay to keysrs-relay.you.workers.dev.';
  await expect(browser.locator('.touch p:first-of-type')).toHaveCount(2);
  await expect(browser.locator('.touch p:first-of-type').nth(0)).toHaveText(importPrompt);
  await expect(browser.locator('.touch p:first-of-type').nth(1)).toHaveText(relayPrompt);
  await expect(browser.locator('#relay')).toBeVisible();
  await expect(browser.locator('body')).not.toContainText('is trying to Grant');
  // The tool table lists the server's sixteen tools; none of them reads or copies a key.
  await expect(browser.locator('#tools tr')).toHaveCount(17);
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
  await expect(screen.getByRole('heading', /Agents get access/)).toBeVisible();
});
