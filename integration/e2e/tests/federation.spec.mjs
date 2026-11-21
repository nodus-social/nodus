// Functional: federation as a reader meets it. A post authored on the Mastodon
// peer is stored by this origin (proof (d)) and has to be readable on the three
// surfaces a reader would reach: the federated timeline, the author's profile,
// and the post's own permalink.
//
// The first test states what already works — the card in search. The three
// below it state the screens a reader reaches from that card by what is on
// them, not by the status code behind them: the code the broken paths answer
// today (502 from the public proxy) is a symptom, and a spec pinned to it
// would have to be rewritten once the data path is fixed. Two of them fail at
// this build on purpose (integration/docs/e2e-gaps.md records each cause and
// owner); the profile resolves through this origin's own store and passes.
//
// Needs the peers; without them the tests skip with that reason, and an origin
// that stored the peer account but no post skips naming the follow that
// delivers one (helpers/peers.mjs).

import { expect, test } from '@playwright/test';

import { ACCOUNTS, BROWSER_ORIGIN } from '../fixtures.mjs';
import { navigate } from '../helpers/navigation.mjs';
import { PEER_ACCT, requirePeerAccount, requirePeerStatus } from '../helpers/peers.mjs';
import { signIn } from '../helpers/session.mjs';

// The post the peer's Create activity delivered, asserted through the API
// first so a failure says whether the data or the paint went missing.
const PEER_POST = 'hello from mastodon, follows are live';

const [PEER_NAME, PEER_HOST] = PEER_ACCT.split('@');

// The address the shell itself draws for a remote author:
// /accounts/{host}/{name}, the form handles.rs' profile_path_for returns.
const PEER_PROFILE = `/accounts/${PEER_HOST}/${PEER_NAME}`;

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

// Gap: the client asks for the federated stream without `local=false`, so the
// API answers with local posts only (e2e-gaps.md, owner: sdk).
test('the federated timeline shows a peer-authored post', async ({ page }) => {
  const session = await signIn(page, ACCOUNTS.ada);
  const status = await requirePeerStatus(page.request, session, PEER_POST);
  expect(status.account.acct, 'the stored status is the peer\'s').toBe(PEER_ACCT);

  await navigate(page, '/home/federated');

  const card = page.locator('li.card').filter({ hasText: PEER_POST }).first();
  await expect(card).toBeVisible();
  await expect(card.locator('header')).toContainText(PEER_ACCT);
});

// Resolved through this origin's own store (search, then the local id), so the
// screen renders the account and its posts; the public proxy that 502s is only
// the fallback for a handle this origin has never stored.
test('a remote profile lists the account\'s posts', async ({ page }) => {
  const session = await signIn(page, ACCOUNTS.ada);
  await requirePeerStatus(page.request, session, PEER_POST);

  await navigate(page, PEER_PROFILE);

  const post = page.locator('li.card').filter({ hasText: PEER_POST }).first();
  await expect(post).toBeVisible();
});

// The peer's own address for the post, read signed in: the browser sends a
// token, so the public proxy relays the read to the peer with it instead of
// consulting this origin's stored copy.
test('a remote post renders at its permalink', async ({ page }) => {
  const session = await signIn(page, ACCOUNTS.ada);
  const status = await requirePeerStatus(page.request, session, PEER_POST);

  // `/status/{host}/{id}` is the shareable form; the peer's own address for the
  // post names both, and the id is the last segment of it.
  const address = new URL(status.url);
  const id = address.pathname.split('/').filter(Boolean).pop();

  await navigate(page, `/status/${address.host}/${id}`);

  await expect(page.getByText(PEER_POST).first()).toBeVisible();
});

// The link the shell paints for a stored remote post names the peer but carries
// the id THIS origin minted for its copy (web/crates/web-server/src/rows.rs,
// `status_path(Some(&host), &inner.id)`): `/status/mastodon.test/<local ULID>`.
// Only an anonymous caller reads the store for it: `public_api.rs` guards
// `local_read` with `token.is_none()`, so the signed-in test above proxies to
// the peer and keeps passing with `local_read` deleted. This one fails without
// it — the id is not the peer's, so the peer answers 404.
test('an anonymous reader opens a remote post by the id this origin minted', async ({
  page,
  browser,
}) => {
  // The lookup needs a token; the browser under test must not have one, so the
  // session lives in its own context and is closed before the anonymous read.
  const lookup = await browser.newContext({ baseURL: BROWSER_ORIGIN });
  let status;
  try {
    const signedIn = await lookup.newPage();
    const session = await signIn(signedIn, ACCOUNTS.ada);
    status = await requirePeerStatus(signedIn.request, session, PEER_POST);
  } finally {
    await lookup.close();
  }

  // `status.id` is this origin's id for the stored copy, not the peer's id.
  await page.goto(`/status/${PEER_HOST}/${status.id}`);
  await expect(page.getByText(PEER_POST).first()).toBeVisible();
});
