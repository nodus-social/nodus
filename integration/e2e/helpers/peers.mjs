// The federation proofs assert on a status the Mastodon peer delivered, so they
// need the peer stack. A run that starts only the origin — `up.sh` + `seed.sh`,
// which is CI's default push/PR path — stores no remote account, and these
// specs decline themselves instead of failing. The probe is the origin's own
// store rather than an environment variable, so starting the peers un-skips the
// next run without anyone remembering to flip a flag.

import { test } from '@playwright/test';

import { findStoredAccount } from './api.mjs';

// The acct the origin stores for the Mastodon peer.
export const PEER_ACCT = 'alice@mastodon.test';

const PEER_SKIP_REASON =
  'the federation proofs need the peer instances, which this run does not start (integration/scripts/peers.sh up)';

/// The origin's record for the peer, or a skip naming the stack this run does
/// not start. Call after signing in: the lookup is made with a session token.
export async function requirePeerAccount(request, session) {
  const peer = await findStoredAccount(request, session, PEER_ACCT);
  test.skip(peer === null, PEER_SKIP_REASON);
  return peer;
}
