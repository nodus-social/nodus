// Shared preparation for screenshot specs. Stability is the whole job here:
// the same DOM must produce the same pixels on a rerun and after a reset.

import { expect } from '@playwright/test';

/// Waits until the page can be screenshotted deterministically: the reduced
/// motion branch is active (playwright.config.mjs sets reducedMotion: 'reduce'),
/// webfonts have resolved, and every image in `scope` has decoded. A screenshot
/// taken before an avatar decodes captures a blank box on one run and the image
/// on the next.
export async function prepareVisualPage(page, scope) {
  await expect
    .poll(
      () =>
        page.evaluate(
          () => window.matchMedia('(prefers-reduced-motion: reduce)').matches,
        ),
      { message: 'the browser reports prefers-reduced-motion: reduce', timeout: 15_000 },
    )
    .toBe(true);
  await page.evaluate(() => document.fonts.ready);
  // Relative ages sit at the end of the card header. Their text width changes
  // when a status crosses 9m→10m, which resizes the mask box and moves pixels
  // even though the timestamp is masked; a fixed box keeps that edge still.
  await page.addStyleTag({
    content: 'header a[href*="/status/"] { display: inline-block; width: 4ch; text-align: right; }',
  });
  // Playwright clips an element screenshot to the layout box rounded to device
  // pixels at both edges, so a fractional box is captured one row taller from
  // one page position than from the next: a card lays out 177.75px tall, and the
  // same card measured 179px tall when the timeline above it held four rows and
  // 178px when a peer post made that five. Snap every card to a whole-pixel
  // height first, so the fractional part stops accumulating down the feed and
  // each card lands on an integer page offset no matter how many rows sit above
  // it; a card gains or loses a quarter pixel at its bottom edge, which does not
  // move its content. Then put the scope on a whole-pixel scroll offset so where
  // the page happens to be scrolled cannot reach the pixels either.
  await page.evaluate(() => {
    for (const card of document.querySelectorAll('li.card')) {
      const { height } = card.getBoundingClientRect();
      if (height > 0) card.style.height = `${Math.round(height)}px`;
    }
  });
  await scope.evaluate((element) => {
    const top = element.getBoundingClientRect().top + window.scrollY;
    window.scrollTo(0, Math.round(top));
  });
  await expect
    .poll(() => page.evaluate(() => window.scrollY === Math.round(window.scrollY)), {
      message: 'the page sits on a whole-pixel scroll offset',
      timeout: 5_000,
    })
    .toBe(true);
  // Snapping the cards does not help if the list itself starts on a fraction —
  // the scope's own edges are what the clip box rounds — so give the scope back
  // the fraction it inherited from whatever sits above it.
  await scope.evaluate((element) => {
    const { top } = element.getBoundingClientRect();
    const margin = Number.parseFloat(getComputedStyle(element).marginTop) || 0;
    element.style.marginTop = `${margin - (top - Math.round(top))}px`;
  });
  await expect
    .poll(
      () =>
        scope
          .locator('img')
          .evaluateAll((images) => images.every((img) => img.complete && img.naturalWidth > 0)),
      { message: 'every image in the screenshot scope has decoded', timeout: 15_000 },
    )
    .toBe(true);
}

/// Nodes whose pixels are time-dependent, not code-dependent. Relative ages
/// ("26m", "now") and the unread badge count change without a deploy, so mask
/// them rather than hiding them in CSS. Masks are painted in the baseline too,
/// so a layout shift around a masked node is still visible.
///
/// The notifications *link* is what gets masked, not the badge inside it. The
/// badge only exists while the count is non-zero, and that count is a record of
/// what other specs did (the favourite and reply notifications.spec.mjs creates),
/// not a property of the page in the screenshot. A mask on the badge agrees only
/// with the state that happened to be current when the baseline was captured;
/// the link's box is the same with or without it.
///
/// A navigator picture that claims the bell must not mask the link itself: the
/// mask would hide whether the door exists. `notificationDoor: 'badge'` masks
/// only the count, so the bell row is part of the picture while the count stays
/// volatile.
export function volatileMasks(page, { notificationDoor = 'link' } = {}) {
  return [
    page.locator('time'),
    page.locator('[datetime]'),
    page.locator('header a[href*="/status/"]'),
    notificationDoor === 'badge'
      ? page.locator('[data-notice-count]')
      : page.locator('a[href="/notifications"]'),
  ];
}
