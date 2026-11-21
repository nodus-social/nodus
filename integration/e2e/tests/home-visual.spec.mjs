// Visual: the home timeline with the seeded follow graph. Ada is deliberately
// not the account that signs in: `peers.sh follow` makes ada follow the Mastodon
// and Misskey accounts, so a peer-authored post would add a row to ada's
// timeline and change this baseline whenever the peers are up — and CI runs this
// suite with the peers down. Admin follows only local accounts, so the picture
// is the same with the peers up, down, or never started.
//
// Relative timestamps are masked because they are the one part of the screen
// that changes without the code changing; everything else is expected to be
// pixel-stable.

import { expect, test } from '@playwright/test';

import { ACCOUNTS, POSTS } from '../fixtures.mjs';
import { signIn } from '../helpers/session.mjs';
import { prepareVisualPage, volatileMasks } from '../helpers/visual.mjs';

test('home timeline', async ({ page }) => {
  await signIn(page, ACCOUNTS.admin);
  await expect(page.getByText(POSTS.graceFirst)).toBeVisible();
  await prepareVisualPage(page, page.locator('main'));

  await expect(page).toHaveScreenshot('home-timeline.png', {
    fullPage: true,
    mask: volatileMasks(page),
  });
});
