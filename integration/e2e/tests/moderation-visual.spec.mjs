// Visual: the moderation accounts list — blocked at this build, not skipped by
// choice. The screenshot needs a rendered list, and the list only appears when
// /api/v1/meta names the moderation capability; it names feed_accounts, events
// and sync_token instead, so every /moderation/{section} route shows the gate
// ("... does not name the moderation capability"). The functional spec asserts
// that gate. This becomes a real baseline once the capability exists.

import { test } from '@playwright/test';

test.fixme(
  'moderation accounts list: /api/v1/meta does not advertise the moderation capability, so no list renders',
  async ({ page }) => {
    await page.goto('/moderation/accounts');
  },
);
