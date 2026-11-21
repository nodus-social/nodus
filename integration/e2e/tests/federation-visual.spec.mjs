// Visual: the peer-authored card as the lab shell paints it. The card is found
// by the delivered text, so a federation regression fails before the screenshot.

import { expect, test } from '@playwright/test';

import { ACCOUNTS } from '../fixtures.mjs';
import { lookupAccount } from '../helpers/api.mjs';
import { navigate } from '../helpers/navigation.mjs';
import { signIn } from '../helpers/session.mjs';
import { prepareVisualPage, volatileMasks } from '../helpers/visual.mjs';

const PEER_ACCT = 'alice@mastodon.test';
const PEER_POST = 'hello from mastodon, follows are live';

test('peer-authored status card', async ({ page }) => {
  const session = await signIn(page, ACCOUNTS.ada);
  const peer = await lookupAccount(page.request, session, PEER_ACCT);
  expect(peer.acct, 'the origin stored the peer under its federated handle').toBe(PEER_ACCT);

  await navigate(page, '/search');
  await page.locator('input[type="search"]').fill(PEER_POST);
  await page.getByRole('button', { name: 'Search' }).click();

  const card = page.locator('li.card').filter({ hasText: PEER_POST }).first();
  await expect(card).toBeVisible();
  await expect(card.locator('header')).toContainText(PEER_ACCT);

  await prepareVisualPage(page, card);
  await expect(card).toHaveScreenshot('peer-status.png', {
    mask: volatileMasks(page),
  });
});
