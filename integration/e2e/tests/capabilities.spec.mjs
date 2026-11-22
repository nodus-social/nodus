// Functional: the capability list is the server's answer, and the shell reads
// it before it paints.
//
// The lab advertises 28 features at GET /api/v1/meta since b81569c, admin and
// moderation among them, and admin@nodus.test is the instance's bootstrap
// administrator (staff_role = admin). So both halves of a capability-driven
// shell have something to answer: a staff door for a staff account, and a page
// that carries the list the client gates on for every reader.
//
// RED ON PURPOSE. Both tests below fail at this build, for the reasons each
// one states in its message:
//
//  - the Administration door is drawn by the server from `Session::admin`,
//    which sign-in fills from `Client::is_staff()` — a read of
//    /api/v2/admin/accounts, which answers 403 "This action requires the
//    admin:read scope" for the read/write/follow grant the lab signs in with
//    (web/crates/web-client/src/state/bridge/session/mod.rs, `scopes`), so no
//    account is ever staff as far as the shell is concerned;
//  - the #nodus-page island the server renders (web/crates/web-server/src/
//    document.rs, `Island`) carries the page's data and no capability list, so
//    the first paint cannot know what the instance serves without the probe
//    the browser makes after wasm boots.
//
// Waiting on: a staff answer the read/write/follow grant can obtain, and the
// capability list in the server's own page.

import { expect, test } from '@playwright/test';

import { ACCOUNTS, BASE_URL, INSTANCE_HOST } from '../fixtures.mjs';
import { signIn } from '../helpers/session.mjs';

/// Hands the session to the SSR host and returns the origin's answer to a GET,
/// so a test reads the document the server sends rather than the DOM wasm has
/// already rewritten (docs/dev-loop.md: the cookie is the only way in).
async function serverDocument(request, token, path) {
  const handoff = await request.post(`${BASE_URL}/api/session`, {
    data: { host: INSTANCE_HOST, token },
  });
  expect(handoff.ok(), 'the server accepted the proven token').toBe(true);
  const response = await request.get(`${BASE_URL}${path}`);
  expect(response.status(), `${path} answers a signed-in reader`).toBe(200);
  return response.text();
}

/// The capability names buried anywhere in the page's island JSON.
///
/// The shape is the implementer's (a `features` key, a field beside it, one
/// array per surface); what matters is that the document names the capabilities
/// the client gates on, so the first paint needs no probe. This walks the JSON
/// for a string array holding the vocabulary `bridge::feature` is asked about.
function featureList(carried) {
  const wanted = ['admin', 'moderation', 'drive', 'feed_accounts'];
  const queue = [carried];
  while (queue.length > 0) {
    const node = queue.shift();
    if (Array.isArray(node)) {
      if (node.every((entry) => typeof entry === 'string')) {
        if (wanted.every((name) => node.includes(name))) return node;
      }
      queue.push(...node);
    } else if (node && typeof node === 'object') {
      queue.push(...Object.values(node));
    }
  }
  return null;
}

test('a nodus server that advertises admin gives its administrator the door', async ({
  page,
  request,
}, testInfo) => {
  // The rail is the desktop layout's answer to "where am I"; the narrow
  // viewports draw no rail at all, so a door test there would pass or fail for
  // the layout and not for the capability.
  test.skip(
    testInfo.project.name !== 'desktop',
    'the staff doors are drawn in the desktop rail',
  );
  const session = await signIn(page, ACCOUNTS.admin);

  // The positive control: the list this spec is about names the capability.
  // Fetched from the page's own origin, the way the client's probe does
  // (web/crates/web-client/src/state/bridge/mod.rs, `probe_extensions`).
  const meta = await page.evaluate(async () => {
    const answer = await fetch('/api/v1/meta');
    return { ok: answer.ok, body: await answer.json() };
  });
  expect(meta.ok, 'the page fetched its own capability list').toBe(true);
  expect(meta.body.features, 'this server names the admin capability').toContain(
    'admin',
  );

  // The rail is painted by the server before wasm runs, so the door the reader
  // sees is in the document: document.rs turns the staff flag into these rows.
  const html = await serverDocument(request, session.token, '/home');
  expect(
    html,
    'the server paints the Administration door for a staff account',
  ).toContain('href="/admin"');
  expect(html).toContain('Administration');
});

test('the page the server renders carries the capability list the client gates on', async ({
  page,
  request,
}) => {
  const session = await signIn(page, ACCOUNTS.ada);
  const html = await serverDocument(request, session.token, '/home');

  const island = /<script id="nodus-page" type="application\/json">([\s\S]*?)<\/script>/.exec(
    html,
  );
  expect(island, 'the page hands the client its data in #nodus-page').not.toBeNull();

  const carried = featureList(JSON.parse(island[1]));
  expect(
    carried,
    'the rendered page names the capabilities the client gates its surfaces on',
  ).not.toBeNull();

  // The page's answer is the endpoint's answer: one list, so a surface is off
  // because the server said so, not because two readers disagreed.
  const meta = await request.get(`${BASE_URL}/api/v1/meta`);
  const { features } = await meta.json();
  expect(carried).toEqual(features);
});
