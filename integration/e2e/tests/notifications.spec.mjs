// Functional: another account acts on Ada's status and Ada sees it in her
// notifications with the actor and the post it concerns.
//
// The unread badge is cleared by the explicit "Mark all read" action, not by
// opening the page: measured at this build, visiting /notifications leaves the
// badge intact. The assertions below encode that real behaviour.
//
// The inbox is emptied before Ada's page boots (see the setup context below),
// so the badge counts this run's two notices and nothing a previous run left.

import { expect, test } from '@playwright/test';

import { ACCOUNTS, BROWSER_ORIGIN } from '../fixtures.mjs';
import {
  clearNotifications,
  createStatus,
  deleteStatus,
  favouriteStatus,
  lookupAccount,
} from '../helpers/api.mjs';
import { navigate } from '../helpers/navigation.mjs';
import { signIn } from '../helpers/session.mjs';

test('a favourite and a reply from another account reach the inbox', async ({
  page,
  browser,
}) => {
  // The rail counts unread ids from the page the client fetched at sign-in and
  // never drops ids a clear removed, so clearing after sign-in would measure the
  // previous run. Clear first, then let the page under test sign in once the
  // notices exist: its boot fetch is exactly this run's inbox.
  const setupContext = await browser.newContext({ baseURL: BROWSER_ORIGIN });
  const setupPage = await setupContext.newPage();
  const setup = await signIn(setupPage, ACCOUNTS.ada);
  await clearNotifications(setupPage.request, setup);
  const status = await createStatus(
    setupPage.request,
    setup,
    `notification target ${Date.now()}`,
  );
  await setupContext.close();

  // Cleanup runs even when an assertion fails: a leftover status would be the
  // newest card on the home timeline and break the next run's baseline.
  let reply = null;

  // Grace acts through her own signed-in session and the same REST endpoints
  // the UI calls; nothing here writes to the database directly.
  const graceContext = await browser.newContext({ baseURL: BROWSER_ORIGIN });
  const gracePage = await graceContext.newPage();
  const graceSession = await signIn(gracePage, ACCOUNTS.grace);
  const grace = await lookupAccount(gracePage.request, graceSession, 'grace');

  await favouriteStatus(gracePage.request, graceSession, status.id);
  reply = await createStatus(
    gracePage.request,
    graceSession,
    'notification reply from the other account',
    status.id,
  );

  try {
    await signIn(page, ACCOUNTS.ada);
    await navigate(page, '/notifications');

    const favourite = page
      .locator('[data-notice-kind="favourite"]')
      .filter({ has: page.locator(`a[href="/status/${status.id}"]`) });
    await expect(favourite).toHaveCount(1);
    await expect(favourite).toContainText('favourited your post');
    await expect(favourite.getByRole('link', { name: 'grace' })).toHaveAttribute(
      'href',
      `/accounts/${grace.id}`,
    );

    const mention = page
      .locator('[data-notice-kind="mention"]')
      .filter({ has: page.locator(`a[href="/status/${reply.id}"]`) });
    await expect(mention).toHaveCount(1);
    await expect(mention).toContainText('mentioned you');

    // Opening the page did not clear anything: both notifications are still
    // unread and the sidebar badge still counts them.
    const badge = page.locator('[data-notice-count]');
    await expect(badge).toHaveText('2');
    await expect(page.locator('[data-unread-dot]')).toHaveCount(2);

    await page.getByRole('button', { name: 'Mark all read' }).click();
    await expect(badge).toHaveCount(0);
    await expect(page.locator('[data-unread-dot]')).toHaveCount(0);
  } finally {
    if (reply) await deleteStatus(gracePage.request, graceSession, reply.id);
    await deleteStatus(page.request, setup, status.id);
    await clearNotifications(page.request, setup);
    await graceContext.close();
  }
});
