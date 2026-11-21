// Visual: one favourite notification. The spec clears the inbox, has Grace
// favourite a disposable status of Ada's, then screenshots the resulting row.
// The disposable status is deleted again so the home-timeline baseline does
// not gain a card.

import { expect, test } from '@playwright/test';

import { ACCOUNTS, BASE_URL } from '../fixtures.mjs';
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
  const session = await signIn(page, ACCOUNTS.ada);
  await clearNotifications(page.request, session);
  const status = await createStatus(page.request, session, `visual notification ${Date.now()}`);

  const graceContext = await browser.newContext({ baseURL: BASE_URL });
  const gracePage = await graceContext.newPage();
  const graceSession = await signIn(gracePage, ACCOUNTS.grace);
  await favouriteStatus(gracePage.request, graceSession, status.id);

  await navigate(page, '/notifications');
  await expect(page.locator('[data-notice-kind="favourite"]')).toHaveCount(1);
  await expect(page.locator('[data-notice-count]')).toHaveText('1');

  const main = page.locator('main');
  await prepareVisualPage(page, main);
  await expect(main).toHaveScreenshot('notifications.png', {
    mask: volatileMasks(page),
  });

  await deleteStatus(page.request, session, status.id);
  await clearNotifications(page.request, session);
  await graceContext.close();
});
