// Visual: the home timeline with the seeded follow graph, and nothing else.
//
// The shot covers the seeded cards, not the page: admin follows ada, so every
// status ada posts lands in this timeline — the specs' own probe statuses, and
// the two `peers.sh follow` writes here to prove delivery. A full-page baseline
// of a live timeline is therefore state-dependent by construction: the page
// measured 1860px tall on a freshly seeded origin and 2603px after a few follow
// runs. The seeded cards are the only row set that seed.sh guarantees, so the
// list is narrowed to them and the snapshot is named for what it shows.
//
// Admin signs in rather than ada: `peers.sh follow` makes ada follow the
// Mastodon and Misskey accounts, so a peer-authored post would add a row to
// ada's timeline whenever the peers are up, and CI runs this suite with the
// peers down. Admin follows only local accounts, so no peer post reaches it.
//
// Relative timestamps are the one part of the screen that changes without the
// code changing, so the age is hidden rather than masked: the mask Playwright
// paints for `header a[href*="/status/"]` lands one line above the glyphs (the
// anchor's box and the drawn text disagree by 16px), which left "52m" visible
// beside a magenta box and made this baseline fail four minutes later on the
// same page. `visibility: hidden` keeps the reserved 4ch box and removes the
// digits; everything else is expected to be pixel-stable.

import { expect, test } from '@playwright/test';

import { ACCOUNTS, POSTS } from '../fixtures.mjs';
import { signIn } from '../helpers/session.mjs';
import { prepareVisualPage, volatileMasks } from '../helpers/visual.mjs';

const SEEDED_CARDS = [
  POSTS.graceSecond,
  POSTS.graceFirst,
  POSTS.adaSecond,
  POSTS.adaFirst,
  POSTS.adminFirst,
];

test('home timeline', async ({ page }) => {
  await signIn(page, ACCOUNTS.admin);
  await expect(page.getByText(POSTS.graceFirst)).toBeVisible();

  // Every seeded card must be on the loaded page before the list is narrowed: a
  // card missing from the page would silently shrink the picture instead of
  // failing, and the baseline would then agree with a shorter timeline.
  for (const text of SEEDED_CARDS) {
    const card = page.locator('li.card').filter({ hasText: text }).first();
    await expect(card, `the seeded card "${text}" is on the first page`).toBeVisible();
    await card.evaluate((element) => element.setAttribute('data-seeded', ''));
  }
  await page.addStyleTag({
    content: 'li.card:not([data-seeded]) { display: none; }',
  });

  const list = page.locator('main ul:has(> li.card)').first();
  await expect(list).toBeVisible();
  await prepareVisualPage(page, list);
  await list.evaluate((element) => {
    for (const age of element.querySelectorAll('header > a:last-child')) {
      age.style.visibility = 'hidden';
    }
  });

  await expect(list).toHaveScreenshot('home-timeline-seeded.png', {
    mask: volatileMasks(page),
  });
});
