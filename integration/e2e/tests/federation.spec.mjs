// Functional: federation proof (d). A post authored on the Mastodon peer is
// stored by this origin and rendered through the lab shell's own search screen,
// with the federated handle and the peer's text in the DOM. The federated
// timeline would be the natural surface, but the client's Federated request
// omits `local=false`, so the API answers with local posts only; the search
// screen reads the same stored statuses and paints them through the same card.
//
// Needs the peers; without them the test skips with that reason (helpers/peers.mjs).

import { expect, test } from '@playwright/test';

import { ACCOUNTS } from '../fixtures.mjs';
import { navigate } from '../helpers/navigation.mjs';
import { PEER_ACCT, requirePeerAccount } from '../helpers/peers.mjs';
import { signIn } from '../helpers/session.mjs';

// The newest post the peer's Create activity delivered, asserted through the
// API first so a failure says whether the data or the paint went missing.
const PEER_POST = 'hello from mastodon, follows are live';

test('a peer-authored post renders through the lab shell', async ({ page }) => {
  const session = await signIn(page, ACCOUNTS.ada);
  const peer = await requirePeerAccount(page.request, session);
  expect(peer.acct, 'the origin stored the peer under its federated handle').toBe(PEER_ACCT);

  await navigate(page, '/search');
  await page.locator('input[type="search"]').fill(PEER_POST);
  await page.getByRole('button', { name: 'Search' }).click();

  const card = page.locator('li.card').filter({ hasText: PEER_POST }).first();
  await expect(card).toBeVisible();
  // The status header prints acct verbatim; the leading @ is the reader's.
  await expect(card.locator('header')).toContainText(PEER_ACCT);
  await expect(card).toContainText(PEER_POST);
});
