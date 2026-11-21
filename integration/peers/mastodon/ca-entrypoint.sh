#!/bin/sh
# The lab origin signs its https certificate with Caddy's internal CA, and Ruby trusts
# only what the file named by SSL_CERT_FILE contains. Naming the lab root alone would
# replace the system bundle, so the bundle is copied and the root appended to the copy.
#
# The copy lives in the tmpdir because /etc/ssl/certs/ca-certificates.crt is root-owned
# while the app runs as `mastodon` (uid 991); SSL_CERT_FILE itself is set in
# compose.peers.yml, because `docker exec` inherits the container's configured
# environment, not this shell's exports.
set -eu
cat /etc/ssl/certs/ca-certificates.crt /certs/nodus-lab-ca.crt > /tmp/nodus-lab-ca-bundle.crt
exec "$@"
