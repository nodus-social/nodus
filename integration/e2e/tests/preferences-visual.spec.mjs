// Visual: the preferences card, with the nine controls in their three groups.
//
// Preferences are per account and every earlier run leaves values behind, so
// the state is seeded through the real API before the page boots: the picture
// pins the editor's layout, not whatever the previous spec chose. The seeded
// map is the client's documented default (sdk/crates/client-core/src/model/
// preferences.rs, `impl Default`).
//
// The card is the desktop reading column; below the `xl` breakpoint the shell
// draws it at a different width, so only that one viewport is pinned.

import { expect, test } from '@playwright/test';

import { ACCOUNTS } from '../fixtures.mjs';
import { navigate } from '../helpers/navigation.mjs';
import { API_BASE, signIn } from '../helpers/session.mjs';
import { prepareVisualPage } from '../helpers/visual.mjs';

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

test('the preferences card draws its three groups', async ({ page }, testInfo) => {
  test.skip(
    testInfo.project.name !== 'desktop',
    'the settings card is pinned in the desktop reading column',
  );

  const session = await signIn(page, ACCOUNTS.ada);
  const seeded = await page.request.put(`${API_BASE}/api/v1/preferences`, {
    headers: { Authorization: `Bearer ${session.token}` },
    data: DEFAULTS,
  });
  expect(seeded.ok(), 'the preferences seed is accepted').toBe(true);

  await navigate(page, '/settings/preferences');
  await expect(page.getByRole('heading', { name: 'Preferences' })).toBeVisible({
    timeout: 30_000,
  });
  await expect(page.locator('[data-preference]')).toHaveCount(9);
  await expect(page.locator('[data-preference-note]')).toHaveCount(1);

  const main = page.locator('main');
  await prepareVisualPage(page, main);
  // The reading column has no height of its own and stretches to the rail's
  // height, so pin it to its content. The same fix keeps the crop from moving
  // when a rail row changes without a pixel of the settings card changing.
  await main.evaluate((element) => {
    const parent = getComputedStyle(element.parentElement);
    if (parent.flexDirection.startsWith('row')) {
      element.style.alignSelf = 'flex-start';
    }
    element.style.height = 'auto';
    const { height } = element.getBoundingClientRect();
    element.style.height = `${Math.ceil(height)}px`;
  });

  await expect(main).toHaveScreenshot('preferences.png');
});
