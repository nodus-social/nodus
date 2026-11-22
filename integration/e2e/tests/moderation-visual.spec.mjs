// Visual: the moderation accounts list — no baseline yet, and not because the
// capability is missing. /api/v1/meta advertises `moderation` (42 features at
// this build); a list needs a session that holds a staff role, and this body
// only opens the route. It also asserts nothing, so un-fixmeing it would go
// green without a picture, which is worse than a named fixme.
//
// A real baseline needs the admin grant walked first (as
// capabilities-visual.spec.mjs does) and a moderation list that renders under
// it.

import { test } from '@playwright/test';

test.fixme('moderation accounts list: no baseline yet, and no assertions in this body', async ({
  page,
}) => {
  await page.goto('/moderation/accounts');
});
