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
  // pixels, so an element whose top lands on a half pixel is captured one pixel
  // taller from one page position than from the next: the same card measured
  // 179px tall when the timeline above it held four rows and 178px when a peer
  // post made that five. Put the scope on a whole-pixel scroll offset so where
  // the page happens to be scrolled cannot reach the pixels.
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
export function volatileMasks(page) {
  return [
    page.locator('time'),
    page.locator('[datetime]'),
    page.locator('header a[href*="/status/"]'),
    page.locator('a[href="/notifications"]'),
  ];
}
