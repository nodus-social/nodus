// Visual: the navigator, for three provider shapes.
//
// The functional specs prove the shell reads the capability answer. These
// pictures prove what the reader actually gets: the doors a full Nodus serves,
// the same rail on an instance that publishes no `admin`, `moderation` or
// `drive`, and a Mastodon-shaped session where the baseline still draws
// bookmarks, lists and search. The rail never lists drive or feed in this
// build, so their absence is asserted rather than pictured.
//
// The rail is the desktop layout's navigator; the narrow viewports draw no rail
// at all, so a picture there would show the layout rather than the capability.
//
// The absent-surfaces and Mastodon-shaped baselines show the same rail in this
// build: the rail has no drive or feed entry, and a Mastodon answer resolves no
// staff role, so nothing in the navigator distinguishes the two shapes. They
// remain separate answers with separate falsifications; the pictures coincide
// because the product's navigator does.
//
// Every shot is falsifiable. The commit that introduced these baselines
// re-recorded each with its claim made false and recorded the difference in
// pixels (maxDiffPixels is 40): full without the grant, 617 px; absent with
// `admin` left in the answer, 343 px; Mastodon with the real Nodus answer,
// 617 px. A baseline that would pass with the bug present is worthless.

import { expect, test } from '@playwright/test';

import { ACCOUNTS, BASE_URL } from '../fixtures.mjs';
import { navigate } from '../helpers/navigation.mjs';
import { signIn } from '../helpers/session.mjs';
import { prepareVisualPage, volatileMasks } from '../helpers/visual.mjs';

// A Mastodon instance document: every field a peer publishes, and no feature
// list. It is the same shape tests/capabilities-absent.spec.mjs intercepts.
const MASTODON_SHAPED = {
  uri: 'nodus.test',
  title: 'Nodus',
  email: 'ops@nodus.test',
  version: '4.6.3',
  description: 'The integration lab.',
  languages: ['en'],
  registrations: false,
  approval_required: false,
};

const RAIL = 'aside[data-rail="left"]';

// The rail is desktop-only: below the `xl` breakpoint the shell has no left
// column, so a screenshot there would be a picture of the viewport, not of the
// capability answer.
function desktopOnly(testInfo) {
  test.skip(
    testInfo.project.name !== 'desktop',
    'the navigator is drawn in the desktop rail',
  );
}

// The SSR server answers `/home` before the browser's interceptor can speak,
// so its island carries the real capability list and would win over the
// intercepted `/api/v1/meta` (capabilities.rs, `prefer`). Strip that one key
// from the document, which is what a client-side route already looks like, so
// both paints read the answer this test is pinning.
async function stripSeededCapabilities(page) {
  await page.route('**/home', async (route) => {
    const response = await route.fetch({ url: `${BASE_URL}/home` });
    const html = await response.text();
    const stripped = html.replace(
      /(<script id="nodus-page" type="application\/json">)([\s\S]*?)(<\/script>)/,
      (_whole, open, json, close) => {
        const island = JSON.parse(json);
        delete island.capabilities;
        return open + JSON.stringify(island) + close;
      },
    );
    await route.fulfill({ response, body: stripped });
  });
}

// The real Nodus lab calls its own administration gate "moderation token" (the
// admin:read/admin:write grant). The door in the rail is drawn only after the
// grant is held, so the full-shape picture has to walk the same consent screen
// an operator walks, rather than inventing a token.
async function grantAdmin(page) {
  await navigate(page, '/admin/overview');
  const grant = page.getByRole('button', { name: 'Grant admin access' });
  await expect(grant, 'the administration gate offers the grant').toBeVisible();
  await grant.click();
  await page.waitForURL(/\/oauth\/authorize/, { timeout: 30_000 });
  await page.getByRole('button', { name: 'Allow' }).click();
  await page.waitForURL(/\/admin\//, { timeout: 30_000 });
  // The rail's staff probe re-asks after the grant; going back to the reading
  // column makes it rebuild with the grant held.
  await navigate(page, '/home');
  await expect(
    page.getByRole('link', { name: 'Administration', exact: true }),
    'the grant opens the administration door in the rail',
  ).toBeVisible({ timeout: 30_000 });
}

// The rail carries the profile card, whose avatar is the one region that can
// change between runs (the lab seeds it from the instance, and a peer run can
// change it). It is masked; the doors are never masked, because they are the
// claim.
async function railPicture(page, name) {
  const rail = page.locator(RAIL);
  await prepareVisualPage(page, rail);
  await expect(rail).toHaveScreenshot(name, {
    mask: [...volatileMasks(page), page.locator('[data-rail-profile] img')],
  });
}

test('a full Nodus instance draws both staff doors', async ({ page }, testInfo) => {
  desktopOnly(testInfo);
  const session = await signIn(page, ACCOUNTS.admin);
  expect(session.acct, 'the administrator is signed in').toBe('admin');

  await grantAdmin(page);
  await expect(
    page.getByRole('link', { name: 'Administration', exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole('link', { name: 'Moderation', exact: true }),
  ).toBeVisible();

  await railPicture(page, 'navigator-nodus-full.png');
});

test('an instance that omits admin, moderation and drive draws neither the doors nor their sections', async ({
  page,
  request,
}, testInfo) => {
  desktopOnly(testInfo);
  const session = await signIn(page, ACCOUNTS.admin);
  expect(session.acct, 'the administrator is signed in').toBe('admin');

  // The grant is obtained against the real answer first: with `admin` absent
  // from the capability list the gate has no grant button to offer, and a
  // reader who was already granted access is exactly the reader this shape is
  // about. Then the instance's answer is replaced and the shell re-reads it.
  //
  // The drive is not in this picture: this build has no rail entry for it (it
  // is reached by address), and the route's `drive_on` falls back to the
  // session's own read scope, so a capability-absent drive still draws for a
  // signed-in reader (web/crates/web-client/src/app.rs:84-88). That is a gap
  // this shot cannot show; it is named in the commit and the follow-up.
  //
  // The bare STAFF heading is real: the rail wraps `extra_doors` in a card
  // before it knows the list is empty (web/crates/ui/src/components/rail/mod.rs,
  // `door_card`). This picture records the defect instead of masking it.
  await grantAdmin(page);

  const full = await request.get(`${BASE_URL}/api/v1/meta`);
  expect(full.ok(), 'the lab publishes its capability list').toBe(true);
  const meta = await full.json();
  meta.features = meta.features.filter(
    (name) => !['admin', 'moderation', 'drive'].includes(name),
  );
  await page.route('**/api/v1/meta', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(meta),
    }),
  );
  await stripSeededCapabilities(page);
  await page.goto('/home', { waitUntil: 'domcontentloaded' });

  await expect(
    page.getByRole('link', { name: 'Administration', exact: true }),
    'the administration door is absent when the instance does not publish it',
  ).toHaveCount(0);
  await expect(
    page.getByRole('link', { name: 'Moderation', exact: true }),
    'the moderation door is absent when the instance does not publish it',
  ).toHaveCount(0);
  await expect(
    page.locator('[role="alert"]'),
    'an absent capability is not an error the reader has to dismiss',
  ).toHaveCount(0);
  await expect(
    page.getByText(/failed/i),
    'an absent capability is not reported as a failure',
  ).toHaveCount(0);
  await expect(
    page.locator('.loading.loading-spinner'),
    'no spinner is left behind once the answer settled',
  ).toHaveCount(0);

  await expect(
    page.getByRole('link', { name: 'Administration', exact: true }),
  ).toHaveCount(0);
  await railPicture(page, 'navigator-nodus-absent-surfaces.png');
});

test('a Mastodon-shaped session keeps lists, bookmarks and search, and draws no drive or feed', async ({
  page,
}, testInfo) => {
  desktopOnly(testInfo);
  // The administrator is the sharper reader here: the grant is obtained
  // against the real answer first, then the Mastodon answer replaces it. A
  // Mastodon-shaped session must lose the staff doors even though the grant is
  // still held, which is the transition this shot pins.
  const session = await signIn(page, ACCOUNTS.admin);
  expect(session.acct, 'the reader this test speaks for is signed in').toBe('admin');
  await grantAdmin(page);

  await page.route('**/api/v1/meta', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(MASTODON_SHAPED),
    }),
  );
  await stripSeededCapabilities(page);
  await page.goto('/home', { waitUntil: 'domcontentloaded' });

  await expect(page.getByRole('link', { name: 'Search', exact: true })).toBeVisible();
  await expect(page.getByRole('link', { name: 'Saved', exact: true })).toBeVisible();
  await expect(page.getByRole('link', { name: 'Lists', exact: true })).toBeVisible();
  await expect(
    page.getByRole('link', { name: 'Drive', exact: true }),
    'a Mastodon baseline has no drive',
  ).toHaveCount(0);
  await expect(
    page.getByRole('link', { name: 'Feed', exact: true }),
    'a Mastodon baseline has no recommended feed',
  ).toHaveCount(0);
  await expect(
    page.getByRole('link', { name: 'Administration', exact: true }),
  ).toHaveCount(0);
  await expect(
    page.getByRole('link', { name: 'Moderation', exact: true }),
  ).toHaveCount(0);

  await railPicture(page, 'navigator-mastodon-shaped.png');
});
