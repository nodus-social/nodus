// Visual: search results for the seeded handle. "grace" matches Grace's two
// seeded posts plus the account card; no other seeded text contains the word,
// so the result set is stable. Relative ages and the account avatar are the
// only time-dependent nodes and are masked.

import { expect, test } from '@playwright/test';

import { ACCOUNTS, POSTS } from '../fixtures.mjs';
import { navigate } from '../helpers/navigation.mjs';
import { signIn } from '../helpers/session.mjs';
import { prepareVisualPage, volatileMasks } from '../helpers/visual.mjs';

test('search results for an account', async ({ page }) => {
  await signIn(page, ACCOUNTS.ada);
  await navigate(page, '/search');

  await page.locator('input[type="search"]').fill('grace');
  await page.getByRole('button', { name: 'Search' }).click();
  await expect(page.getByText('@grace')).toBeVisible();
  await expect(page.getByText(POSTS.graceFirst)).toBeVisible();

  const main = page.locator('main');
  await prepareVisualPage(page, main);
  await expect(main).toHaveScreenshot('search-results.png', {
    mask: volatileMasks(page),
  });
});
