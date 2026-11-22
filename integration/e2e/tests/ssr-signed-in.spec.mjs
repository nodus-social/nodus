// Functional: a signed-in page is rendered by the server, not by the browser
// asking for its data afterwards. GET /home with a valid session cookie must
// already carry the reader's timeline in the bytes that arrive.
//
// The assertion is on the response body on purpose: the hydrated DOM would say
// nothing about who fetched the posts, and the campaign's claim is that the
// first paint needs no client-side fetch. So the document's own post cards are
// counted against the page the API reports for the same reader — if the two
// disagree, the document is a shell waiting for wasm.
//
// Green at this build: the signed-in /home already carries the reader's
// timeline and the island's statuses. This spec stays as the contract the
// server-side rendering must keep — it is the assertion a client-fetch shell
// would fail, and the one a later "render the shell, fetch in wasm" change
// would break.
//
// The session cookie is minted the way the client mints it (POST /api/session,
// web/crates/web-client/src/state/bridge/session/mod.rs, `announce_to_server`),
// from a token proved by the real OAuth sign-in.

import { expect, test } from '@playwright/test';

import { ACCOUNTS, BASE_URL, INSTANCE_HOST, POSTS } from '../fixtures.mjs';
import { signIn } from '../helpers/session.mjs';

test('GET /home answers with the signed-in timeline already in the document', async ({
  page,
  request,
}) => {
  const session = await signIn(page, ACCOUNTS.ada);

  const handoff = await request.post(`${BASE_URL}/api/session`, {
    data: { host: INSTANCE_HOST, token: session.token },
  });
  expect(handoff.status(), 'the server accepted the proven token').toBe(200);

  const document = await request.get(`${BASE_URL}/home`);
  expect(document.status(), 'the signed-in home answers').toBe(200);
  const html = await document.text();

  // The reader's own timeline, in the bytes the server sent: Grace's post is
  // on Ada's home because the seed has Ada following her.
  expect(
    html,
    'the document already carries a followed account\'s post',
  ).toContain(POSTS.graceFirst);

  // Same reader, same page, through the API: the document carries the first
  // page the API reports, not a placeholder the browser fills afterwards.
  const api = await request.get(`${BASE_URL}/api/v1/timelines/home?limit=20`, {
    headers: { Authorization: `Bearer ${session.token}` },
  });
  expect(api.status(), 'the API answers the same reader').toBe(200);
  const statuses = await api.json();
  expect(statuses.length, 'the seed left the reader a timeline').toBeGreaterThan(0);

  const drawn = html.match(/<li class="card /g) ?? [];
  expect(
    drawn.length,
    'the document carries every post the API reports for this reader',
  ).toBe(statuses.length);

  // And it is the same posts, not the same number of empty cards.
  for (const status of statuses) {
    const text = /<p>(.*?)<\/p>/.exec(status.content)?.[1] ?? '';
    if (text.trim()) expect(html).toContain(text.trim());
  }
});
