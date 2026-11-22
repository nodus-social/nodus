// Functional: a signed-in reader's browser talks to their own server and
// nobody else. Opening a remote post is the case that matters — the post was
// authored on a peer, and a client that fetches it from the peer's address
// hands the reader's request (and the peer's certificate) to a third party for
// a page their own instance already holds.
//
// This origin stored the post (federation.spec.mjs proves the store), so the
// rows it needs are here; the browser's only job is to ask for them here.
//
// Green at this build: `/status/{host}/{id}` reads the stored row through
// this origin and the page asks nothing of the peer. Keeping the spec keeps it
// that way — the proxy's relay path (one id this origin never stored, noted in
// integration/docs/e2e-gaps.md) is the next thing that could leak a host, and
// media URLs copied off a peer are the other.
//
// Every request the page makes is recorded and the test fails listing the ones
// whose host is not the lab's. The rendered post is asserted first, so a
// failure says whether the paint or the routing went wrong: an empty page would
// otherwise pass an empty request log.
//
// Needs the peers. Without them the test skips with that reason rather than
// passing on a page it never opened (helpers/peers.mjs).

import { expect, test } from '@playwright/test';

import { ACCOUNTS, BROWSER_ORIGIN, INSTANCE_HOST } from '../fixtures.mjs';
import { navigate } from '../helpers/navigation.mjs';
import { PEER_ACCT, requirePeerStatus } from '../helpers/peers.mjs';
import { signIn } from '../helpers/session.mjs';

// The post the peer's Create activity delivered; the API assertion in front of
// the paint says whether the data or the browser's route went missing.
const PEER_POST = 'hello from mastodon, follows are live';

const [PEER_NAME, PEER_HOST] = PEER_ACCT.split('@');

// The address this origin prints for a remote author's post: the id in it is
// the one THIS origin minted (integration/docs/e2e-gaps.md records the form).
const remotePost = (status) => `/status/${PEER_HOST}/${status.id}`;

test('a signed-in reader opening a remote post talks only to their own server', async ({
  page,
}) => {
  const session = await signIn(page, ACCOUNTS.ada);
  const status = await requirePeerStatus(page.request, session, PEER_POST);
  expect(status.account.acct, 'the stored status is the peer\'s').toBe(PEER_ACCT);

  // Recorded from here: the sign-in's own hops are not what this spec is
  // about, and the OAuth handoff is its own conversation with this server.
  const elsewhere = [];
  const here = [];
  page.on('request', (request) => {
    const url = request.url();
    if (!url.startsWith('http://') && !url.startsWith('https://')) return;
    const { host } = new URL(url);
    if (host === INSTANCE_HOST) here.push(`${request.method()} ${url}`);
    else elsewhere.push(`${request.method()} ${url}`);
  });

  await navigate(page, remotePost(status));

  // The post is on screen: the page resolved the remote author through this
  // origin's store, which is the read this spec holds to one origin.
  const card = page.locator('li.card, article').filter({ hasText: PEER_POST }).first();
  await expect(card).toBeVisible();
  await expect(card).toContainText(PEER_ACCT);

  // Nothing the browser asked for left the lab's origin. The cookie is
  // HttpOnly and same-origin; a request to the peer would carry neither the
  // reader's session nor this origin's answer.
  expect(here.length, 'the listener saw the reads the page made').toBeGreaterThan(0);
  expect(
    elsewhere,
    `the browser asked only ${BROWSER_ORIGIN} while opening a remote post`,
  ).toEqual([]);

  // The peer's canonical address is a link out, not a fetch: the card offers
  // it and the page itself never reached for it.
  expect(await card.getByRole('link', { name: PEER_NAME }).count()).toBeGreaterThan(0);
});
