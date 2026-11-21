#!/bin/sh
# The peers publish `https://<their domain>/...` and Caddy answers those names with a
# certificate from its internal CA, so the origin has to trust that CA to fetch a key
# document or an actor from either one. reqwest is built with the platform verifier
# (Cargo.toml, `features = ["rustls", "webpki-roots"]`), which on Linux is
# rustls-native-certs: it reads SSL_CERT_FILE and uses that file as the whole root store.
# Naming the lab root alone would therefore drop every public root, so the image's bundle
# is copied and the lab root appended to the copy, exactly as the Mastodon wrapper does.
#
# The copy lives in /tmp because /etc/ssl/certs/ca-certificates.crt is root-owned while the
# service runs as uid 10001. SSL_CERT_FILE itself is declared in compose.yml, because
# `docker exec` inherits the container's configured environment, not this shell's exports.
set -eu
cat /etc/ssl/certs/ca-certificates.crt /certs/nodus-lab-ca.crt >/tmp/nodus-lab-ca-bundle.crt
exec "$@"
