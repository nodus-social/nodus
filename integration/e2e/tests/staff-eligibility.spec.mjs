// The rail's staff doors are eligibility, not a grant and not an area bit.
//
// Three sessions, one per claim, all on the live `/api/v1/meta` answer (it
// names `admin` and `moderation`):
//
//  - a non-staff account (`grace@nodus.test`, whose credentials carry no staff
//    role) sees no door, and the page behind the address explains the role
//    instead of drawing panels;
//  - the same administrator whose other test sees both doors sees neither when
//    the instance refuses the role read — fail closed, which is the opposite of
//    the optimistic fallback the door used to take;
//  - the staff account (`admin@nodus.test`) sees both doors without being
//    granted anything, because eligibility is what the door advertises and the
//    grant is what the page behind it asks for.
//
// The staff card is only drawn on desktop, so the rail half is skipped
// elsewhere; the non-staff page explanation holds on every viewport, but this
// spec speaks for the rail's readers.

import { expect, test } from '@playwright/test';

import { ACCOUNTS } from '../fixtures.mjs';
import { navigate } from '../helpers/navigation.mjs';
import { signIn } from '../helpers/session.mjs';
import { staffCardSettled } from '../helpers/staff.mjs';

const ADMINISTRATION = { name: 'Administration', exact: true };
const MODERATION = { name: 'Moderation', exact: true };
const NOT_STAFF = 'Not a moderator here';
const NOT_STAFF_BODY =
  'This instance does not make your account staff — an administrator has to grant it.';

function desktopOnly(testInfo) {
  test.skip(
    testInfo.project.name !== 'desktop',
    'the staff doors are drawn in the desktop rail',
  );
}

async function expectNoStaffDoors(page) {
  // A probe that has not answered yet also draws no card; waiting for the
  // tree to settle at zero is what makes "absent" an answer rather than a
  // frame before the answer.
  expect(
    await staffCardSettled(page, 0, 20_000),
    'the rail settles without a staff card',
  ).toBe(true);
  await expect(
    page.getByRole('link', ADMINISTRATION),
    'no administration door for this account',
  ).toHaveCount(0);
  await expect(
    page.getByRole('link', MODERATION),
    'no moderation door for this account',
  ).toHaveCount(0);
}

test('a non-staff account sees no staff doors and reads why the page is closed', async ({
  page,
}, testInfo) => {
  desktopOnly(testInfo);
  const session = await signIn(page, ACCOUNTS.grace);
  expect(session.acct, 'the non-staff reader is signed in').toBe('grace');

  await expectNoStaffDoors(page);

  await navigate(page, '/admin/overview');
  await expect(
    page.getByRole('heading', { name: NOT_STAFF, exact: true }),
    'the page names the missing role rather than drawing panels',
  ).toBeVisible();
  await expect(
    page.getByText(NOT_STAFF_BODY, { exact: true }),
    'the page says what would have to change',
  ).toBeVisible();
  await expect(
    page.locator('[role="tablist"]'),
    'a non-staff account gets no administration strip',
  ).toHaveCount(0);
  await expect(
    page.getByText('Last seven days', { exact: true }),
    'a non-staff account gets no dashboard',
  ).toHaveCount(0);
  await expect(
    page.locator('[role="alert"]'),
    'having no role is not an error',
  ).toHaveCount(0);
  await expect(
    page.locator('.loading.loading-spinner'),
    'the gate has settled',
  ).toHaveCount(0);
});

test('a refused role read closes the doors and the page stays closed', async ({
  page,
}, testInfo) => {
  desktopOnly(testInfo);
  const session = await signIn(page, ACCOUNTS.admin);
  expect(session.acct, 'the administrator is signed in').toBe('admin');

  // Refuse the one read that decides eligibility. A fresh document asks it
  // again, so the shell cannot answer from the verdict it cached before the
  // refusal.
  await page.route('**/api/v1/accounts/verify_credentials', (route) =>
    route.fulfill({
      status: 403,
      contentType: 'application/json',
      body: JSON.stringify({ error: 'This action requires the admin:read scope' }),
    }),
  );
  await page.goto('/home', { waitUntil: 'domcontentloaded' });

  await expectNoStaffDoors(page);

  await navigate(page, '/admin/overview');
  await expect(
    page.getByRole('heading', { name: 'Could not ask this instance', exact: true }),
    'a refused read is answered as unknown, not as staff',
  ).toBeVisible();
  await expect(
    page.locator('[role="tablist"]'),
    'a refused read does not open the administration area',
  ).toHaveCount(0);
  await expect(
    page.getByText('Last seven days', { exact: true }),
    'a refused read does not draw the dashboard',
  ).toHaveCount(0);
});

test('the staff account sees both doors without a grant', async ({ page }, testInfo) => {
  desktopOnly(testInfo);
  const session = await signIn(page, ACCOUNTS.admin);
  expect(session.acct, 'the administrator is signed in').toBe('admin');

  expect(
    await staffCardSettled(page, 1, 20_000),
    'the staff card is drawn for the eligible account',
  ).toBe(true);
  await expect(
    page.getByRole('link', ADMINISTRATION),
    'the administrator sees the administration door',
  ).toBeVisible();
  await expect(
    page.getByRole('link', MODERATION),
    'the administrator sees the moderation door',
  ).toBeVisible();
});
