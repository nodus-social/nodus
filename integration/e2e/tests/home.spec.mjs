// Functional: a seeded reader signs in through the real OAuth flow and the
// home timeline shows a followed account's post, both in the DOM and in the
// API response the DOM was built from.

import { expect, test } from '@playwright/test';

import { ACCOUNTS, POSTS } from '../fixtures.mjs';
import { signIn, API_BASE } from '../helpers/session.mjs';

test('home timeline shows posts from a followed account', async ({ page }) => {
  const session = await signIn(page, ACCOUNTS.ada);

  await expect(page.getByText(POSTS.graceFirst)).toBeVisible();

  // The instance the shell is signed in at has to be the lab's canonical name.
  // The shell builds the reader's handle from it (`web/crates/web-client/src/
  // app.rs`, `profile_card`) and sends it as `X-Instance-Host` on every discovery
  // request, where a host:port is refused: a loopback origin painted
  // `discovery request failed` on every signed-in page before the lab named
  // itself nodus.test.
  expect(session.host, 'the browser signed in at the canonical origin').toBe('nodus.test');
  await expect(
    page.getByText('discovery request failed'),
    'the shell never shows a refused discovery request',
  ).toHaveCount(0);

  // The same bearer token over REST: the post exists in the timeline the client
  // reads, not only in whatever the first paint happened to cache.
  const response = await page.request.get(`${API_BASE}/api/v1/timelines/home`, {
    headers: { Authorization: `Bearer ${session.token}` },
  });
  expect(response.ok()).toBeTruthy();
  const timeline = await response.json();
  const texts = timeline.map((status) => status.content);
  expect(
    texts.some((content) => content.includes('Grace was here')),
    'home timeline contains Grace\'s seeded post',
  ).toBe(true);
});

// The rail's profile card is the one place the handle is spelled out, and the
// rail is only drawn in the wide layout (`web/crates/ui/src/components/rail`),
// so this row is desktop-only rather than asserted against nothing on a phone.
test('the rail names the instance the reader is signed in at', async ({ page }, testInfo) => {
  test.skip(testInfo.project.name !== 'desktop', 'the rail is drawn only in the desktop layout');
  await signIn(page, ACCOUNTS.ada);
  await expect(
    page.getByRole('complementary').getByText(`@${ACCOUNTS.ada.username}@nodus.test`, {
      exact: true,
    }),
    'the rail renders @ada@nodus.test, not a host:port',
  ).toBeVisible();
});
