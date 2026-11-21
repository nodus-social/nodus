#!/bin/bash
# Runs the optional federation peers (real Mastodon and real Misskey) next to
# the core lab and exercises federation against them.
#
#   peers.sh up      start the peer stack (core lab must be up, or is started)
#   peers.sh down    stop and remove the peer containers, keep peer data
#   peers.sh status  container state, endpoint probes, seeded account files
#   peers.sh seed    create the peer accounts and write their tokens
#   peers.sh follow  attempt the three federation directions and report
#
# `up` does not seed: a fresh stack has no accounts and no tokens until `seed`
# runs. `down` keeps the named volumes so a seeded Misskey token survives;
# reset.sh and down.sh remove them when the whole lab is reset.
set -euo pipefail

SCRIPT_DIR=$(
    unset CDPATH
    cd -- "$(dirname -- "$0")" && pwd
)
. "$SCRIPT_DIR/common.sh"

PEERS_FILE="$INTEGRATION_DIR/compose.peers.yml"
STATE_DIR="$INTEGRATION_DIR/state"
MISSKEY_URL="http://127.0.0.1:18082"
MASTODON_URL="http://127.0.0.1:18081"
NODUS_URL="http://127.0.0.1:$(http_port)"
MISSKEY_SETUP_PASSWORD=misskey-lab-setup
MISSKEY_ADMIN=admin
MISSKEY_ADMIN_PASSWORD=lab-password-admin
MASTODON_ACCOUNT=alice
MISSKEY_ACCOUNT=alice

peer_compose() {
    docker compose --project-name "$PROJECT" \
        --env-file "$INTEGRATION_DIR/.env" \
        --file "$COMPOSE_FILE" \
        --file "$PEERS_FILE" "$@"
}

die() {
    printf 'peers: %s\n' "$*" >&2
    exit 1
}

usage() {
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
}

ensure_peer_env() {
    ensure_env
    fill_secret MASTODON_DB_PASSWORD generate_hex
    fill_secret MISSKEY_DB_PASSWORD generate_hex
    fill_secret MASTODON_ACTIVE_RECORD_PRIMARY_KEY generate_base64
    fill_secret MASTODON_ACTIVE_RECORD_DETERMINISTIC_KEY generate_base64
    fill_secret MASTODON_ACTIVE_RECORD_KEY_DERIVATION_SALT generate_base64
    # Values with a documented default; fill_secret would regenerate them, so
    # append them only when an older .env predates the peer section.
    for pair in \
        "MASTODON_ACCOUNT_PASSWORD=lab-password-alice" \
        "MISSKEY_ACCOUNT_PASSWORD=lab-password-alice"; do
        key=${pair%%=*}
        if [ -z "$(env_value "$key")" ]; then
            printf '%s\n' "$pair" >>"$INTEGRATION_DIR/.env"
        fi
    done
}

mastodon_password() {
    env_value MASTODON_ACCOUNT_PASSWORD
}

misskey_password() {
    env_value MISSKEY_ACCOUNT_PASSWORD
}

require_peers_up() {
    if ! curl -fsS -o /dev/null "$MASTODON_URL/health" 2>/dev/null; then
        die "Mastodon is not answering on $MASTODON_URL; run peers.sh up"
    fi
    if ! curl -fsS -o /dev/null "$MISSKEY_URL/healthz" 2>/dev/null; then
        die "Misskey is not answering on $MISSKEY_URL; run peers.sh up"
    fi
}

# --- small HTTP helpers -----------------------------------------------------
#
# Every call prints the body and then an `HTTP <code>` line so a failing check
# can be pasted into a report without re-running it.

http_json() { # method url token json
    local method=$1 url=$2 token=$3 body=$4
    if [ -n "$body" ]; then
        curl -sS -X "$method" "$url" \
            ${token:+-H "Authorization: Bearer $token"} \
            -H 'content-type: application/json' \
            --data "$body" -w '\nHTTP %{http_code}\n'
    else
        curl -sS -X "$method" "$url" \
            ${token:+-H "Authorization: Bearer $token"} \
            -w '\nHTTP %{http_code}\n'
    fi
}

json_body() { # strips the trailing HTTP line
    sed '$d'
}

json_code() {
    sed -n '$s/^HTTP //p'
}

nodus_api() { # method path token [json]
    http_json "$1" "$NODUS_URL$2" "$3" "${4:-}"
}

mastodon_api() { # method path token [json]
    http_json "$1" "$MASTODON_URL$2" "$3" "${4:-}"
}

misskey_api() { # path token [json]
    http_json POST "$MISSKEY_URL/api/$1" "$2" "${3:-{\}}"
}

# --- lab OAuth --------------------------------------------------------------
#
# The same PKCE exchange seed.sh performs. It lives here because seeded peer
# checks need a Nodus token and seed.sh does not persist one.

nodus_login_token() { # email password
    local email=$1 password=$2 work jar page csrf code verifier challenge
    work=$(mktemp -d)
    jar="$work/jar"
    page="$work/login.html"
    trap 'rm -rf "$work"' RETURN

    local app client_id client_secret redirect
    app=$(curl -fsS -X POST "$NODUS_URL/api/v1/apps" \
        -H 'content-type: application/json' \
        -d "{\"client_name\":\"nodus-lab peers\",\"redirect_uris\":\"$NODUS_URL/oauth/callback\",\"scopes\":\"read write follow\"}")
    client_id=$(printf '%s' "$app" | jq -r .client_id)
    client_secret=$(printf '%s' "$app" | jq -r .client_secret)
    redirect="$NODUS_URL/oauth/callback"

    curl -fsS -c "$jar" "$NODUS_URL/auth/login" -o "$page"
    csrf=$(sed -n 's/.*name="csrf_token" value="\([^"]*\)".*/\1/p' "$page" | head -n 1)
    [ -n "$csrf" ] || return 1
    code=$(curl -sS -o /dev/null -w '%{http_code}' -b "$jar" -c "$jar" \
        --data-urlencode "email=$email" \
        --data-urlencode "password=$password" \
        --data-urlencode "return_to=/" \
        --data-urlencode "csrf_token=$csrf" \
        "$NODUS_URL/auth/login")
    [ "$code" = 303 ] || return 1

    verifier=$(openssl rand -hex 32)
    challenge=$(printf '%s' "$verifier" |
        openssl dgst -sha256 -binary |
        openssl base64 -A |
        tr '+/' '-_' | tr -d '=')
    local headers="$work/headers" consent="$work/consent.html" location auth_code
    code=$(curl -sS -o "$consent" -D "$headers" -w '%{http_code}' \
        -b "$jar" -c "$jar" -G "$NODUS_URL/oauth/authorize" \
        --data-urlencode "response_type=code" \
        --data-urlencode "client_id=$client_id" \
        --data-urlencode "redirect_uri=$redirect" \
        --data-urlencode "scope=read write follow" \
        --data-urlencode "state=peers" \
        --data-urlencode "code_challenge=$challenge" \
        --data-urlencode "code_challenge_method=S256")
    [ "$code" = 200 ] || return 1
    csrf=$(sed -n 's/.*name="csrf_token" value="\([^"]*\)".*/\1/p' "$consent" | head -n 1)
    code=$(curl -sS -o /dev/null -D "$headers" -w '%{http_code}' \
        -b "$jar" -c "$jar" -X POST "$NODUS_URL/oauth/authorize" \
        --data-urlencode "client_id=$client_id" \
        --data-urlencode "redirect_uri=$redirect" \
        --data-urlencode "scopes=read write follow" \
        --data-urlencode "state=peers" \
        --data-urlencode "code_challenge=$challenge" \
        --data-urlencode "csrf_token=$csrf" \
        --data-urlencode "decision=allow")
    [ "$code" = 303 ] || return 1
    location=$(sed -n 's/^[Ll]ocation: //p' "$headers" | tr -d '\r' | tail -n 1)
    auth_code=$(printf '%s' "$location" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')
    curl -fsS -X POST "$NODUS_URL/oauth/token" \
        --data-urlencode "grant_type=authorization_code" \
        --data-urlencode "code=$auth_code" \
        --data-urlencode "client_id=$client_id" \
        --data-urlencode "client_secret=$client_secret" \
        --data-urlencode "redirect_uri=$redirect" \
        --data-urlencode "code_verifier=$verifier" |
        jq -r .access_token
}

# --- Mastodon ---------------------------------------------------------------

mastodon_account_exists() {
    peer_compose exec -T mastodon \
        bundle exec rails runner \
        "exit(Account.local.where(username: '$MASTODON_ACCOUNT').exists? ? 0 : 1)" \
        >/dev/null 2>&1
}

mastodon_token() { # -> token on stdout, diagnostics on stderr
    # Mastodon 4.6 removed the OAuth password grant: its Doorkeeper initializer
    # now allows only `authorization_code client_credentials`
    # (config/initializers/doorkeeper.rb), and a password request answers
    # `unsupported_grant_type` (HTTP 400). There is no headless browser in this
    # lab, so the token is issued the way Mastodon's own tests do: an
    # application plus an access token for alice, created through the model.
    peer_compose exec -T mastodon bundle exec rails runner "
        app = Doorkeeper::Application.find_or_create_by!(name: 'nodus-lab-peers') do |a|
          a.redirect_uri = 'urn:ietf:wg:oauth:2.0:oob'
          a.scopes = 'read write follow'
        end
        user = Account.find_local('$MASTODON_ACCOUNT').user
        token = Doorkeeper::AccessToken.create!(
          application: app, resource_owner_id: user.id,
          scopes: 'read write follow', expires_in: nil
        )
        puts token.token
    " 2>/dev/null | tail -n 1
}

seed_mastodon() {
    printf '==> Mastodon: %s@mastodon.test\n' "$MASTODON_ACCOUNT"
    if mastodon_account_exists; then
        printf '  account already exists\n'
    else
        peer_compose exec -T mastodon bundle exec bin/tootctl accounts create \
            "$MASTODON_ACCOUNT" \
            --email "$MASTODON_ACCOUNT@mastodon.test" \
            --confirmed \
            --approve
    fi
    # `tootctl accounts modify` accepts only USERNAME plus role/confirm flags;
    # there is no --password. Set the password through the model so the value
    # stored in .env is the one the UI login uses. The password is no longer an
    # OAuth credential in 4.6 (the grant is gone, see mastodon_token).
    peer_compose exec -T mastodon bundle exec rails runner \
        "Account.find_local('$MASTODON_ACCOUNT').user.update!(password: '$(mastodon_password)', approved: true)" \
        >/dev/null

    local token
    token=$(mastodon_token)
    if [ -z "$token" ]; then
        die "could not mint a Mastodon token for $MASTODON_ACCOUNT"
    fi
    install -d -m 700 "$STATE_DIR"
    jq -n --arg host "$MASTODON_URL" \
        --arg username "$MASTODON_ACCOUNT" \
        --arg password "$(mastodon_password)" \
        --arg token "$token" \
        --arg acct "$MASTODON_ACCOUNT@mastodon.test" \
        '{host: $host, username: $username, password: $password,
          token: $token, acct: $acct}' >"$STATE_DIR/mastodon-account.json"
    chmod 600 "$STATE_DIR/mastodon-account.json"
    printf '  token written to %s\n' "$STATE_DIR/mastodon-account.json"
}

# --- Misskey ----------------------------------------------------------------

misskey_state_get() { # jq path
    [ -f "$STATE_DIR/misskey-account.json" ] || return 1
    jq -r "$1" "$STATE_DIR/misskey-account.json" 2>/dev/null
}

misskey_token_valid() { # token
    [ -n "$1" ] || return 1
    local body
    body=$(misskey_api i "$1")
    printf '%s' "$body" | json_body | jq -e '.id' >/dev/null 2>&1
}

misskey_admin_token() {
    local state_token token response
    state_token=$(misskey_state_get .adminToken || true)
    if misskey_token_valid "$state_token"; then
        printf '%s\n' "$state_token"
        return 0
    fi
    response=$(misskey_api admin/accounts/create "" \
        "$(jq -nc --arg u "$MISSKEY_ADMIN" \
            --arg p "$MISSKEY_ADMIN_PASSWORD" \
            --arg s "$MISSKEY_SETUP_PASSWORD" \
            '{username: $u, password: $p, setupPassword: $s}')")
    token=$(printf '%s' "$response" | json_body | jq -r '.token // empty')
    if [ -z "$token" ]; then
        return 1
    fi
    printf '%s\n' "$token"
}

seed_misskey() {
    printf '==> Misskey: %s@misskey.test\n' "$MISSKEY_ACCOUNT"
    install -d -m 700 "$STATE_DIR"

    local admin_token response token user_id existing
    admin_token=$(misskey_admin_token) || {
        printf '%s\n' "  the root account already exists and no working admin token is stored."
        printf '%s\n' "  Run peers.sh down && peers.sh up && peers.sh seed to rebuild."
        return 1
    }

    # Misskey 2026.11 creates a new instance with `federation: none`; 2024.11
    # defaulted to `all`. Left closed, ap/show answers FEDERATION_NOT_ALLOWED
    # and nothing from nodus.test resolves, so the lab opens it here. The
    # setting lives in the `meta` row, not in default.yml, hence the API call.
    response=$(misskey_api admin/meta "$admin_token" '{}')
    if [ "$(printf '%s' "$response" | json_body | jq -r '.federation')" != all ]; then
        misskey_api admin/update-meta "$admin_token" '{"federation":"all"}' >/dev/null
        printf '  federation opened (2026.11 defaults new instances to none)\n'
    fi

    existing=$(misskey_api users/show "" \
        "$(jq -nc --arg u "$MISSKEY_ACCOUNT" '{username: $u}')")
    user_id=$(printf '%s' "$existing" | json_body | jq -r '.id // empty')
    if [ -n "$user_id" ] && misskey_token_valid "$(misskey_state_get .token || true)"; then
        token=$(misskey_state_get .token)
        printf '  account already exists, stored token still valid\n'
    else
        if [ -n "$user_id" ]; then
            printf '  stored token is unusable; recreating %s\n' "$MISSKEY_ACCOUNT"
            misskey_api admin/accounts/delete "$admin_token" \
                "$(jq -nc --arg id "$user_id" '{userId: $id}')" >/dev/null
        fi
        response=$(misskey_api admin/accounts/create "$admin_token" \
            "$(jq -nc --arg u "$MISSKEY_ACCOUNT" \
                --arg p "$(misskey_password)" \
                '{username: $u, password: $p}')")
        token=$(printf '%s' "$response" | json_body | jq -r '.token // empty')
        if [ -z "$token" ]; then
            printf '%s\n' "$response" >&2
            die "Misskey refused to create $MISSKEY_ACCOUNT"
        fi
        printf '  created account and token\n'
    fi

    jq -n --arg host "$MISSKEY_URL" \
        --arg username "$MISSKEY_ACCOUNT" \
        --arg password "$(misskey_password)" \
        --arg token "$token" \
        --arg acct "$MISSKEY_ACCOUNT@misskey.test" \
        --arg adminToken "$admin_token" \
        '{host: $host, username: $username, password: $password,
          token: $token, acct: $acct, adminToken: $adminToken}' \
        >"$STATE_DIR/misskey-account.json"
    chmod 600 "$STATE_DIR/misskey-account.json"
    printf '  token written to %s\n' "$STATE_DIR/misskey-account.json"
}

# --- federation checks ------------------------------------------------------

nodus_token() {
    [ -f "$STATE_DIR/nodus-account.json" ] &&
        jq -r '.token // empty' "$STATE_DIR/nodus-account.json" 2>/dev/null
}

# A token minted before a reset points at a row the dropped database no longer
# has, and every follow check would answer 401. The file cannot be trusted by
# existence alone, so it is verified the same way the API verifies it.
nodus_token_works() {
    local token
    token=$(nodus_token)
    [ -n "$token" ] || return 1
    [ "$(nodus_api GET /api/v1/accounts/verify_credentials "$token" | json_code)" = 200 ]
}

seed_nodus_token() {
    local token
    token=$(nodus_login_token ada@nodus.test lab-password-ada) || {
        printf '  could not log in as ada@nodus.test (has seed.sh run?)\n' >&2
        return 1
    }
    jq -n --arg host "$NODUS_URL" --arg username ada \
        --arg password lab-password-ada --arg token "$token" \
        --arg acct ada@nodus.test \
        '{host: $host, username: $username, password: $password,
          token: $token, acct: $acct}' >"$STATE_DIR/nodus-account.json"
    chmod 600 "$STATE_DIR/nodus-account.json"
}

# Mastodon fans a status out to the followers it already knows about, and ada's
# Follow reaches it through an ingress queue. A status posted straight after the
# follow can be created while ada is still a pending request, is never delivered
# to the origin, and the federation specs then have nothing to render. These two
# polls turn that race into a wait: first for Mastodon to list the follower, then
# for the origin to store the status.
mastodon_follower_count() {
    local token search
    token=$(jq -r .token "$STATE_DIR/mastodon-account.json")
    search=$(mastodon_api GET '/api/v2/search?q=%40ada%40nodus.test&resolve=true&type=accounts' "$token")
    printf '%s\n' "$search" | json_body | jq -r '.accounts[0].followers_count // 0'
}

wait_for_mastodon_follower() {
    local attempt=0
    while [ "$attempt" -lt 30 ]; do
        if [ "$(mastodon_follower_count)" -ge 1 ]; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    printf 'RESULT: Mastodon never listed ada@nodus.test as a follower\n'
    return 1
}

# The origin stores a delivered peer status and serves it from search, but its
# home timeline is built from the local follow graph, which is not the same
# question. Ask for the peer account's own statuses instead.
nodus_has_peer_status() {
    local token account_id
    token=$(nodus_token)
    account_id=$(nodus_api GET "/api/v2/search?q=%40$MASTODON_ACCOUNT%40mastodon.test&resolve=true&type=accounts" "$token" |
        json_body | jq -r '.accounts[0].id // empty')
    [ -n "$account_id" ] || return 1
    nodus_api GET "/api/v1/accounts/$account_id/statuses?limit=40" "$token" | json_body |
        jq -e 'length > 0' >/dev/null
}

wait_for_nodus_ingest() {
    local attempt=0
    while [ "$attempt" -lt 30 ]; do
        if nodus_has_peer_status; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    printf 'RESULT: the origin did not ingest a peer-authored status\n'
    return 1
}

check_nodus_to_mastodon() {
    local token search account_id
    printf '\n=== nodus -> Mastodon: ada follows alice@mastodon.test ===\n'
    token=$(nodus_token)
    if [ -z "$token" ]; then
        printf 'skipped: no Nodus token (run peers.sh seed)\n'
        return 1
    fi

    printf -- '-- resolve by actor URL\n'
    # The canonical actor URL: Mastodon advertises its identity from WEB_DOMAIN,
    # which cannot carry a port, and every ActivityPub id it emits is https. Caddy
    # owns `mastodon.test` on 443 and proxies to the web process, so this is the
    # address the origin really fetches.
    search=$(nodus_api GET "/api/v2/search?q=https%3A%2F%2Fmastodon.test%2Fusers%2F$MASTODON_ACCOUNT&resolve=true" "$token")
    printf '%s\n' "$search"
    account_id=$(printf '%s' "$search" | json_body | jq -r '.accounts[0].id // empty')

    if [ -z "$account_id" ]; then
        printf -- '-- resolve by handle\n'
        search=$(nodus_api GET "/api/v2/search?q=$MASTODON_ACCOUNT%40mastodon.test&resolve=true" "$token")
        printf '%s\n' "$search"
        account_id=$(printf '%s' "$search" | json_body | jq -r '.accounts[0].id // empty')
    fi

    [ -n "$account_id" ] || {
        printf 'RESULT: nodus could not resolve the Mastodon account, so no Follow was sent.\n'
        return 1
    }
    printf -- '-- follow account %s\n' "$account_id"
    nodus_api POST "/api/v1/accounts/$account_id/follow" "$token" '{}'

    printf -- '-- wait for Mastodon to accept the follow\n'
    local failed=0
    wait_for_mastodon_follower || failed=1
    if nodus_has_peer_status; then
        printf -- '-- the origin already holds a peer status, not posting another\n'
    else
        printf -- '-- post from Mastodon\n'
        mastodon_api POST /api/v1/statuses "$(jq -r .token "$STATE_DIR/mastodon-account.json")" \
            '{"status":"hello from mastodon, follows are live","visibility":"public"}' >/dev/null
        printf -- '-- wait for the origin to ingest it\n'
        wait_for_nodus_ingest || failed=1
    fi
    printf -- '-- ada home timeline\n'
    nodus_api GET '/api/v1/timelines/home?limit=10' "$token"
    return "$failed"
}

check_mastodon_to_nodus() {
    local token search account_id
    printf '\n=== Mastodon -> nodus: alice follows ada@nodus.test ===\n'
    [ -f "$STATE_DIR/mastodon-account.json" ] || {
        printf 'skipped: no Mastodon token (run peers.sh seed)\n'
        return 1
    }
    token=$(jq -r .token "$STATE_DIR/mastodon-account.json")

    printf -- '-- resolve by actor URL\n'
    # Mastodon's WebFinger builds `https://<domain>` for every domain that is not
    # `.onion` (`app/lib/webfinger.rb`, `standard_url`), which is what the origin
    # answers on 443. The actor URL goes straight to the resolver and never
    # reaches WebFinger.
    search=$(mastodon_api GET '/api/v2/search?q=https%3A%2F%2Fnodus.test%2Fusers%2Fada&resolve=true&type=accounts' "$token")
    printf '%s\n' "$search"
    account_id=$(printf '%s' "$search" | json_body | jq -r '.accounts[0].id // empty')

    if [ -z "$account_id" ]; then
        printf -- '-- resolve by handle\n'
        search=$(mastodon_api GET '/api/v2/search?q=%40ada%40nodus.test&resolve=true' "$token")
        printf '%s\n' "$search"
        account_id=$(printf '%s' "$search" | json_body | jq -r '.accounts[0].id // empty')
    fi

    [ -n "$account_id" ] || {
        printf 'RESULT: Mastodon could not resolve ada@nodus.test, so no Follow was sent.\n'
        return 1
    }
    printf -- '-- follow account %s\n' "$account_id"
    mastodon_api POST "/api/v1/accounts/$account_id/follow" "$token" '{}'

    printf -- '-- post from nodus\n'
    nodus_api POST /api/v1/statuses "$(nodus_token)" \
        '{"status":"hello from nodus, outbound delivery check"}' >/dev/null
    sleep 3
    printf -- '-- Mastodon home timeline\n'
    mastodon_api GET '/api/v1/timelines/home?limit=10' "$token"
}

check_misskey_to_nodus() {
    printf '\n=== Misskey -> nodus: alice@misskey.test follows ada@nodus.test ===\n'
    if [ ! -f "$STATE_DIR/misskey-account.json" ] || [ -z "$(nodus_token)" ]; then
        printf 'skipped: missing Misskey or Nodus token (run peers.sh seed)\n'
        return 1
    fi
    local token user_id response note_id before after note_status note_address
    token=$(jq -r .token "$STATE_DIR/misskey-account.json")

    # Nodus verifies a signature by fetching the signer through the ActivityPub
    # client, whose resolver refuses private addresses even when
    # NODUS_ALLOW_PRIVATE_HOSTS names them. The origin's own resolve does honour
    # the allowlist, so resolving alice here caches her key and the deliveries
    # below pass signature verification. See docs/peers.md, "(c)".
    printf -- '-- resolve alice@misskey.test through nodus (caches her key)\n'
    nodus_api GET '/api/v2/search?q=%40alice%40misskey.test&resolve=true' \
        "$(nodus_token)" >/dev/null

    printf -- '-- resolve by actor URL via ap/show\n'
    # WebFinger for `nodus.test` builds https://nodus.test, which Caddy answers on 443;
    # ap/show takes the actor URL the origin publishes and skips discovery.
    response=$(misskey_api ap/show "$token" \
        "$(jq -nc '{uri: "https://nodus.test/users/ada"}')")
    printf '%s\n' "$response"
    user_id=$(printf '%s' "$response" | json_body | jq -r '.object.id // empty')

    if [ -z "$user_id" ]; then
        printf -- '-- resolve by handle\n'
        response=$(misskey_api users/show "$token" \
            "$(jq -nc '{username: "ada", host: "nodus.test"}')")
        printf '%s\n' "$response"
        user_id=$(printf '%s' "$response" | json_body | jq -r '.id // empty')
    fi

    [ -n "$user_id" ] || {
        printf 'RESULT: Misskey could not resolve ada@nodus.test, so no Follow was sent.\n'
        return 1
    }
    printf -- '-- follow user %s\n' "$user_id"
    misskey_api following/create "$token" \
        "$(jq -nc --arg id "$user_id" '{userId: $id}')"

    printf -- '-- react to a nodus note\n'
    # The note is dereferenced by its ActivityPub id, which is not the Mastodon-API
    # `uri`: the origin serves `https://nodus.test/@ada/<id>` as HTML even for an
    # ActivityPub Accept header, and only `https://nodus.test/statuses/<id>` is the
    # object `/users/ada/outbox` lists. A fresh note is posted so the check never
    # depends on a home timeline that has nothing in it.
    note_status=$(nodus_api POST '/api/v1/statuses' "$(nodus_token)" \
        '{"status":"hello from nodus, misskey reaction check","visibility":"public"}' |
        json_body)
    note_address=$(printf '%s' "$note_status" | jq -r '.id // empty')
    printf 'nodus note id: %s\n' "$note_address"
    [ -n "$note_address" ] || return 1
    response=$(misskey_api ap/show "$token" \
        "$(jq -nc --arg uri "https://nodus.test/statuses/$note_address" '{uri: $uri}')")
    printf '%s\n' "$response"
    note_id=$(printf '%s' "$response" | json_body | jq -r '.object.id // empty')
    [ -n "$note_id" ] || {
        printf 'RESULT: Misskey could not dereference the nodus note, no reaction sent.\n'
        return 1
    }
    before=$(nodus_api GET "/api/v1/statuses/$note_address/reactions" "$(nodus_token)" | json_body)
    printf -- '-- send reaction\n'
    misskey_api notes/reactions/create "$token" \
        "$(jq -nc --arg id "$note_id" '{noteId: $id, reaction: "👍"}')"
    sleep 5
    after=$(nodus_api GET "/api/v1/statuses/$note_address/reactions" "$(nodus_token)" | json_body)
    printf 'nodus reactions before: %s\n' "$before"
    printf 'nodus reactions after:  %s\n' "$after"
}

check_peer_post_in_web_shell() {
    printf '\n=== peer posts through the lab shell (%s) ===\n' "$NODUS_URL"
    local token account_id
    token=$(nodus_token)
    [ -n "$token" ] || {
        printf 'skipped: no Nodus token (run peers.sh seed)\n'
        return 1
    }
    account_id=$(nodus_api GET /api/v1/accounts/verify_credentials "$token" |
        json_body | jq -r .id)
    printf -- '-- ada public timeline as seen by the shell session\n'
    nodus_api GET "/api/v1/accounts/$account_id/statuses?limit=10" "$token"
}

report_failure_logs() {
    printf '\n=== nodus-api log tail (signature and discovery failures) ===\n'
    compose logs --no-color --tail=25 nodus-api
}

# --- commands ---------------------------------------------------------------

cmd_up() {
    ensure_peer_env
    if ! docker network inspect "$PROJECT" >/dev/null 2>&1; then
        printf 'core lab network %s is missing; starting the core stack\n' "$PROJECT"
        "$SCRIPT_DIR/up.sh" --skip-build
    fi
    # Mastodon and Misskey build their trust bundle at start from the lab CA.
    # Refusing here, rather than letting them verify against a root caddy no
    # longer signs with, turns a BadSignature at delivery time into one message
    # naming the command that fixes it.
    "$SCRIPT_DIR/ca.sh" require
    printf 'starting peers\n'
    peer_compose up -d
    if ! wait_for_url "$MASTODON_URL/health" 300; then
        peer_compose logs --no-color --tail=40 mastodon-setup mastodon
        die 'Mastodon did not become healthy'
    fi
    if ! wait_for_url "$MISSKEY_URL/healthz" 300; then
        peer_compose logs --no-color --tail=40 misskey
        die 'Misskey did not become healthy'
    fi
    printf '\npeers healthy:\n'
    printf '  Mastodon  %s (UI published on 18081)\n' "$MASTODON_URL"
    printf '  Misskey   %s (UI published on 18082)\n' "$MISSKEY_URL"
    printf 'seeded accounts are not created yet: run peers.sh seed\n'
}

cmd_down() {
    ensure_peer_env
    peer_compose rm -sf \
        mastodon mastodon-sidekiq mastodon-setup \
        misskey misskey-files-init \
        mastodon-db mastodon-redis misskey-db misskey-redis >/dev/null 2>&1 || true
    printf 'peer containers removed; named peer volumes kept (reset.sh removes them)\n'
}

cmd_status() {
    ensure_peer_env
    peer_compose ps mastodon mastodon-sidekiq misskey \
        mastodon-db mastodon-redis misskey-db misskey-redis 2>/dev/null || true
    printf '\nendpoints:\n'
    for url in "$MASTODON_URL/health" "$MISSKEY_URL/healthz" \
        "$NODUS_URL/healthz"; do
        code=$(curl -sS -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)
        printf '  %-40s HTTP %s\n' "$url" "${code:-000}"
    done
    printf '\nseeded state:\n'
    for file in "$STATE_DIR"/*-account.json; do
        [ -f "$file" ] || continue
        printf '  %s: %s\n' "$file" \
            "$(jq -r '.acct // "?"' "$file" 2>/dev/null || printf 'unreadable')"
    done
}

cmd_seed() {
    ensure_peer_env
    require_peers_up
    seed_mastodon
    seed_misskey
    if ! nodus_token_works; then
        seed_nodus_token || printf 'warning: Nodus token not seeded\n' >&2
    fi
}

cmd_follow() {
    ensure_peer_env
    require_peers_up
    [ -f "$STATE_DIR/nodus-account.json" ] || seed_nodus_token || true
    # Each proof names what it saw and returns non-zero when it could not get to the
    # end. One blocked direction must not hide the others, so the failures are
    # collected and reported together instead of stopping the run at the first one.
    local failed=0
    check_nodus_to_mastodon || failed=1
    check_mastodon_to_nodus || failed=1
    check_misskey_to_nodus || failed=1
    check_peer_post_in_web_shell || failed=1
    report_failure_logs
    return "$failed"
}

case ${1:-} in
up) cmd_up ;;
down) cmd_down ;;
status) cmd_status ;;
seed) cmd_seed ;;
follow) cmd_follow ;;
*)
    usage
    exit 1
    ;;
esac
