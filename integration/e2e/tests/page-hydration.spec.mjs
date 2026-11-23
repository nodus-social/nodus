// Functional: a signed-in profile or thread document arrives already hydrated, and each
// load pays for its page once — the client does not fetch the subject a second time.
//
// The wiring under test: nodus-backend 9d3f232 + 143771f serve one snapshot per entity at
// GET /api/v1/pages/profile/{id} and /api/v1/pages/status/{id} and advertise `pages` in
// /api/v1/meta; web acc6754a paints the document from that one read and hands the same
// payload to the client in the #nodus-page island; web 112c0800 gates it on
// Feature::Pages.
//
// Three assertions:
//
//  1. the document carries the payload: {kind:"thread", status, context} for /status/{id},
//     {kind:"account", account, statuses, relationship, cursor} for /accounts/{id};
//  2. one read of /api/v1/pages/ per load, and none of the older
//     /api/v1/accounts/{id} + /api/v1/statuses/{id} reads for the same subject after the
//     island has been adopted (that divergence is what the wiring removed);
//  3. a second visit pays one read again (a page is stale-able), never one per mount.
//
// Where the read happens, recorded here so a future reader does not mistake a zero count
// for a missing call: the server makes it while it renders the document
// (web/crates/web-server/src/pages.rs, `read_entity_with` -> `reads.profile_page` /
// `reads.status_page`), so it is not visible to `page.on('request')`. The browser pays no
// page read at all when the island is adoptable: seed.rs `install`/`adopt` fills the
// account, relationship, statuses, status and context before the first component reads
// them (web/crates/web-client/src/state/bridge/seed.rs), and the thread screen skips
// `load_thread` when both are present (web/crates/route/src/route/screens/thread.rs:112).
// Assertion 2 therefore pins the briefed count of 1 and is expected to fail at the next
// build-from-pins; the number is left alone rather than lowered, because lowering it would
// hide which side of the wire pays for the page.
//
// The lab's running images predate this wiring (built 2026-11-23 00:08 CET for web and
// 01:42 UTC for the server, while the pages commits land at 03:14 CET and later), so each
// test is marked fixme with that as the stated reason instead of being weakened to pass
// against a shell that has no island. What the stale lab did answer when the gate was
// lifted for one run (2026-11-23): the thread document already carried a
// {"kind":"thread"} island and the browser made zero /api/v1/pages/ and zero
// /api/v1/statuses/{id} reads, because the pre-pages renderer assembles the thread
// server-side and paints the same island; the profile island carried account and statuses
// but no relationship. So the island alone does not prove the `pages` wiring; the page
// count and the absence of the old subject reads are the discriminating observations.

import { expect, test } from '@playwright/test';

import { ACCOUNTS, BASE_URL, INSTANCE_HOST, POSTS, PROFILE_HANDLE } from '../fixtures.mjs';
import { signIn } from '../helpers/session.mjs';

const FIXME_REASON =
  'the lab image predates the page-hydration wiring; re-enable after the next build-from-pins';

/// Whether the lab's shell can serve a page at all: `pages` is what the server asks
/// capabilities::serves_pages before it takes the one-read path.
let advertised;
async function pagesAreServed(request) {
  if (advertised === undefined) {
    const meta = await request.get(`${BASE_URL}/api/v1/meta`);
    expect(meta.ok(), `${BASE_URL}/api/v1/meta answers`).toBe(true);
    const body = await meta.json();
    advertised = Array.isArray(body.features) && body.features.includes('pages');
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

/// Every request the browser makes while `url` loads and settles, in order.
///
/// Settling is network-idle rather than a timer: the claim is that the page makes no
/// read, so a wait long enough to miss one would prove nothing.
async function requestsDuring(page, url) {
  const urls = [];
  const record = (request) => urls.push(request.url());
  page.on('request', record);
  try {
    await page.goto(url);
    await page.waitForLoadState('networkidle');
    return urls;
  } finally {
    page.off('request', record);
  }
}

const pageReads = (urls) => urls.filter((url) => url.includes('/api/v1/pages/'));

const subjectReads = (urls, id) =>
  urls.filter(
    (url) =>
      url.includes(`/api/v1/accounts/${id}`) || url.includes(`/api/v1/statuses/${id}`),
  );

test('the signed-in thread document carries its island', async ({ page, request }) => {
  test.fixme(!(await pagesAreServed(request)), FIXME_REASON);

  const session = await signIn(page, ACCOUNTS.ada);
  const { statusId } = await subject(page, session);

  const handoff = await request.post(`${BASE_URL}/api/session`, {
    data: { host: INSTANCE_HOST, token: session.token },
  });
  expect(handoff.status(), 'the server accepted the proven token').toBe(200);

  const response = await request.get(`${BASE_URL}/status/${statusId}`);
  expect(response.status(), '/status/{id} answers a signed-in reader').toBe(200);
  const html = await response.text();
  expect(html, 'the document names the island kind in its bytes').toContain('"kind":"thread"');

  const island = paintedIsland(html);
  expect(island.kind).toBe('thread');
  expect(String(island.status?.id)).toBe(statusId);
  expect(Array.isArray(island.context?.ancestors)).toBe(true);
  expect(Array.isArray(island.context?.descendants)).toBe(true);
});

test('the signed-in profile document carries its island', async ({ page, request }) => {
  test.fixme(!(await pagesAreServed(request)), FIXME_REASON);

  const session = await signIn(page, ACCOUNTS.ada);
  const { accountId } = await subject(page, session);

  const handoff = await request.post(`${BASE_URL}/api/session`, {
    data: { host: INSTANCE_HOST, token: session.token },
  });
  expect(handoff.status(), 'the server accepted the proven token').toBe(200);

  const response = await request.get(`${BASE_URL}/accounts/${accountId}`);
  expect(response.status(), '/accounts/{id} answers a signed-in reader').toBe(200);
  const html = await response.text();
  expect(html, 'the document names the island kind in its bytes').toContain('"kind":"account"');

  const island = paintedIsland(html);
  expect(island.kind).toBe('account');
  expect(String(island.account?.id)).toBe(accountId);
  expect(Array.isArray(island.statuses)).toBe(true);
  expect(
    island.statuses.length,
    'the first page of posts travels with the profile',
  ).toBeGreaterThan(0);
  // Ada follows Grace in the seed, and the relationship is part of the one-read payload:
  // the profile effect must not fetch it again (web/crates/route/src/route/screens/account.rs).
  expect(island.relationship?.following).toBe(true);
});

test('a thread and a profile pay one page read each, neither re-reads its subject', async ({
  page,
  request,
}) => {
  test.fixme(!(await pagesAreServed(request)), FIXME_REASON);

  const session = await signIn(page, ACCOUNTS.ada);
  const { accountId, statusId, statusText } = await subject(page, session);

  const thread = await requestsDuring(page, `/status/${statusId}`);
  await expect(page.getByText(statusText)).toBeVisible();
  expect(pageReads(thread).length, 'the thread load pays exactly one page read').toBe(1);
  expect(
    subjectReads(thread, statusId).length,
    'hydration does not re-read the thread through /api/v1/statuses/{id}',
  ).toBe(0);

  const profile = await requestsDuring(page, `/accounts/nodus.test/${accountId}`);
  await expect(page.getByText(statusText)).toBeVisible();
  expect(pageReads(profile).length, 'the profile load pays exactly one page read').toBe(1);
  expect(
    subjectReads(profile, accountId).length,
    'hydration does not re-read the profile through /api/v1/accounts/{id}',
  ).toBe(0);
});

test('a second visit to the same thread pays one read per load, not one per mount', async ({
  page,
  request,
}) => {
  test.fixme(!(await pagesAreServed(request)), FIXME_REASON);

  const session = await signIn(page, ACCOUNTS.ada);
  const { statusId, statusText } = await subject(page, session);
  const url = `/status/${statusId}`;

  const first = await requestsDuring(page, url);
  await expect(page.getByText(statusText)).toBeVisible();
  const second = await requestsDuring(page, url);
  await expect(page.getByText(statusText)).toBeVisible();

  expect(pageReads(first).length, 'the first load pays one page read').toBe(1);
  expect(pageReads(second).length, 'the second load pays one page read, not a cached zero').toBe(1);
  expect(
    subjectReads(first, statusId).length + subjectReads(second, statusId).length,
    'neither load re-reads the thread through /api/v1/statuses/{id}',
  ).toBe(0);
});
