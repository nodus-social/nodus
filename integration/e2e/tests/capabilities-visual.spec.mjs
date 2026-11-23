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
// The two degraded baselines are byte-identical, and that is the product's
// answer rather than a missing assertion. Both draw no staff card, for two
// different reasons the rail cannot picture: the absent answer omits the
// capabilities while the session still holds the grant, and the Mastodon answer
// names `admin` and `moderation` in its probed baseline while the session's
// protocol carries no extensions, so the three-part staff gate
// (`staff_door(extensions, served, role)`, web/crates/ui/src/capabilities.rs)
// closes on its first fact. Every other rail door is served by both answers:
// Mastodon's baseline covers lists, favourites, scheduled posts, search, the
// directory, conversations and notifications, and the Nodus answer under test
// only drops admin, moderation and drive — drive having no rail entry in this
// build. There is no door in this navigator on which the two shapes can
// honestly differ, so the shots are named for the mechanism each one pins
// (`grant-held`, `grant-ignored`) rather than reading as a comparison.
//
// Every shot is falsifiable. Each was re-recorded with its claim made false and
// the difference measured (maxDiffPixels is 40): full without the grant, 737 px;
// absent with `admin` left in the answer, 463 px; Mastodon with the real Nodus
// answer, 737 px. A baseline that would pass with the bug present is worthless.
//
// web 17f66d6 ("rail: draw a group's heading only when something survives under
// it") made `served_entries` the single capability filter and `section_is_drawn`
// the heading's question, so a group with nothing under it paints no heading.
// The empty STAFF heading these baselines had recorded was therefore the bug,
// and the three pictures here are the same falsification run in reverse: the
// committed baselines at bd19e84 are the "heading drawn unconditionally" paint,
// so a picture that still matched them would prove the heading had not been
// removed.

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
  // A probe that started before the grant can answer after it and re-cache
  // "no role", so a client-side navigation may carry the pre-grant verdict
  // forever. Reloading starts a shell whose first ask already sees the grant.
  await page.reload();
  // The rail's staff probe re-asks after the grant; going back to the reading
  // column makes it rebuild with the grant held, and the door is looked for
  // across a few loads rather than one.
  for (let attempt = 1; attempt <= 2; attempt += 1) {
    await navigate(page, '/home');
    if (await staffCardSettled(page, 1)) return;
  }
  await expect(
    page.getByRole('link', { name: 'Administration', exact: true }),
    'the grant opens the administration door in the rail',
  ).toBeVisible({ timeout: 20_000 });
}

// The rail carries the profile card, whose avatar is the one region that can
// change between runs (the lab seeds it from the instance, and a peer run can
// change it). It is masked; the doors are never masked, because they are the
// claim.
//
// The staff card is drawn and torn down while the rail's probe settles, so a
// card seen in one frame is not yet a card; `settled` is the frame after the
// tree has held still and the card is still there.
async function staffCardSettled(page, doors, timeout = 8_000) {
  const staffCards = page.locator(`${RAIL} [data-nav-rail-doors]`);
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if ((await staffCards.count()) !== doors) {
      await page.waitForTimeout(250);
      continue;
    }
    await quietTree(page.locator(RAIL));
    if ((await staffCards.count()) === doors) return true;
  }
  return false;
}

async function quietTree(scope) {
  await scope.evaluate(
    (element) =>
      new Promise((done) => {
        let timer = setTimeout(done, 800);
        const observer = new MutationObserver(() => {
          clearTimeout(timer);
          timer = setTimeout(() => {
            observer.disconnect();
            done();
          }, 800);
        });
        observer.observe(element, {
          childList: true,
          subtree: true,
          characterData: true,
          attributes: true,
        });
      }),
  );
}

// The rail is a column that stretches to the page's tallest column, so its box
// is the timeline's height, not its own: the same finished rail measured 1288px
// on one run and 1289px on the next while every rail row was identical, because
// the last card in the feed landed on either side of a device pixel. Pin the
// rail to its own cards instead: opt it out of the flex stretch, let it size to
// content, and round that up to a whole pixel. The blank column below the last
// door is the layout, not part of the capability answer this shot claims.
//
// The three shots share `RAIL_FRAME_HEIGHT` so a shape that loses a card differs
// in pixels rather than in size: Playwright reports a size mismatch without a
// pixel count, and the falsification table is counts. The frame is taller than
// the tallest shape's content today (the full rail), so every shot keeps the
// same crop and only the pixels move when a claim is made false.
//
// The rail is also filled in stages, and its staff probe re-asks after the
// grant, so the staff card is torn down and rebuilt: a picture taken in that gap
// is a rail with a shorter box, not a rail without the door. The shot names how
// many staff cards it claims, and the rail is measured only once it holds that
// many and has stopped changing.
const RAIL_FRAME_HEIGHT = 640;
async function railPicture(page, name, doors) {
  const rail = page.locator(RAIL);
  await prepareVisualPage(page, rail);
  if (!(await staffCardSettled(page, doors))) {
    // The shell carries the capability answer that was rendered before the
    // grant landed, so the probe can read a session without the staff role and
    // never ask again. A fresh load re-asks.
    await page.reload();
    await prepareVisualPage(page, rail);
    expect(
      await staffCardSettled(page, doors),
      `the rail holds ${doors} staff card(s)`,
    ).toBe(true);
  }
  // The notifications probe answers after the first paint: until it does, the
  // bell row does not exist and a shot taken then is the pre-probe rail. Wait
  // for the door itself, not for a timeout, so the picture pins the navigator
  // the reader actually gets.
  await expect(rail.locator('[data-notice-bell]')).toBeVisible();
  await rail.evaluate((element, frame) => {
    element.style.alignSelf = 'flex-start';
    element.style.height = 'auto';
    const { height } = element.getBoundingClientRect();
    element.style.height = `${Math.max(Math.ceil(height), frame)}px`;
  }, RAIL_FRAME_HEIGHT);
  await expect(rail).toHaveScreenshot(name, {
    mask: [
      ...volatileMasks(page, { notificationDoor: 'badge' }),
      page.locator('[data-rail-profile] img'),
    ],
  });
}

test('a full Nodus instance draws both staff doors', async ({
  page,
}, testInfo) => {
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

  await railPicture(page, 'navigator-nodus-full.png', 1);
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
  // The grant is still held when the answer is replaced, so the absent picture
  // is the one reader the capability filter has to work on: a reader who could
  // use the doors, on an instance that does not serve them. The staff card is
  // gone from it, heading included — `door_card` asks `section_is_drawn` before
  // it draws the card (web/crates/ui/src/components/rail/mod.rs), which is why
  // there is no bare STAFF heading left behind. `grant-held` in the baseline's
  // name is that fact; the Mastodon shot's `grant-ignored` is the other way to
  // arrive at the same rail.
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
  await railPicture(page, 'navigator-absent-caps-grant-held.png', 0);
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
  expect(session.acct, 'the reader this test speaks for is signed in').toBe(
    'admin',
  );
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

  await expect(
    page.getByRole('link', { name: 'Search', exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole('link', { name: 'Saved', exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole('link', { name: 'Lists', exact: true }),
  ).toBeVisible();
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

  await railPicture(page, 'navigator-mastodon-grant-ignored.png', 0);
});
