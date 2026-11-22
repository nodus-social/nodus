// Admin pages are gated one at a time: the area survives, the page it does not
// serve says so in its own words.
//
// The mutation is one name. The lab's live `/api/v1/meta` answer is read first
// and every name kept; only `admin_topology` is dropped, so a door or a tab that
// disappears here disappeared because that one page was refused, not because
// the test replaced the server with a smaller fiction.
//
// `admin` staying in the answer is the operator's rule: omit the specific
// administration page that is not supported, never the administration area.
// The area's door, heading and strip are pinned below; the missing page's own
// sentence is `Surface::absent` (web/crates/ui/src/capabilities/surface/rows.rs)
// painted by `<UnservedPage/>`. The page's address and tab are the product's,
// `system` and "System": the section's slug is `system` even though its subject
// is topology (web/crates/pages/src/pages/admin/mod.rs).

import { expect, test } from '@playwright/test';

import { ACCOUNTS, BASE_URL } from '../fixtures.mjs';
import { navigate } from '../helpers/navigation.mjs';
import { signIn } from '../helpers/session.mjs';
import { grantAdmin, staffCardSettled } from '../helpers/staff.mjs';
import { prepareVisualPage, volatileMasks } from '../helpers/visual.mjs';

const TOPOLOGY_SENTENCE = 'This instance does not serve the topology view.';

function desktopOnly(testInfo) {
  test.skip(
    testInfo.project.name !== 'desktop',
    'the administration door and its tab strip are pinned in the desktop rail',
  );
}

// The SSR server answers `/home` before the browser's interceptor can speak,
// so its island carries the live capability list and would win over the
// intercepted `/api/v1/meta` (web/crates/web-client/src/state/bridge/
// capabilities.rs, `prefer`). Strip that one key so the client negotiates the
// answer this test is pinning.
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

async function omitTopology(page, request) {
  const answer = await request.get(`${BASE_URL}/api/v1/meta`);
  expect(answer.ok(), 'the lab publishes its capability list').toBe(true);
  const meta = await answer.json();
  expect(meta.features, 'the live answer names the page this test removes').toContain(
    'admin_topology',
  );
  const mutated = {
    ...meta,
    features: meta.features.filter((name) => name !== 'admin_topology'),
  };
  expect(
    mutated.features,
    'the mutation is one name, and the area around it survives',
  ).toHaveLength(meta.features.length - 1);

  await page.route('**/api/v1/meta', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(mutated),
    }),
  );
  await stripSeededCapabilities(page);
  await page.goto('/home', { waitUntil: 'domcontentloaded' });
}

// The reading column is a flex item in the page row and stretches to the rail.
// Pin the crop to the admin area's own content, as drive-visual.spec.mjs does.
async function contentHeight(scope) {
  await scope.evaluate((element) => {
    const parent = getComputedStyle(element.parentElement);
    if (parent.flexDirection.startsWith('row')) {
      element.style.alignSelf = 'flex-start';
    }
    element.style.height = 'auto';
    const { height } = element.getBoundingClientRect();
    element.style.height = `${Math.ceil(height)}px`;
  });
}

test('an answer that keeps admin but omits one admin page keeps the area and explains that page', async ({
  page,
  request,
}, testInfo) => {
  desktopOnly(testInfo);
  const session = await signIn(page, ACCOUNTS.admin);
  expect(session.acct, 'the administrator is signed in').toBe('admin');
  // The panels behind the area need the wider grant; obtaining it against the
  // live answer first keeps the mutation the only variable.
  await grantAdmin(page);

  await omitTopology(page, request);

  const administration = page.getByRole('link', {
    name: 'Administration',
    exact: true,
  });
  await expect(
    administration,
    'the area door survives a page the instance does not serve',
  ).toBeVisible({ timeout: 20_000 });
  expect(await staffCardSettled(page, 1), 'the staff card survives').toBe(true);

  await navigate(page, '/admin/overview');
  const strip = page.locator('[role="tablist"]').first();
  await expect(strip, 'the area draws its strip').toBeVisible();
  await expect(
    page.getByRole('tab', { name: 'Overview', exact: true }),
    'a served page still has its tab',
  ).toBeVisible();
  await expect(
    page.getByRole('tab', { name: 'System', exact: true }),
    'the tab strip does not offer the page the answer omitted',
  ).toHaveCount(0);
  await expect(
    page.getByText('Last seven days', { exact: true }),
    'the overview still renders its own content',
  ).toBeVisible();

  await prepareVisualPage(page, strip);
  await expect(strip).toHaveScreenshot('admin-area-missing-system-tab.png');

  // A direct visit is the address a reader follows, not a tab the stripped
  // strip no longer offers: the page has to explain itself.
  await navigate(page, '/admin/system');
  await expect(
    page.getByRole('heading', { name: 'Administration', exact: true }),
    'the area heading stays',
  ).toBeVisible();
  await expect(
    page.getByText(TOPOLOGY_SENTENCE, { exact: true }),
    'the page paints its own explanation',
  ).toBeVisible();
  await expect(
    page.getByText('Last seven days', { exact: true }),
    'the unserved page does not fall back to the dashboard',
  ).toHaveCount(0);
  await expect(
    page.locator('[role="alert"]'),
    'a page the instance does not serve is not an error toast',
  ).toHaveCount(0);
  await expect(
    page.locator('.loading.loading-spinner'),
    'no spinner is left on an unserved page',
  ).toHaveCount(0);

  const main = page.locator('main');
  await prepareVisualPage(page, main);
  await contentHeight(main);
  await expect(main).toHaveScreenshot('admin-page-unserved-system.png', {
    mask: volatileMasks(page),
  });
});
