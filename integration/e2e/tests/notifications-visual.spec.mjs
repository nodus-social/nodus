// Visual: one favourite notification. The spec empties the inbox and has Grace
// favourite a disposable status of Ada's before Ada's page boots, then
// screenshots the resulting row. The disposable status is deleted again so the
// home-timeline baseline does not gain a card.

import { expect, test } from '@playwright/test';

import { ACCOUNTS, BROWSER_ORIGIN } from '../fixtures.mjs';
import {
  clearNotifications,
  createStatus,
  deleteStatus,
  favouriteStatus,
} from '../helpers/api.mjs';
import { navigate } from '../helpers/navigation.mjs';
import { signIn } from '../helpers/session.mjs';
import { prepareVisualPage, volatileMasks } from '../helpers/visual.mjs';

test('notifications with one favourite', async ({ page, browser }) => {
  // Same ordering rule as notifications.spec.mjs: the inbox has to be empty
  // before the page under test signs in, or the badge counts stale rows.
  const setupContext = await browser.newContext({ baseURL: BROWSER_ORIGIN });
  const setupPage = await setupContext.newPage();
  const setup = await signIn(setupPage, ACCOUNTS.ada);
  await clearNotifications(setupPage.request, setup);
  const status = await createStatus(
    setupPage.request,
    setup,
    `visual notification ${Date.now()}`,
  );
  await setupContext.close();

  const graceContext = await browser.newContext({ baseURL: BROWSER_ORIGIN });
  const gracePage = await graceContext.newPage();
  const graceSession = await signIn(gracePage, ACCOUNTS.grace);
  await favouriteStatus(gracePage.request, graceSession, status.id);

  try {
    await signIn(page, ACCOUNTS.ada);
    await navigate(page, '/notifications');
    await expect(page.locator('[data-notice-kind="favourite"]')).toHaveCount(1);
    await expect(page.locator('[data-notice-count]')).toHaveText('1');

    const main = page.locator('main');
    await prepareVisualPage(page, main);
    await expect(main).toHaveScreenshot('notifications.png', {
      mask: volatileMasks(page),
    });
  } finally {
    // A failed assertion must not leave the disposable status behind: it would
    // be the newest card on the next run's home timeline.
    await deleteStatus(page.request, setup, status.id);
    await clearNotifications(page.request, setup);
    await graceContext.close();
  }
});
