// Functional: a server that publishes no capability list is a server the shell
// must not pretend to fully serve. The answer is intercepted in the browser and
// replaced with a Mastodon-shaped one — a `/api/v1/meta` with no `features` at
// all, which is what a peer instance answers and what the client reads as
// "nothing beyond the baseline is served"
// (web/crates/web-client/src/state/bridge/mod.rs, `features_of`).
//
// What the reader gets: no staff doors, no error, and the surfaces a reader
// cannot do without — the home timeline and a profile — still work. The point
// of the negative is that the doors are absent *because the answer said so*:
// tests/capabilities.spec.mjs pins the same server advertising admin and the
// door painted, so this file is not passing on a shell that never draws one.
//
// The assertion that pins the behaviour is `[role="alert"]` count 0: the
// current shell turns the missing capabilities into a sentence the reader has
// to read instead of simply not drawing the controls
// (web/crates/web-client/src/routes/home/trouble.rs is the pattern).

import { expect, test } from '@playwright/test';

import { ACCOUNTS, POSTS, PROFILE_HANDLE } from '../fixtures.mjs';
import { lookupAccount } from '../helpers/api.mjs';
import { navigate } from '../helpers/navigation.mjs';
import { signIn } from '../helpers/session.mjs';

// A Mastodon instance document: every field a peer publishes, and no feature
// list. Mastodon's own answer is the credential-free shape this lab's "no
// capabilities" case is about, and it is what a browser gets when it signs in
// to a peer's address.
const MASTODON_SHAPED = {
  uri: 'nodus.test',
  title: 'Nodus',
  email: 'ops@nodus.test',
  version: '4.6.3',
  description: 'The integration lab.',
  languages: ['en'],
  registrations: false,
  approval_required: false,
};

test('a server that publishes no capability list draws no staff doors and no error', async ({
  page,
}, testInfo) => {
  await page.route('**/api/v1/meta', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(MASTODON_SHAPED),
    }),
  );

  const session = await signIn(page, ACCOUNTS.ada);
  expect(session.acct, 'the reader this test speaks for is signed in').toBe('ada');

  // The interceptor is in force for the client's own probe, not only for a
  // request the spec makes: the reader's page is the one under test.
  const probe = await page.evaluate(async () => {
    const answer = await fetch('/api/v1/meta');
    return answer.json();
  });
  expect(probe.features, 'the page sees the server without a feature list').toBeUndefined();

  // Staff doors: the server said nothing about admin or moderation. Only the
  // desktop layout draws a rail, so the negative is only evidence there — the
  // rest of the test holds on all three.
  if (testInfo.project.name === 'desktop') {
    await expect(page.getByRole('link', { name: 'Administration', exact: true })).toHaveCount(0);
    await expect(page.getByRole('link', { name: 'Moderation', exact: true })).toHaveCount(0);
  }

  // No error anywhere: not the feed's failure card, not a toast, not a banner.
  // A capability the server does not advertise is not a failure the reader
  // caused, so it is never reported as one.
  await expect(page.locator('[role="alert"]')).toHaveCount(0);
  await expect(page.getByText(/failed/i)).toHaveCount(0);

  // The essential surface: the home timeline is still the home timeline.
  const card = page.locator('li.card').filter({ hasText: POSTS.graceFirst }).first();
  await expect(card).toBeVisible();
  await expect(page.locator('[role="alert"]')).toHaveCount(0);

  // And a profile still resolves through this origin.
  const grace = await lookupAccount(page.request, session, PROFILE_HANDLE);
  await navigate(page, `/accounts/${grace.id}`);
  await expect(page.getByText(POSTS.graceFirst).first()).toBeVisible();
  await expect(page.locator('[role="alert"]')).toHaveCount(0);
});
