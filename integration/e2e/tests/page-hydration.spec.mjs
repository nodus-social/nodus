// Functional: a signed-in profile or thread document arrives already hydrated, so the
// browser never reads the subject for itself.
//
// The wiring under test: nodus-backend 9d3f232 + 143771f serve one snapshot per entity at
// GET /api/v1/pages/profile/{id} and /api/v1/pages/status/{id} and advertise `pages` in
// /api/v1/meta; web 116f3f0 paints the document from that one read and hands the same
// payload to the client in the #nodus-page island; web 7df9c54 gates it on the SDK's
// published feature, and web 85507f1 seeds the profile relationship from the island.
//
// Three assertions, each observed at the layer that can see it:
//
//  1. the browser makes no subject read: signed-in /status/{id} and /accounts/{id} issue
//     zero requests for the subject under test — no /api/v1/pages/, no
//     /api/v1/statuses/{id}, no /api/v1/statuses/{id}/context, no /api/v1/accounts/{id}.
//     The document request is a navigation, not an XHR, and is asserted separately so a
//     failed load cannot be mistaken for a clean zero;
//  2. the island carries what the client trusts: `kind`, the thread's status id and its
//     context arrays, the profile's account id, statuses and relationship;
//  3. a second visit to the same thread is still zero subject reads per load, so a
//     "hydrate on every mount" regression fails here.
//
// The subject is Grace (`PROFILE_HANDLE`) and the viewer is Ada: the profile assertion
// below deliberately names a relationship the viewer actually has. Mastodon answers
// `null` for a viewer's own relationship, so an own profile could not prove the island
// carried one even when it did.
//
// The page read itself happens server-side, while the document is rendered
// (web/crates/web-server/src/pages.rs, `read_entity_with` -> `reads.profile_page` /
// `reads.status_page`), so it is invisible to `page.on('request')` and cannot be counted
// from the browser. The count is proven where it happens: nodus-backend
// crates/api/tests/pages.rs pins the profile page at 13 statements for the id form and 14
// for the handle form (the extra is the explicit `COMMIT`), and the thread page at 12. One
// assertion, one owner.
//
// The lab's running images predate this wiring (built 2026-11-23 04:22-04:25 UTC, while
// the pages commits and the instance-host fix land later), so each test is marked fixme
// with that as the stated reason instead of being weakened to pass against a shell that
// paints the old path.
//
// What the gate-lifted run answered on 2026-11-23: the pre-`pages` renderer assembles the
// thread server-side and paints the same {"kind":"thread"} island, so "the island exists"
// does not discriminate the new wiring; the browser made zero /api/v1/pages/ reads. On the
// profile island the pre-pages path carried account and statuses but `relationship` was
// `null` (the pre-pages renderer passes `None`). That null was NOT a signed-out paint: the
// session was signed in and the API's `/api/v1/pages/profile/{id}` answered
// `{following:true}` for the same reader. The gate asked `serves_pages` about `""`, because
// a local session's acct (`"ada"`) has no `@host` and `read_entity_with` derived the host
// from `split_once('@')` instead of the session's own host. Assertion 2's relationship
// check is the one that discriminates; assertion 1 is what fails if hydration starts
// re-fetching.

import { expect, test } from '@playwright/test';

import { ACCOUNTS, BASE_URL, INSTANCE_HOST, POSTS, PROFILE_HANDLE } from '../fixtures.mjs';
import { signIn } from '../helpers/session.mjs';

const FIXME_REASON =
  'the lab image predates the instance-host fix for local sessions; re-enable after the next build-from-pins';

/// Whether the lab's shell can serve a page at all: `pages` is what the server asks
/// capabilities::serves_pages before it takes the one-read path. A lab whose handshake
/// does not answer at all serves no pages either, so it skips for the same reason.
let advertised;
async function pagesAreServed(request) {
  if (advertised === undefined) {
    const meta = await request.get(`${BASE_URL}/api/v1/meta`);
    if (!meta.ok()) {
      advertised = false;
    } else {
      const body = await meta.json();
      advertised = Array.isArray(body.features) && body.features.includes('pages');
    }
  }
  return advertised;
}

/// The island the server painted, parsed rather than regex-ed out of the whole document.
/// It is one `<script id="nodus-page" type="application/json">`; the server escapes `</`
/// inside it so the closing tag is unambiguous (web/crates/web-server/src/document.rs).
function paintedIsland(html) {
  const match = /<script id="nodus-page" type="application\/json">([\s\S]*?)<\/script>/.exec(html);
  expect(match, 'the document carries a #nodus-page island').not.toBeNull();
  return JSON.parse(match[1]);
}

/// The seeded account and one of its statuses, resolved the way the client would: by
/// handle, through the API, rather than by the id Postgres assigned at seed time.
async function subject(page, session) {
  const headers = { Authorization: `Bearer ${session.token}` };
  const lookup = await page.request.get(
    `${BASE_URL}/api/v1/accounts/lookup?acct=${PROFILE_HANDLE}`,
    { headers },
  );
  expect(lookup.ok(), 'the seeded profile is findable by handle').toBe(true);
  const account = await lookup.json();
  const statuses = await page.request.get(`${BASE_URL}/api/v1/accounts/${account.id}/statuses`, {
    headers,
  });
  expect(statuses.ok(), "the profile's posts answer").toBe(true);
  const posts = await statuses.json();
  expect(posts.length, 'the seed left the profile a post').toBeGreaterThan(0);
  // The API orders a profile newest-first, so the thread under test is resolved by the
  // text the seed wrote, not by position.
  const status = posts.find((post) => (post.content ?? '').includes(POSTS.graceFirst));
  expect(status, "the seed left Grace's first post on her profile").toBeTruthy();
  return {
    accountId: String(account.id),
    statusId: String(status.id),
    statusText: POSTS.graceFirst,
  };
}

/// Every request the browser makes while `url` loads and settles, in order, with the kind
/// of request so a navigation can be told from an XHR.
///
/// Settling is network-idle rather than a timer: the claim is that the page makes no
/// read, so a wait long enough to miss one would prove nothing.
async function requestsDuring(page, url) {
  const requests = [];
  const record = (request) =>
    requests.push({ url: request.url(), type: request.resourceType() });
  page.on('request', record);
  try {
    await page.goto(url);
    await page.waitForLoadState('networkidle');
    return requests;
  } finally {
    page.off('request', record);
  }
}

const pathOf = (url) => new URL(url).pathname;

/// Any page-API read: the server should have made it, not the browser.
const pageReads = (requests) =>
  requests.filter((request) => pathOf(request.url).startsWith('/api/v1/pages/'));

/// Reads of the subject under test through the old per-entity endpoints. The prefix checks
/// cover the suffixes that hydration used to fetch separately: `/statuses/{id}/context`
/// and `/accounts/{id}/statuses`, `/accounts/{id}/relationships`.
const subjectReads = (requests, id) =>
  requests.filter(({ url }) => {
    const path = pathOf(url);
    return (
      path === `/api/v1/statuses/${id}` ||
      path.startsWith(`/api/v1/statuses/${id}/`) ||
      path === `/api/v1/accounts/${id}` ||
      path.startsWith(`/api/v1/accounts/${id}/`)
    );
  });

/// The document itself, so a zero read count is only accepted when the page actually
/// loaded. `/status/{id}` and `/accounts/{id}` are navigations; nothing above matches them.
const documentFor = (requests, path) =>
  requests.filter((request) => request.type === 'document' && pathOf(request.url) === path);

test('a signed-in entity load makes no subject read from the browser', async ({ page, request }) => {
  test.fixme(!(await pagesAreServed(request)), FIXME_REASON);

  const session = await signIn(page, ACCOUNTS.ada);
  const { accountId, statusId, statusText } = await subject(page, session);

  const threadPath = `/status/${statusId}`;
  const thread = await requestsDuring(page, threadPath);
  await expect(page.getByText(statusText)).toBeVisible();
  expect(documentFor(thread, threadPath).length, 'the thread document was fetched').toBe(1);
  expect(pageReads(thread), 'the browser never reads the page API; SSR already did').toEqual([]);
  expect(
    subjectReads(thread, statusId),
    'hydration does not re-read the thread through /api/v1/statuses/{id}',
  ).toEqual([]);

  const profilePath = `/accounts/${accountId}`;
  const profile = await requestsDuring(page, profilePath);
  await expect(page.getByText(statusText)).toBeVisible();
  expect(documentFor(profile, profilePath).length, 'the profile document was fetched').toBe(1);
  expect(pageReads(profile), 'the browser never reads the page API; SSR already did').toEqual([]);
  expect(
    subjectReads(profile, accountId),
    'hydration does not re-read the profile through /api/v1/accounts/{id}',
  ).toEqual([]);
});

test('the island carries the fields the client trusts', async ({ page, request }) => {
  test.fixme(!(await pagesAreServed(request)), FIXME_REASON);

  const session = await signIn(page, ACCOUNTS.ada);
  const { accountId, statusId } = await subject(page, session);

  const handoff = await request.post(`${BASE_URL}/api/session`, {
    data: { host: INSTANCE_HOST, token: session.token },
  });
  expect(handoff.status(), 'the server accepted the proven token').toBe(200);

  const threadResponse = await request.get(`${BASE_URL}/status/${statusId}`);
  expect(threadResponse.status(), '/status/{id} answers a signed-in reader').toBe(200);
  const thread = paintedIsland(await threadResponse.text());
  expect(thread.kind).toBe('thread');
  expect(String(thread.status?.id)).toBe(statusId);
  expect(Array.isArray(thread.context?.ancestors)).toBe(true);
  expect(Array.isArray(thread.context?.descendants)).toBe(true);
  // The seed posts no replies (integration/scripts/seed.sh never sets in_reply_to_id), so
  // there is nothing to be non-empty yet; when the fixture gains a reply, assert its id
  // appears in `descendants` (and the ancestor's in `ancestors`).

  const profileResponse = await request.get(`${BASE_URL}/accounts/${accountId}`);
  expect(profileResponse.status(), '/accounts/{id} answers a signed-in reader').toBe(200);
  const profile = paintedIsland(await profileResponse.text());
  expect(profile.kind).toBe('account');
  expect(String(profile.account?.id)).toBe(accountId);
  expect(Array.isArray(profile.statuses)).toBe(true);
  expect(profile.statuses.length, 'the first page of posts travels with the profile').toBeGreaterThan(
    0,
  );
  // Ada follows Grace in the seed (`follow "$ADA_TOKEN" "$GRACE_ID" grace`), so this is
  // the relationship the one-read payload must carry. On the stale image it was null:
  // the pre-pages path did not ask for a relationship at all. The subject is asserted to
  // be someone else's profile first, because a viewer's own relationship is null by
  // design and would make this assertion say nothing.
  expect(String(profile.account?.acct), 'the subject is not the viewer').not.toBe(session.acct);
  expect(
    profile.relationship,
    'the one-read profile carries the viewer relationship',
  ).toBeInstanceOf(Object);
  expect(profile.relationship?.following).toBe(true);
});

test('a second visit is still zero subject reads per load', async ({ page, request }) => {
  test.fixme(!(await pagesAreServed(request)), FIXME_REASON);

  const session = await signIn(page, ACCOUNTS.ada);
  const { statusId, statusText } = await subject(page, session);
  const threadPath = `/status/${statusId}`;

  const first = await requestsDuring(page, threadPath);
  await expect(page.getByText(statusText)).toBeVisible();
  const second = await requestsDuring(page, threadPath);
  await expect(page.getByText(statusText)).toBeVisible();

  for (const [name, requests] of [
    ['first', first],
    ['second', second],
  ]) {
    expect(documentFor(requests, threadPath).length, `the ${name} load fetched the document`).toBe(
      1,
    );
    expect(pageReads(requests), `${name} load pays no page read in the browser`).toEqual([]);
    expect(
      subjectReads(requests, statusId),
      `the ${name} load does not re-read the thread through /api/v1/statuses/{id}`,
    ).toEqual([]);
  }
});
