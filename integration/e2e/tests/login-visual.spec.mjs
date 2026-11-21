// Visual: the signed-out sign-in screen at each project's viewport. Nothing is
// seeded into the page, so this baseline only changes when the markup or the
// stylesheet does.

import { expect, test } from '@playwright/test';

test('sign-in screen', async ({ page }) => {
  await page.goto('/sign-in');
  await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
  await page.evaluate(() => document.fonts.ready);
  await expect(page).toHaveScreenshot('sign-in.png', { fullPage: true });
});
