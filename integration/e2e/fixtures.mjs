// Values the specs and the seed script agree on. seed.sh is the only writer:
// the accounts below are registered over /auth/register and the post texts are
// inserted through POST /api/v1/statuses, so the specs assert data that came
// through the real API rather than through a fixture written to the database.
//
// If you change a credential or a post here, change it in
// integration/scripts/seed.sh too and rerun the seed.

// Host origin of the lab. Defaults to the documented port; LAB_BASE_URL is the
// same override playwright.config.mjs honours.
export const BASE_URL = process.env.LAB_BASE_URL ?? 'http://127.0.0.1:8080';

// What the browser types into the Instance field. The scheme is left out
// because the client adds http for loopback addresses; 127.0.0.1 is loopback,
// so this instance is allowed to speak plain HTTP. The host:port comes from
// BASE_URL so a lab on another port still signs in.
export const INSTANCE_HOST = new URL(BASE_URL).host;

export const ACCOUNTS = {
  ada: {
    username: 'ada',
    email: 'ada@nodus.test',
    password: 'lab-password-ada',
  },
  grace: {
    username: 'grace',
    email: 'grace@nodus.test',
    password: 'lab-password-grace',
  },
  admin: {
    username: 'admin',
    email: 'admin@nodus.test',
    password: 'nodus-lab-admin',
  },
};

// Exact strings from seed.sh. The home timeline spec asserts Grace's text on
// Ada's home, which only appears if the follow and the fan-out both worked.
export const POSTS = {
  adaFirst: "Hello from Ada. This post comes from the integration lab.",
  adaSecond: "Ada's second note: the home timeline should show both accounts.",
  graceFirst: 'Grace was here. This is real data served by the lab API.',
  graceSecond: "Grace's follow-up: profiles and timelines have something to render.",
  adminFirst: 'Admin check-in: bootstrap login works over plain HTTP.',
};

// The account whose profile the spec opens. The route is the bare handle: the
// client resolves it against the signed-in instance, which keeps the test
// independent of the numeric id Postgres assigned at seed time.
export const PROFILE_HANDLE = ACCOUNTS.grace.username;
export const PROFILE_POST = POSTS.graceFirst;
