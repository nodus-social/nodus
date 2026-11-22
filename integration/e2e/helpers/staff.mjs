// The staff rail's two observable facts: how many staff cards it holds, and
// whether the administrator's consent screen has been walked. Both are shared
// by the capability pictures and the eligibility specs, because a card that is
// still being probed is not the same thing as a card the answer removed.

import { expect } from '@playwright/test';

import { navigate } from './navigation.mjs';

export const RAIL = 'aside[data-rail="left"]';

async function quietTree(scope) {
  await scope.evaluate(
    (element) =>
      new Promise((done) => {
        let timer = setTimeout(done, 800);
        const observer = new MutationObserver(() => {
          clearTimeout(timer);
          timer = setTimeout(() => {
            observer.disconnect();
            done();
          }, 800);
        });
        observer.observe(element, {
          childList: true,
          subtree: true,
          characterData: true,
          attributes: true,
        });
      }),
  );
}

/// The rail's staff card is drawn and torn down while the role probe settles,
/// so a card seen in one frame is not yet a card: wait until the tree has held
/// still and the card count is still `doors`.
export async function staffCardSettled(page, doors, timeout = 8_000) {
  const staffCards = page.locator(`${RAIL} [data-nav-rail-doors]`);
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if ((await staffCards.count()) !== doors) {
      await page.waitForTimeout(250);
      continue;
    }
    await quietTree(page.locator(RAIL));
    if ((await staffCards.count()) === doors) return true;
  }
  return false;
}

/// Walks the instance's own consent screen for the wider administration token,
/// so a spec that needs the panels holds the same grant an operator holds.
export async function grantAdmin(page) {
  await navigate(page, '/admin/overview');
  const grant = page.getByRole('button', { name: 'Grant admin access' });
  await expect(grant, 'the administration gate offers the grant').toBeVisible();
  await grant.click();
  await page.waitForURL(/\/oauth\/authorize/, { timeout: 30_000 });
  await page.getByRole('button', { name: 'Allow' }).click();
  await page.waitForURL(/\/admin\//, { timeout: 30_000 });
  // A probe that started before the grant can answer after it and re-cache
  // "no role", so a client-side navigation may carry the pre-grant verdict.
  // Reloading starts a shell whose first ask already sees the grant.
  await page.reload();
  for (let attempt = 1; attempt <= 2; attempt += 1) {
    await navigate(page, '/home');
    if (await staffCardSettled(page, 1)) return;
  }
  await expect(
    page.getByRole('link', { name: 'Administration', exact: true }),
    'the grant opens the administration door in the rail',
  ).toBeVisible({ timeout: 20_000 });
}
