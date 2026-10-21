import { test } from '@e2e-dev/web';
import { expect } from 'e2e';

test('marketing navigation, release links, privacy and terms', async ({ app, browser, screen }) => {
  await app.open('/');
  await expect(screen.getByRole('heading', /Dummy keys for your VMs/)).toBeVisible();
  // The mock prompts read exactly as macOS shows the app's Touch ID reasons.
  const relayPrompt = 'Keysrs is trying to connect the relay to keysrs-relay.you.workers.dev.';
  const grantPrompt = 'Keysrs is trying to grant "run evals" the key codex-astra for OpenAI at api.openai.com, 30 min.';
  const wrapPrompt = 'Keysrs is trying to match 1 value in .env against the vault and wrap them.';
  await expect(browser.locator('.touch p:first-of-type')).toHaveCount(3);
  await expect(browser.locator('.touch p:first-of-type').nth(0)).toHaveText(relayPrompt);
  await expect(browser.locator('.touch p:first-of-type').nth(1)).toHaveText(wrapPrompt);
  await expect(browser.locator('.touch p:first-of-type').nth(2)).toHaveText(grantPrompt);
  await expect(browser.locator('#relay')).toBeVisible();
  await expect(browser.locator('body')).not.toContainText('is trying to Grant');
  const download = browser.locator('a[href$="Keysrs-arm64.dmg"]');
  await expect(download.first()).toHaveAttribute('href', 'https://github.com/gshost1/Keysreallysafe/releases/latest/download/Keysrs-arm64.dmg');
  await expect(download).toHaveCount(3);
  await browser.locator('.nav a[href="#features"]').click();
  await expect(browser.locator('#features')).toBeVisible();
  await browser.locator('.nav a[href="#faq"]').click();
  await expect(browser.locator('#faq')).toBeVisible();
  await browser.locator('footer a[href="/privacy"]').click();
  await expect(screen.getByRole('heading', 'Privacy', { exact: true })).toBeVisible();
  await expect(browser.locator('body')).toContainText('no session replays');
  await browser.locator('footer a[href="/terms"]').click();
  await expect(screen.getByRole('heading', 'Terms', { exact: true })).toBeVisible();
  await browser.locator('footer a[href="/"]').click();
  await expect(screen.getByRole('heading', /Dummy keys for your VMs/)).toBeVisible();
});
