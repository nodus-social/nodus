// Functional: what the moderation area actually serves at this build.
//
// The web source knows these sections — Reports, Appeals, Scans, Media,
// Accounts, Registrations, Federation and Rules — and the account profile
// editor lives under Accounts. The capability is not what is missing: the lab
// publishes 42 features at /api/v1/meta, `admin` and `moderation` among them
// (checked against the live answer). What a bare session lacks is a role, and
// the rail's staff door is `staff_door(extensions, served, role)` — three
// facts, all three required. The grant that supplies the third is walked in
// capabilities-visual.spec.mjs (`/admin/overview` → Grant admin access →
// Allow) before that spec can picture either door.
//
// The two `test.fixme`s below are placeholders, not blocked tests: each body
// only opens a route and asserts nothing, so un-fixmeing them passes without
// proving anything. They stay fixmes until the assertions are written.

import { expect, test } from '@playwright/test';

import { ACCOUNTS } from '../fixtures.mjs';
import { navigate } from '../helpers/navigation.mjs';
import { signIn } from '../helpers/session.mjs';

// FIXME(product): no Moderation link renders in the rail for this session, and
// the reason is the role, not the capability: /api/v1/meta advertises
// `moderation`, but `staff_door` also needs a staff role, and this test never
// walks the admin grant. The three assertions that follow are stale with it —
// no route says "does not name the moderation capability" any more — so the
// body needs a rewrite, not just a grant.
test.fixme('the staff area is gated by the missing moderation capability', async ({
  page,
}) => {
  await signIn(page, ACCOUNTS.admin);

  // The staff sidebar offers Moderation but no Administration link.
  await expect(
    page.getByRole('link', { name: 'Moderation', exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole('link', { name: 'Administration', exact: true }),
  ).toHaveCount(0);

  for (const section of [
    '/moderation',
    '/moderation/accounts',
    '/moderation/reports',
  ]) {
    await navigate(page, section);
    await expect(
      page.getByText(/does not name the moderation capability/),
      `${section} shows the capability gate`,
    ).toBeVisible();
    // No accounts table, no section navigation and no per-account editor.
    await expect(page.locator('main table')).toHaveCount(0);
    await expect(
      page.getByRole('heading', { name: 'Accounts', exact: true }),
    ).toHaveCount(0);
  }
});

test.fixme('moderation accounts list and account profile editor: no assertions written yet', async ({
  page,
}) => {
  await page.goto('/moderation/accounts');
});
