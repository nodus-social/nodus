// Functional: another account acts on Ada's status and Ada sees it in her
// notifications with the actor and the post it concerns.
//
// The unread badge is cleared by the explicit "Mark all read" action, not by
// opening the page: measured at this build, visiting /notifications leaves the
// badge intact. The assertions below encode that real behaviour.

import { expect, test } from '@playwright/test';

import { ACCOUNTS, BASE_URL } from '../fixtures.mjs';
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
  const session = await signIn(page, ACCOUNTS.ada);
  await clearNotifications(page.request, session);

  const status = await createStatus(page.request, session, `notification target ${Date.now()}`);

  // Grace acts through her own signed-in session and the same REST endpoints
  // the UI calls; nothing here writes to the database directly.
  const graceContext = await browser.newContext({ baseURL: BASE_URL });
  const gracePage = await graceContext.newPage();
  const graceSession = await signIn(gracePage, ACCOUNTS.grace);
  const grace = await lookupAccount(gracePage.request, graceSession, 'grace');

  await favouriteStatus(gracePage.request, graceSession, status.id);
  const reply = await createStatus(
    gracePage.request,
    graceSession,
    'notification reply from the other account',
    status.id,
  );

  await navigate(page, '/notifications');
  // The inbox is instance-wide and earlier specs leave their own notices, so the
  // assertion is per kind: exactly one favourite and one mention for this status
  // would be an over-fit on a shared box, presence is what the inbox promises.
  const rows = page.locator('[data-notice-kind]');
  await expect(rows.first()).toBeVisible();

  const favourite = page.locator('[data-notice-kind="favourite"]').first();
  await expect(favourite).toContainText('favourited your post');
  await expect(favourite.getByRole('link', { name: 'grace' })).toHaveAttribute(
    'href',
    `/accounts/${grace.id}`,
  );
  await expect(favourite.getByRole('link', { name: 'View post' })).toHaveAttribute(
    'href',
    `/status/${status.id}`,
  );

  const mention = page.locator('[data-notice-kind="mention"]').first();
  await expect(mention).toContainText('mentioned you');
  await expect(mention.getByRole('link', { name: 'View post' })).toHaveAttribute(
    'href',
    `/status/${reply.id}`,
  );

  // Opening the page did not clear anything: both notifications are still
  // unread and the sidebar badge still counts them.
  const badge = page.locator('[data-notice-count]');
  await expect(badge).toHaveText('2');
  await expect(page.locator('[data-unread-dot]')).toHaveCount(2);

  await page.getByRole('button', { name: 'Mark all read' }).click();
  await expect(badge).toHaveCount(0);
  await expect(page.locator('[data-unread-dot]')).toHaveCount(0);

  await deleteStatus(gracePage.request, graceSession, reply.id);
  await deleteStatus(page.request, session, status.id);
  await clearNotifications(page.request, session);
  await graceContext.close();
});
