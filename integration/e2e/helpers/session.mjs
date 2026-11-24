// Drives the real browser sign-in: the SPA registers an OAuth client, redirects
// to the API's login page, the consent form is approved, and the callback
// exchanges the code. Nothing here injects a token, so a spec that signs in
// proves the whole chain works against the running stack.

import { createHash, randomBytes } from 'node:crypto';

import { expect } from '@playwright/test';

import { BASE_URL, BROWSER_ORIGIN, INSTANCE_HOST } from '../fixtures.mjs';

/// The grant the console requests: the ordinary family plus the administration
/// one. `Authenticated::allows` is hierarchical only within a family, so `read`
/// never answers for `admin:read` — the wider family has to be granted.
const ADMIN_SCOPES = 'read write follow admin:read admin:write';

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

/// Signs `account` in with the administration grant and returns the same
/// session shape [[signIn]] returns.
///
/// The SPA's own sign-in registers a client with the narrow `read write follow`
/// scopes, and the instance refuses an authorization request broader than the
/// registration (`nodus-backend/crates/auth/src/lib.rs`, `authorize`). So this
/// walks the same five steps by hand instead of reusing the SPA page: register
/// an application with the wider set, log in at `/auth/login`, approve the
/// consent form, exchange the code for a token, store the record.
///
/// Everything happens in the browser at the lab's canonical origin, which is
/// the origin the app is registered against and the one the redirect returns
/// to. The callback path is deliberately not `/oauth/callback`: the SPA's own
/// callback expects its private pending record, and the code is read from the
/// consent response's `Location` before anything navigates there.
export async function signInWithAdminScopes(page, account) {
  // Land on the canonical origin first: the fetches below are relative, and a
  // fresh page starts at about:blank where they would have no origin.
  await page.goto('/sign-in');
  const redirectUri = `${BROWSER_ORIGIN}/oauth/admin-grant-callback`;

  const app = await page.evaluate(
    async ({ clientName, redirectUri, scopes }) => {
      const response = await fetch('/api/v1/apps', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          client_name: clientName,
          redirect_uris: redirectUri,
          scopes,
        }),
      });
      if (!response.ok) {
        throw new Error(
          `registering the admin-scoped app failed with HTTP ${response.status}: ` +
            (await response.text()),
        );
      }
      return response.json();
    },
    {
      clientName: 'nodus e2e admin grant',
      redirectUri,
      scopes: ADMIN_SCOPES,
    },
  );

  const verifier = base64url(randomBytes(32));
  const challenge = base64url(createHash('sha256').update(verifier).digest());
  const state = base64url(randomBytes(16));
  const authorize = new URL('/oauth/authorize', BROWSER_ORIGIN);
  authorize.search = new URLSearchParams({
    response_type: 'code',
    client_id: app.client_id,
    redirect_uri: redirectUri,
    scope: ADMIN_SCOPES,
    state,
    code_challenge: challenge,
    code_challenge_method: 'S256',
  }).toString();

  // A signed-out browser is redirected to the server-rendered login form with
  // the authorization request in return_to, exactly as the SPA's handoff is.
  await page.goto(authorize.toString());
  await page.waitForURL(/\/auth\/login/, { timeout: 30_000 });
  await page.locator('input[name="email"]').fill(account.email);
  await page.locator('input[name="password"]').fill(account.password);
  await page.locator('form').getByRole('button', { name: 'Sign in' }).click();

  // The consent page lists the scopes and answers the approval with a 303 to
  // the registered redirect_uri, carrying the code. Read it off the response so
  // this helper does not depend on the page that happens to receive it.
  await page.waitForURL(/\/oauth\/authorize/, { timeout: 30_000 });
  await expect(page.getByRole('button', { name: 'Allow' })).toBeVisible({
    timeout: 15_000,
  });
  const consent = page.waitForResponse(
    (response) =>
      response.request().method() === 'POST' &&
      new URL(response.url()).pathname === '/oauth/authorize',
    { timeout: 30_000 },
  );
  await page.getByRole('button', { name: 'Allow' }).click();
  const location = (await consent).headers().location;
  if (!location) throw new Error('the consent response carried no Location');
  const callback = new URL(location, BROWSER_ORIGIN);
  const code = callback.searchParams.get('code');
  if (!code) throw new Error(`no authorization code in ${location}`);

  const token = await page.evaluate(
    async ({ code, clientId, redirectUri, verifier }) => {
      const body = new URLSearchParams({
        grant_type: 'authorization_code',
        code,
        client_id: clientId,
        redirect_uri: redirectUri,
        code_verifier: verifier,
      });
      const response = await fetch('/oauth/token', {
        method: 'POST',
        headers: { 'content-type': 'application/x-www-form-urlencoded' },
        body,
      });
      if (!response.ok) {
        throw new Error(
          `the token exchange failed with HTTP ${response.status}: ` +
            (await response.text()),
        );
      }
      return (await response.json()).access_token;
    },
    { code, clientId: app.client_id, redirectUri, verifier },
  );

  const me = await page.evaluate(async (bearer) => {
    const response = await fetch('/api/v1/accounts/verify_credentials', {
      headers: { Authorization: `Bearer ${bearer}` },
    });
    if (!response.ok) {
      throw new Error(
        `the admin-scoped token was refused by verify_credentials: HTTP ${response.status}`,
      );
    }
    return response.json();
  }, token);

  await page.evaluate(
    ({ record }) => window.localStorage.setItem('nodus.session', record),
    {
      // The same five-line record `readSession` parses below; none of these
      // fields contains a character the format escapes.
      record: ['nodus-session/2', INSTANCE_HOST, token, me.id, me.acct].join('\n'),
    },
  );
  // Reload so the shell adopts the record the way it does after the SPA's own
  // callback, and the caller is left signed in rather than on a stray URL.
  await page.goto('/home');
  await expect(page.getByRole('link', { name: 'Home', exact: true })).toBeVisible();

  const session = await readSession(page);
  expect(session.token, 'the stored session is the admin-scoped token').toBe(token);
  return session;
}

/// RFC 7636's base64url, without padding.
function base64url(bytes) {
  return bytes
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
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
