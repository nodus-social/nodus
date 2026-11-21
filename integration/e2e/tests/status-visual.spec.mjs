// Visual: a status card in the favourited state. The card is chosen by the
// seeded text, and the star is set through the UI so the baseline captures the
// real active class and count. Favourite state is restored afterwards, because
// the home-timeline baseline also contains this card.

import { expect, test } from '@playwright/test';

import { ACCOUNTS, POSTS } from '../fixtures.mjs';
import { findStatusByText, lookupAccount, unfavouriteStatus } from '../helpers/api.mjs';
import { signIn } from '../helpers/session.mjs';
import { prepareVisualPage, volatileMasks } from '../helpers/visual.mjs';

test('status card with a favourite', async ({ page }) => {
  const session = await signIn(page, ACCOUNTS.ada);
  const grace = await lookupAccount(page.request, session, 'grace');
  const target = await findStatusByText(page.request, session, grace.id, POSTS.graceFirst);
  expect(target, 'the seeded status is readable through the API').toBeTruthy();

  try {
    const card = page.locator('li.card').filter({ hasText: POSTS.graceFirst }).first();
    await expect(card).toBeVisible();

    // A previous failed run may have left the star active; the baseline is the
    // same either way, so only click when there is something to add.
    const add = card.getByTitle('Add to favourites');
    if (await add.count()) await add.click();
    await expect(card.getByTitle('Remove from favourites')).toBeVisible();

    await prepareVisualPage(page, card);
    await expect(card).toHaveScreenshot('status-card-favourited.png', {
      mask: volatileMasks(page),
    });
  } finally {
    await unfavouriteStatus(page.request, session, target.id);
  }
});
