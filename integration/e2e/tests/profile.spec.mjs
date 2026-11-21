// Functional: a signed-in reader asks for another seeded account's profile and
// gets that account's real data — identity, its posts and the follow edge the
// seed created.
//
// The assertions go through the API with the token the sign-in helper stored,
// not through /@grace in the DOM: the profile screen reads
// /public-api/account/{host}/{name}, and that proxy in the SSR host only speaks
// to public https instances (web/crates/web-server/src/validate.rs), so an http
// lab origin answers 400 by design. integration/README.md records that
// limitation; this spec keeps the profile data itself covered.

import { expect, test } from '@playwright/test';

import { ACCOUNTS, POSTS, PROFILE_HANDLE } from '../fixtures.mjs';
import { signIn, API_BASE } from '../helpers/session.mjs';

test('profile of a seeded account shows its posts and follow edge', async ({
  page,
}) => {
  const session = await signIn(page, ACCOUNTS.ada);

  const headers = { Authorization: `Bearer ${session.token}` };

  // Resolve the handle the way the client would: by name, on this instance,
  // rather than by the id Postgres assigned at seed time.
  const lookup = await page.request.get(
    `${API_BASE}/api/v1/accounts/lookup?acct=${PROFILE_HANDLE}`,
    { headers },
  );
  expect(lookup.ok()).toBeTruthy();
  const profile = await lookup.json();
  expect(profile.acct).toBe(PROFILE_HANDLE);
  expect(profile.id).toBeTruthy();

  const statuses = await page.request.get(
    `${API_BASE}/api/v1/accounts/${profile.id}/statuses`,
    { headers },
  );
  expect(statuses.ok()).toBeTruthy();
  const posts = await statuses.json();
  expect(
    posts.some((status) => status.content.includes(POSTS.graceFirst)),
    "profile lists Grace's seeded post",
  ).toBe(true);

  // Ada follows Grace (seed.sh), so the profile a reader sees carries the edge.
  const relationships = await page.request.get(
    `${API_BASE}/api/v1/accounts/relationships?id[]=${profile.id}`,
    { headers },
  );
  expect(relationships.ok()).toBeTruthy();
  const [relationship] = await relationships.json();
  expect(relationship.following).toBe(true);
});
