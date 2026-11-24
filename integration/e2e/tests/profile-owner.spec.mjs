// The owner's own profile, reached both ways, keeps the customization controls
// and offers no relationship verb against itself.
//
// Both halves failed once and neither had a spec: the handle address matched the
// visitor's page (a local account's `acct` is bare, so `@admin@nodus.test` never
// matched) and the owner was offered Follow/Mute/Block against themselves.
//
// The instance answers a local account with the bare `acct` (`admin`), so a
// lookup for `@admin@nodus.test` used to fail to match and the reader fell
// through to the visitor's page, which draws neither an editor nor a verb.
import { expect, test } from '@playwright/test';

import { ACCOUNTS } from '../fixtures.mjs';
import { readSession, signIn } from '../helpers/session.mjs';

const VERBS = ['Follow', 'Mute', 'Block'];

test('the owner reaches their own profile by handle and by id, with no verbs', async ({
  page,
}) => {
  await signIn(page, ACCOUNTS.admin);

  const session = await readSession(page);
  expect(session?.acct, 'the sign-in left an acct in the session').toBeTruthy();
  expect(session?.accountId, 'the sign-in left an account id in the session').toBeTruthy();
  const { acct, accountId } = session;

  for (const path of [`/@${acct}@nodus.test`, `/accounts/${accountId}`]) {
    await page.goto(path);

    // The editor is the proof that this is the owner's screen and not the
    // visitor's page: only the owner's profile receives one.
    const controls = page.getByLabel('Profile pictures and banners');
    await expect(controls, `the owner's editor at ${path}`).toBeVisible({
      timeout: 30_000,
    });

    // Nobody follows, mutes or blocks themselves.
    for (const verb of VERBS) {
      await expect(
        page.getByRole('button', { name: verb, exact: true }),
        `${verb} offered against the owner's own account at ${path}`,
      ).toHaveCount(0);
    }
  }
});
