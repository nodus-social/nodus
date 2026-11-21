// Visual: the home composer holding text and a real attachment. The fixture is
// the same committed PNG the drive spec uploads, so the thumbnail pixels are
// identical on every run; the media id in its URL is not painted.

import { fileURLToPath } from 'node:url';

import { expect, test } from '@playwright/test';

import { ACCOUNTS } from '../fixtures.mjs';
import { clearDrive } from '../helpers/api.mjs';
import { signIn } from '../helpers/session.mjs';
import { prepareVisualPage } from '../helpers/visual.mjs';

const FIXTURE = fileURLToPath(new URL('../fixtures/status-image.png', import.meta.url));

test('composer with text and an attachment', async ({ page }) => {
  const session = await signIn(page, ACCOUNTS.ada);
  await clearDrive(page.request, session);

  const composer = page
    .locator('main .card')
    .filter({ has: page.locator('.ProseMirror') })
    .first();
  await composer.locator('.ProseMirror').click();
  await page.keyboard.type('Shipping this with a screenshot.');

  const chooser = page.waitForEvent('filechooser');
  await composer.getByRole('button', { name: 'Add images, video or audio' }).click();
  await (await chooser).setFiles(FIXTURE);
  await expect(composer.locator('img').first()).toBeVisible();

  await prepareVisualPage(page, composer);
  await expect(composer).toHaveScreenshot('composer.png');

  await clearDrive(page.request, session);
});
