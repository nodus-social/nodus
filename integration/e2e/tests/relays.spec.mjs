// Functional: the relay write path, driven with an administration-scoped
// token, and the two reasons the same door refuses an ordinary session.
//
// `Authenticated::allows` is hierarchical only within a scope family, so a
// `read write follow` token — the one every other spec signs in with — can
// neither read nor write `/api/v1/admin/relays`. This spec signs in again with
// the grant the console requests for administration (`read write follow
// admin:read admin:write`) and exercises POST and DELETE, which no other spec
// has done against a shipped backend.
//
// What this does NOT prove: that a relay accepts the subscription, or that any
// federation happens. The lab has no relay listening at the test inbox, so the
// backend queues a Follow activity and the row stays `pending`; delivery is a
// queue this spec cannot read. The assertions below are about the API's
// bookkeeping, not about another instance.
//
// The lab must be left exactly as it was found, so any relay at the test inbox
// is removed before the flow and the one this spec creates is removed after it
// — including when an assertion fails halfway. The seeded lab subscribes no
// relay, so a clean run starts and ends at zero.

import { expect, test } from '@playwright/test';

import { ACCOUNTS } from '../fixtures.mjs';
import { authHeaders } from '../helpers/api.mjs';
import { API_BASE, signIn, signInWithAdminScopes } from '../helpers/session.mjs';

const RELAYS = `${API_BASE}/api/v1/admin/relays`;
const INBOX = 'https://relay.example/actor';

async function listRelays(request, session) {
  const response = await request.get(RELAYS, { headers: authHeaders(session) });
  expect(response.status(), 'GET /api/v1/admin/relays answers 200').toBe(200);
  const relays = await response.json();
  expect(Array.isArray(relays), 'the relay list is an array').toBe(true);
  return relays;
}

async function unsubscribe(request, session, id, allowed) {
  const response = await request.delete(`${RELAYS}/${id}`, {
    headers: authHeaders(session),
  });
  expect(
    allowed,
    `DELETE /api/v1/admin/relays/${id} answers ${allowed.join(' or ')}`,
  ).toContain(response.status());
  return response;
}

test('an admin-scoped token subscribes and unsubscribes a relay', async ({
  page,
  request,
}) => {
  const session = await signInWithAdminScopes(page, ACCOUNTS.admin);

  // Converge on a clean slate: a previous interrupted run may have left the
  // test inbox subscribed, and POST would then answer 422 instead of 200.
  const before = await listRelays(request, session);
  for (const relay of before.filter((relay) => relay.inbox_url === INBOX)) {
    await unsubscribe(request, session, relay.id, [200, 204]);
  }
  const baseline = (await listRelays(request, session)).length;

  let created = null;
  try {
    // The form shape the console sends; the handler accepts form or JSON.
    const added = await request.post(RELAYS, {
      headers: authHeaders(session),
      form: { inbox_url: INBOX },
    });
    expect(added.status(), 'POST /api/v1/admin/relays answers 200').toBe(200);
    const relay = await added.json();
    expect(relay.inbox_url).toBe(INBOX);
    expect(relay.id, 'the new subscription carries an id').toBeTruthy();
    expect(relay.state, 'a queued subscription starts pending').toBe('pending');
    created = relay.id;

    const duplicate = await request.post(RELAYS, {
      headers: authHeaders(session),
      form: { inbox_url: INBOX },
    });
    expect(duplicate.status(), 'subscribing twice answers 422').toBe(422);
    expect((await duplicate.json()).error).toMatch(/already subscribed/);

    const malformed = await request.post(RELAYS, {
      headers: authHeaders(session),
      form: { inbox_url: 'not a url' },
    });
    expect(malformed.status(), 'a malformed inbox answers 422').toBe(422);
    expect((await malformed.json()).error).toMatch(/https URL/);

    await unsubscribe(request, session, created, [200, 204]);
    created = null;

    const after = await listRelays(request, session);
    expect(after, 'the list is back to its previous length').toHaveLength(baseline);
    expect(
      after.filter((relay) => relay.inbox_url === INBOX),
      'the test inbox is no longer subscribed',
    ).toHaveLength(0);
  } finally {
    if (created) {
      // Cleanup after a failed assertion must not become a second failure of
      // its own, so a 404 (already gone) is tolerated here only.
      await request.delete(`${RELAYS}/${created}`, { headers: authHeaders(session) });
    }
  }
});

test('a staff token without the admin family is refused the scope it lacks', async ({
  page,
  request,
}) => {
  const session = await signIn(page, ACCOUNTS.admin);

  const response = await request.get(RELAYS, { headers: authHeaders(session) });
  expect(response.status()).toBe(403);
  expect(
    (await response.json()).error,
    'the refusal names the scope the token lacks',
  ).toBe('This action requires the admin:read scope');
});

test('a token from a non-staff account is refused for the missing role', async ({
  page,
  request,
}) => {
  const session = await signIn(page, ACCOUNTS.ada);

  const response = await request.get(RELAYS, { headers: authHeaders(session) });
  expect(response.status()).toBe(403);
  expect(
    (await response.json()).error,
    'the role is checked before the scope, so this door names the role',
  ).toBe('Administrator access is required');
});
