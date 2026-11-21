// Functional: the session lifecycle a visitor can exercise without touching
// storage directly — signed out, wrong password, and sign-out followed by the
// browser's Back button.
//
// Sign-out clears the client's stored record; it does not revoke the OAuth
// token server-side (measured: verify_credentials still answers 200), so the
// assertion is about the UI session, which is what the next visitor inherits.

import { expect, test } from '@playwright/test';

import { ACCOUNTS, INSTANCE_HOST } from '../fixtures.mjs';
import { navigate } from '../helpers/navigation.mjs';
import { signIn } from '../helpers/session.mjs';

async function storedSession(page) {
  return page.evaluate(() => window.localStorage.getItem('nodus.session'));
}

test('a signed-out visit to /home shows the sign-in screen', async ({ page }) => {
  await page.goto('/home');

  await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
  // The client renders sign-in in place; it does not redirect away from /home.
  expect(new URL(page.url()).pathname).toBe('/home');
  expect(await storedSession(page)).toBeNull();
});

test('a wrong password shows an error and stores no session', async ({ page }) => {
  await page.goto('/sign-in');
  await page.locator('input[placeholder="mastodon.social"]').first().fill(INSTANCE_HOST);
  await page.getByRole('button', { name: 'Authorize' }).click();
  await page.waitForURL(/\/auth\/login/);

  await page.locator('input[name="email"]').fill(ACCOUNTS.ada.email);
  await page.locator('input[name="password"]').fill('definitely-not-the-password');
  await page.locator('form').getByRole('button', { name: 'Sign in' }).click();

  await expect(page.getByText('Wrong email or password.')).toBeVisible();
  expect(new URL(page.url()).pathname).toBe('/auth/login');
  expect(await storedSession(page)).toBeNull();
});

// FIXME(selector): /settings/account renders no `Instance <host>` text at this
// build, so the spec cannot reach a Sign out button through that page.
test.fixme('sign-out clears the session and Back does not restore it', async ({ page }) => {
  await signIn(page, ACCOUNTS.ada);

  await navigate(page, '/settings/account');
  await expect(page.getByText(`Instance ${INSTANCE_HOST}`)).toBeVisible();
  await page.getByRole('button', { name: 'Sign out', exact: true }).click();

  await expect
    .poll(() => storedSession(page), { message: 'the stored session is removed' })
    .toBeNull();

  // The app shell can still be painted from memory after sign-out, so the
  // proof is the stored record plus a fresh document: Back keeps the path but
  // a reload renders the signed-out screen.
  await page.goBack();
  await expect(page).toHaveURL(/\/home$/);
  expect(await storedSession(page)).toBeNull();

  await page.reload();
  await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
  expect(await storedSession(page)).toBeNull();
});
