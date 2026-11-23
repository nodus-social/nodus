// Functional: the preferences editor writes one key per change, reads the value
// back from the control after a reload, and files a refusal under the row that
// asked instead of raising a toast.
//
// The page is hydrated client-side (the SSR document names the shell, not the
// cards), so every assertion here is a browser assertion: a server-side GET
// would pass even if the editor never painted.
//
// Preferences are stored per account and earlier runs leave values behind, so
// the arrangement writes the canonical map through the real API before the page
// boots. That is why the spec passes twice in a row: it does not depend on the
// state the previous run left.

import { expect, test } from '@playwright/test';

import { ACCOUNTS } from '../fixtures.mjs';
import { navigate } from '../helpers/navigation.mjs';
import { API_BASE, signIn } from '../helpers/session.mjs';

// The account's own defaults, as `GET /api/v1/preferences` reports them
// (sdk/crates/client-core/src/model/preferences.rs, `impl Default`).
const DEFAULTS = {
  'posting:default:visibility': 'public',
  'posting:default:sensitive': false,
  'posting:default:language': null,
  'posting:default:quote_policy': 'public',
  'reading:expand:media': 'default',
  'reading:expand:spoilers': false,
  'reading:autoplay:gifs': false,
  'notification:email': true,
  'notification:report': true,
};

const VISIBILITY = 'select[aria-label="Default visibility"]';
const QUOTE_POLICY = 'select[aria-label="Who may quote new posts"]';
const QUOTE_ROW = '[data-preference="posting:default:quote_policy"]';

const REFUSAL = 'unknown preference: posting:default:quote_policy';

async function seed(page, session, values) {
  const response = await page.request.put(`${API_BASE}/api/v1/preferences`, {
    headers: { Authorization: `Bearer ${session.token}` },
    data: values,
  });
  expect(
    response.ok(),
    `PUT /api/v1/preferences seeds ${JSON.stringify(values)}`,
  ).toBe(true);
}

async function openPreferences(page) {
  await expect(page.getByRole('heading', { name: 'Preferences' })).toBeVisible({
    timeout: 30_000,
  });
  // The card is painted only after the read settles; the last row is the one
  // that proves the whole form exists.
  await expect(page.locator('[data-preference="notification:report"]')).toBeVisible();
}

test('the three groups paint their controls, and one change sends one key that survives a reload', async ({
  page,
}) => {
  const session = await signIn(page, ACCOUNTS.ada);
  await seed(page, session, DEFAULTS);

  try {
    await navigate(page, '/settings/preferences');
    await openPreferences(page);

    // Three groups with their headings, nine rows in total, split 4/3/2.
    const groups = page.locator('[data-preference-group]');
    await expect(groups).toHaveCount(3);
    for (const [name, rows] of [
      ['Posting defaults', 4],
      ['Reading', 3],
      ['Notifications', 2],
    ]) {
      const group = page.locator(`[data-preference-group="${name}"]`);
      await expect(group, `${name} is painted`).toBeVisible();
      await expect(group.getByRole('heading', { name })).toBeVisible();
      await expect(group.locator('[data-preference]')).toHaveCount(rows);
    }
    await expect(page.locator('[data-preference]')).toHaveCount(9);

    // The inert sentence: one note, naming both stored-but-inert settings.
    const note = page.locator('[data-preference-note]');
    await expect(note).toHaveCount(1);
    await expect(note).toContainText('stored, but they have no effect');
    await expect(note).toContainText('notification email');
    await expect(note).toContainText('report notifications');

    // One change is one key: intercept the wire request rather than inferring
    // it from the rendered state.
    const put = page.waitForRequest(
      (request) =>
        request.method() === 'PUT' &&
        new URL(request.url()).pathname === '/api/v1/preferences',
      { timeout: 15_000 },
    );
    await page.locator(VISIBILITY).selectOption('unlisted');
    const request = await put;
    const body = request.postDataJSON();
    expect(
      Object.keys(body),
      'the body carries only the key the reader changed',
    ).toEqual(['posting:default:visibility']);
    expect(body).toEqual({ 'posting:default:visibility': 'unlisted' });
    await expect(page.getByText('Saved.', { exact: true })).toBeVisible();

    // The value survives a document reload, read from the control the reader
    // would see rather than from a server call.
    await page.reload({ waitUntil: 'domcontentloaded' });
    await openPreferences(page);
    await expect(page.locator(VISIBILITY)).toHaveValue('unlisted');
  } finally {
    await seed(page, session, DEFAULTS);
  }
});

test('a refused change is the row sentence, the control goes back, and no toast appears', async ({
  page,
}) => {
  const session = await signIn(page, ACCOUNTS.ada);
  await seed(page, session, {
    'posting:default:quote_policy': 'public',
  });

  try {
    await navigate(page, '/settings/preferences');
    await openPreferences(page);
    await expect(page.locator(QUOTE_POLICY)).toHaveValue('public');

    // Force the server's refusal for this one write. GETs stay real so the
    // page read is the lab's answer; only the PUT is replaced.
    await page.route('**/api/v1/preferences', async (route) => {
      if (route.request().method() !== 'PUT') {
        await route.continue();
        return;
      }
      await route.fulfill({
        status: 422,
        contentType: 'application/json',
        body: JSON.stringify({ error: REFUSAL }),
      });
    });

    try {
      await page.locator(QUOTE_POLICY).selectOption('nobody');

      const row = page.locator(QUOTE_ROW);
      const alert = row.getByRole('alert');
      await expect(alert).toBeVisible();
      await expect(alert).toHaveText(REFUSAL);
      // The sentence is filed under the row that asked, and it is the only
      // alert on the screen.
      await expect(page.locator('[role="alert"]')).toHaveCount(1);

      // The optimistic value goes back to the last confirmed one, and the
      // control stays editable.
      await expect(page.locator(QUOTE_POLICY)).toHaveValue('public');
      await expect(page.locator(QUOTE_POLICY)).toBeEnabled();

      // A refusal is not a toast: no floating report and no success status.
      await expect(page.locator('.toast')).toHaveCount(0);
      await expect(page.getByText('Saved.', { exact: true })).toHaveCount(0);
    } finally {
      await page.unroute('**/api/v1/preferences');
    }
  } finally {
    await seed(page, session, {
      'posting:default:quote_policy': 'public',
    });
  }
});
