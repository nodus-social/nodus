// Visual: the home timeline with the seeded follow graph. Relative timestamps
// are masked because they are the one part of the screen that changes without
// the code changing; everything else is expected to be pixel-stable.

import { expect, test } from '@playwright/test';

import { ACCOUNTS, POSTS } from '../fixtures.mjs';
import { signIn } from '../helpers/session.mjs';
import { volatileMasks } from '../helpers/visual.mjs';

test('home timeline', async ({ page }) => {
  await signIn(page, ACCOUNTS.ada);
  await expect(page.getByText(POSTS.graceFirst)).toBeVisible();
  await page.evaluate(() => document.fonts.ready);

  await expect(page).toHaveScreenshot('home-timeline.png', {
    fullPage: true,
    mask: volatileMasks(page),
  });
});
