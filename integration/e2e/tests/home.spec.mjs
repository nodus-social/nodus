// Functional: a seeded reader signs in through the real OAuth flow and the
// home timeline shows a followed account's post, both in the DOM and in the
// API response the DOM was built from.

import { expect, test } from '@playwright/test';

import { ACCOUNTS, POSTS } from '../fixtures.mjs';
import { signIn, API_BASE } from '../helpers/session.mjs';

test('home timeline shows posts from a followed account', async ({ page }) => {
  const session = await signIn(page, ACCOUNTS.ada);

  await expect(page.getByText(POSTS.graceFirst)).toBeVisible();

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
