// Drives the real browser sign-in: the SPA registers an OAuth client, redirects
// to the API's login page, the consent form is approved, and the callback
// exchanges the code. Nothing here injects a token, so a spec that signs in
// proves the whole chain works against the running stack.

import { expect } from '@playwright/test';

import { BASE_URL, INSTANCE_HOST } from '../fixtures.mjs';

/// Signs `account` in through the UI and returns the bearer token the SPA
/// stored. The token is useful for asserting the same data through the API.
export async function signIn(page, account) {
  await page.goto('/sign-in');
  await page.locator('input[placeholder="mastodon.social"]').first().fill(INSTANCE_HOST);
  await page.getByRole('button', { name: 'Authorize' }).click();

  // The SPA hands off to the API's own server-rendered login form, carrying the
  // pending authorize request in return_to.
  await page.waitForURL(/\/auth\/login/, { timeout: 30_000 });
  await page.locator('input[name="email"]').fill(account.email);
  await page.locator('input[name="password"]').fill(account.password);
  await page.locator('form').getByRole('button', { name: 'Sign in' }).click();

  // The login POST redirects to the consent page, which lists the scopes and
  // offers Allow/Deny.
  await page.waitForURL(/\/oauth\/authorize/, { timeout: 30_000 });
  await expect(page.getByRole('button', { name: 'Allow' })).toBeVisible({
    timeout: 15_000,
  });
  await page.getByRole('button', { name: 'Allow' }).click();

  // The callback exchanges the code and the SPA navigates home. With the
  // recommendation extension enabled the default landing is /home/feed, so the
  // helper takes the Home tab. The tab is a client-side navigation on purpose:
  // a full reload re-reads the stored host through the SDK, which assumes https
  // for any host without a scheme (see integration/README.md, limitations).
  await page.waitForURL(/\/home(\/|$)/, { timeout: 30_000 });
  await page.getByRole('link', { name: 'Home', exact: true }).click();
  await page.waitForURL(/\/home$/, { timeout: 30_000 });
  const session = await readSession(page);
  expect(session.token, 'the SPA stored a token after the callback').toBeTruthy();
  return session;
}

/// Reads the hand-written localStorage session record: a prefix line, the
/// host, the token, the account id and the acct — see
/// web/crates/web-client/src/state/bridge/session/record.rs. It is asserted
/// here rather than imported because it is a storage detail, not an API.
export async function readSession(page) {
  return page.evaluate(() => {
    const raw = window.localStorage.getItem('nodus.session');
    if (!raw) return null;
    const [prefix, host, token, accountId, acct] = raw.split('\n');
    return { prefix, host, token, accountId, acct };
  });
}

/// Convenience for specs that need the base URL next to the token.
export const API_BASE = BASE_URL;
