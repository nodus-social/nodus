// Functional: search resolves a handle and free text against the lab's index.
// The account card is a link to the profile, and at this build that link is as
// far as following goes — see the fixme at the bottom.

import { expect, test } from '@playwright/test';

import { ACCOUNTS, POSTS } from '../fixtures.mjs';
import { navigate } from '../helpers/navigation.mjs';
import { signIn } from '../helpers/session.mjs';

async function search(page, query) {
  await navigate(page, '/search');
  await page.locator('input[type="search"]').fill(query);
  await page.getByRole('button', { name: 'Search' }).click();
  await expect(page.getByRole('heading', { name: 'Search' })).toBeVisible();
}

test('search by handle finds the account and its posts', async ({ page }) => {
  await signIn(page, ACCOUNTS.ada);
  await search(page, 'grace');

  const accounts = page.locator('main ul').first();
  await expect(accounts.getByText('@grace')).toBeVisible();
  await expect(accounts.getByRole('link', { name: /grace/ })).toHaveAttribute(
    'href',
    /^\/accounts\//,
  );

  await expect(page.getByText(POSTS.graceFirst)).toBeVisible();
});

test('search by text finds the post body', async ({ page }) => {
  await signIn(page, ACCOUNTS.ada);
  await search(page, 'second note');

  await expect(page.getByText(POSTS.adaSecond)).toBeVisible();
});

// Gap: search renders accounts and posts, but an account result has no follow
// control (it is one anchor to /accounts/{id}), and that route asks
// /public-api/account/{host}/{id}, which the lab's http origin rejects with
// HTTP 400 by design (integration/README.md). So neither "follow from the
// result" nor "see the follow on the profile page" exists in the UI yet; the
// follow edge itself is covered through the API in profile.spec.mjs.
test.fixme(
  'follow from a search result and see it on the profile page: no follow control, profile answers HTTP 400',
  async ({ page }) => {
    await page.goto('/search');
  },
);
