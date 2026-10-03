import { test, type Browser } from '@e2e-dev/web';
import { expect, type App } from 'e2e';

async function reset(app: App) {
  const reply = await fetch(new URL('/__fixture/reset', app.baseUrl), { method: 'POST' });
  await expect(reply.status).toBe(200);
  await app.open('/');
}
const row = (browser: Browser, name: string) => browser.locator(`#keys-body tr[data-name="${name}"]`).first();

test('vault creation, metadata edit and confirmed deletion round trip', async ({ app, browser, screen }) => {
  await reset(app);
  await screen.getByRole('tab', 'Keys').click();
  await expect(browser.locator('#keys-count')).toHaveText('3 keys');
  await browser.locator('#btn-add').click();
  await browser.locator('#add-form [name=name]').fill('delta');
  await browser.locator('#add-form [name=provider]').fill('openai');
  await browser.locator('#add-form [name=secret]').fill('sk-fixture-NEVER-REAL-0000000000');
  await browser.locator('#add-form [type=submit]').click();
  await expect(row(browser, 'delta')).toBeVisible();
  await browser.locator('#keys-body tr[data-name="delta"] [data-act=edit]').first().click();
  await browser.locator('#edit-form [name=notes]').fill('edited synthetic note');
  await browser.locator('#edit-form [type=submit]').click();
  await expect(browser.locator('#status')).toHaveText('Saved delta.');
  const saved = await (await fetch(new URL('/api/keys', app.baseUrl))).json();
  await expect(saved.keys.find((k: any) => k.name === 'delta').notes).toBe('edited synthetic note');
  await browser.locator('#keys-body tr[data-name="delta"] [data-act=delete]').first().click();
  await expect(browser.locator('#delete-name')).toHaveText('delta');
  await browser.locator('#delete-confirm').click();
  await expect(row(browser, 'delta')).not.toBeVisible();
  await expect(browser.locator('#keys-count')).toHaveText('3 keys');
});

test('reveal close clears the synthetic value and rotation finishes', async ({ app, browser, screen }) => {
  await reset(app);
  await screen.getByRole('tab', 'Keys').click();
  await browser.locator('#keys-body tr[data-name="alpha"] [data-act=reveal]').first().click();
  await expect(browser.locator('#reveal-secret')).toHaveText('sk-fixture-NEVER-REAL-0000000000');
  await browser.locator('#dlg-reveal [data-close]').click();
  await expect(browser.locator('#reveal-secret')).toHaveText('');
  await browser.locator('#keys-body tr[data-name="alpha"] [data-act=rotate]').first().click();
  await browser.locator('#rotate-form [name=secret]').fill('sk-fixture-NEVER-REAL-0000000000');
  await browser.locator('#rotate-form [type=submit]').click();
  await expect(browser.locator('#status')).toContainText('Rotated alpha');
  await expect(browser.locator('#dlg-rotate')).not.toBeVisible();
});

test('gateway spend preserves unknown costs through source filtering', async ({ app, browser, screen }) => {
  await reset(app);
  await screen.getByRole('tab', 'Chart').click();
  await screen.getByRole('radio', 'API keys').click();
  await expect(browser.locator('body')).toContainText('system-one');
  await expect(browser.locator('#chart-error')).toHaveText('');
  await screen.getByRole('radio', 'USD', { exact: true }).click();
  await expect(browser.locator('#totals')).toContainText('6 requests');
  await expect(browser.locator('#totals')).toContainText('2 requests unpriced');
  await screen.getByRole('radio', 'Show only calls routed to TypeSafe').click();
  await expect(browser.locator('#totals')).toContainText('cost unknown');
  await expect(browser.locator('#totals')).toContainText('2 requests');
  const payload = await (await fetch(new URL('/api/spend?source=keys&by=model', app.baseUrl))).json();
  await expect(payload.totals.gateway_calls).toBe(6);
  await expect(payload.totals.gateway_unpriced_calls).toBe(2);
  await expect(payload.rows.find((r: any) => r.provider === 'typesafe').usd_estimate).toBe(null);
});

test('duplicate key is refused and the add dialog stays usable', async ({ app, browser, screen }) => {
  await reset(app);
  await screen.getByRole('tab', 'Keys').click();
  await browser.locator('#btn-add').click();
  await browser.locator('#add-form [name=name]').fill('alpha');
  await browser.locator('#add-form [name=provider]').fill('openai');
  await browser.locator('#add-form [name=secret]').fill('sk-fixture-NEVER-REAL-0000000000');
  await browser.locator('#add-form [type=submit]').click();
  await expect(browser.locator('#add-err')).toContainText('already');
  await expect(browser.locator('#add-form [type=submit]')).toBeEnabled();
});
