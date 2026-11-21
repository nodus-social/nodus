// Functional: the three timeline tabs and what the client does when a tab is
// revisited. The seeded graph is Ada follows Grace and Admin, so Home carries
// both followed authors, Local carries every local author and Federated the
// public view of them.
//
// The unfollow test arranges its state with the API and then signs in from a
// fresh browser context: the client caches a timeline for the session, so the
// only way to prove what the server returns after an unfollow is a new boot.

import { expect, test } from '@playwright/test';

import { ACCOUNTS, BROWSER_ORIGIN, POSTS } from '../fixtures.mjs';
import { authHeaders, lookupAccount } from '../helpers/api.mjs';
import { navigate } from '../helpers/navigation.mjs';
import { API_BASE, signIn } from '../helpers/session.mjs';

// The seeded Home timeline is covered by home.spec.mjs. What this row adds is
// the tab copy and the federated view, and those do not exist as promised: the
// Local tab renders no caption at this build, and Federated lists local posts
// only (integration/docs/e2e-gaps.md).
test.fixme(
  'the Local tab renders no caption and Federated serves local posts',
  async ({ page }) => {
  await signIn(page, ACCOUNTS.ada);

  // Ada follows both seeded authors, so both posts are on Home.
  await expect(page.getByText(POSTS.graceFirst)).toBeVisible();
  await expect(page.getByText(POSTS.adminFirst)).toBeVisible();

  await page.getByRole('tab', { name: 'Local' }).click();
  await page.waitForURL(/\/home\/local$/);
  await expect(page.getByText('Posts from this instance.')).toBeVisible();
  await expect(page.getByText(POSTS.graceFirst)).toBeVisible();
  await expect(page.getByText(POSTS.adminFirst)).toBeVisible();

  // The tab strip only exists on /home; the sidebar link returns there.
  await page.getByRole('link', { name: 'Home', exact: true }).click();
  await page.waitForURL(/\/home$/);
  await page.getByRole('tab', { name: 'Federated' }).click();
  await page.waitForURL(/\/home\/federated$/);
  await expect(page.getByText('Posts from this instance.')).toBeVisible();
  await expect(page.getByText(POSTS.graceFirst)).toBeVisible();
  await expect(page.getByText(POSTS.adminFirst)).toBeVisible();
  },
);

// POST /api/v1/accounts/:id/unfollow returns non-2xx at this build, so the
// state this row arranges through the API never exists. Owner: API.
test.fixme(
  'unfollow returns non-2xx, so the edge cannot be removed through the API',
  async ({ page, browser }) => {
  const session = await signIn(page, ACCOUNTS.ada);
  const admin = await lookupAccount(page.request, session, 'admin');

  const unfollow = await page.request.post(
    `${API_BASE}/api/v1/accounts/${admin.id}/unfollow`,
    { headers: authHeaders(session) },
  );
  expect(unfollow.ok(), 'ada can unfollow the admin account').toBe(true);

  try {
    // A fresh context has no cached timeline, so this is the server's answer
    // for Ada's follow set after the unfollow.
    const context = await browser.newContext({ baseURL: BROWSER_ORIGIN });
    const fresh = await context.newPage();
    await signIn(fresh, ACCOUNTS.ada);

    await expect(fresh.getByText(POSTS.graceFirst)).toBeVisible();
    await expect(fresh.getByText(POSTS.adminFirst)).toHaveCount(0);

    await navigate(fresh, '/home/local');
    await expect(fresh.getByText(POSTS.adminFirst)).toBeVisible();
    await expect(fresh.getByText(POSTS.graceFirst)).toBeVisible();

    await navigate(fresh, '/home/federated');
    await expect(fresh.getByText(POSTS.adminFirst)).toBeVisible();
    await context.close();
  } finally {
    await page.request.post(`${API_BASE}/api/v1/accounts/${admin.id}/follow`, {
      headers: authHeaders(session),
    });
  }
  },
);

test('a revisited timeline is served from the store, not fetched again', async ({
  page,
}) => {
  const requests = [];
  page.on('request', (request) => {
    if (new URL(request.url()).pathname === '/api/v1/timelines/home') {
      requests.push(request.url());
    }
  });

  await signIn(page, ACCOUNTS.ada);
  await expect(page.getByText(POSTS.graceFirst)).toBeVisible();

  // Measured behaviour at this build: boot asks for the home timeline twice
  // (the duplication recorded in web/e2e/tests/loading.spec.mjs, whose fixme
  // "a timeline is fetched once, and revisited from the store" is still open),
  // and revisiting Home adds no third request because the store serves it.
  // The seed is smaller than one page, so pagination is not exercised here.
  const atBoot = requests.length;
  expect(atBoot, 'boot fetched the home timeline').toBeGreaterThan(0);
  await expect(page.getByRole('button', { name: 'Load more' })).toHaveCount(0);

  await page.getByRole('tab', { name: 'Local' }).click();
  await page.waitForURL(/\/home\/local$/);
  await page.getByRole('link', { name: 'Home', exact: true }).click();
  await page.waitForURL(/\/home$/);

  await expect(page.getByText(POSTS.graceFirst)).toBeVisible();
  expect(
    requests.length,
    'returning to Home reused the stored timeline instead of fetching it',
  ).toBe(atBoot);
});
