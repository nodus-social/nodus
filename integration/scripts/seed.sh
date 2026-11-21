#!/bin/bash
# Creates the lab's demo data through the public HTTP API, not by writing SQL:
# the admin comes from NODUS_BOOTSTRAP_*, the two ordinary accounts are
# registered on /auth/register, and every token is obtained with the same PKCE
# flow the browser client uses. Rerunning is additive: posts that already exist
# with the same text are skipped.
set -euo pipefail

SCRIPT_DIR=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

for tool in curl jq openssl; do
	command -v "$tool" >/dev/null || {
		printf 'seed.sh needs %s\n' "$tool" >&2
		exit 1
	}
done

ensure_env
port=$(http_port)
BASE="http://localhost:${port}"
ADMIN_EMAIL=$(env_value NODUS_BOOTSTRAP_EMAIL)
ADMIN_USER=$(env_value NODUS_BOOTSTRAP_USERNAME)
ADMIN_PASSWORD=$(env_value NODUS_BOOTSTRAP_PASSWORD)

ADA_USER=ada
ADA_EMAIL=ada@nodus.test
ADA_PASSWORD=lab-password-ada
GRACE_USER=grace
GRACE_EMAIL=grace@nodus.test
GRACE_PASSWORD=lab-password-grace

CLIENT_NAME="nodus-lab seed"
REDIRECT_URI="http://127.0.0.1:${port}/oauth/callback"
SCOPES="read write follow"
STATE="seed"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

csrf_from() {
	sed -n 's/.*name="csrf_token" value="\([^"]*\)".*/\1/p' "$1" | head -n 1
}

die() {
	printf 'seed failed: %s\n' "$*" >&2
	exit 1
}

wait_for_url "$BASE/healthz" 120 || die "the stack is not answering on $BASE"

# ---- OAuth client ---------------------------------------------------------

app=$(curl -fsS -X POST "$BASE/api/v1/apps" \
	-H 'content-type: application/json' \
	-d "$(jq -nc --arg name "$CLIENT_NAME" --arg redirect "$REDIRECT_URI" \
		--arg scopes "$SCOPES" \
		'{client_name: $name, redirect_uris: $redirect, scopes: $scopes}')") ||
	die "client registration failed"
client_id=$(printf '%s' "$app" | jq -r .client_id)
client_secret=$(printf '%s' "$app" | jq -r .client_secret)
[ -n "$client_id" ] && [ "$client_id" != null ] || die "no client_id in $app"

# ---- account helpers ------------------------------------------------------

register_account() {
	local user=$1 email=$2 password=$3
	local jar="$WORK/$user-register.jar" page="$WORK/$user-register.html"
	curl -fsS -c "$jar" "$BASE/auth/register" -o "$page"
	local csrf
	csrf=$(csrf_from "$page")
	[ -n "$csrf" ] || die "no csrf token on the register page"
	local code
	code=$(curl -sS -o "$WORK/$user-register.out" -w '%{http_code}' \
		-b "$jar" -c "$jar" \
		--data-urlencode "username=$user" \
		--data-urlencode "email=$email" \
		--data-urlencode "password=$password" \
		--data-urlencode "password_confirmation=$password" \
		--data-urlencode "return_to=/" \
		--data-urlencode "csrf_token=$csrf" \
		"$BASE/auth/register")
	case "$code" in
	2* | 3*) ;;
	*) die "registering $user returned HTTP $code" ;;
	esac
}

# Returns a bearer token for an existing account. The token is the only thing on
# stdout; diagnostics go to stderr.
login_token() {
	local email=$1 password=$2 name=$3
	local jar="$WORK/$name.jar" page="$WORK/$name-login.html"
	curl -fsS -c "$jar" "$BASE/auth/login" -o "$page"
	local csrf
	csrf=$(csrf_from "$page")
	[ -n "$csrf" ] || die "no csrf token on the login page"
	local code
	code=$(curl -sS -o "$WORK/$name-login.out" -w '%{http_code}' \
		-b "$jar" -c "$jar" \
		--data-urlencode "email=$email" \
		--data-urlencode "password=$password" \
		--data-urlencode "return_to=/" \
		--data-urlencode "csrf_token=$csrf" \
		"$BASE/auth/login")
	[ "$code" = "303" ] || die "login for $email returned HTTP $code"

	local verifier challenge
	verifier=$(openssl rand -hex 32)
	challenge=$(printf '%s' "$verifier" |
		openssl dgst -sha256 -binary |
		openssl base64 -A |
		tr '+/' '-_' | tr -d '=')

	local consent="$WORK/$name-consent.html" headers="$WORK/$name-consent.headers"
	code=$(curl -sS -o "$consent" -D "$headers" -w '%{http_code}' \
		-b "$jar" -c "$jar" -G "$BASE/oauth/authorize" \
		--data-urlencode "response_type=code" \
		--data-urlencode "client_id=$client_id" \
		--data-urlencode "redirect_uri=$REDIRECT_URI" \
		--data-urlencode "scope=$SCOPES" \
		--data-urlencode "state=$STATE" \
		--data-urlencode "code_challenge=$challenge" \
		--data-urlencode "code_challenge_method=S256")
	[ "$code" = "200" ] || die "authorize page for $name returned HTTP $code"

	csrf=$(csrf_from "$consent")
	[ -n "$csrf" ] || die "no csrf token on the consent page"

	code=$(curl -sS -o /dev/null -D "$headers" -w '%{http_code}' \
		-b "$jar" -c "$jar" -X POST "$BASE/oauth/authorize" \
		--data-urlencode "client_id=$client_id" \
		--data-urlencode "redirect_uri=$REDIRECT_URI" \
		--data-urlencode "scopes=$SCOPES" \
		--data-urlencode "state=$STATE" \
		--data-urlencode "code_challenge=$challenge" \
		--data-urlencode "csrf_token=$csrf" \
		--data-urlencode "decision=allow")
	[ "$code" = "303" ] || die "consent for $name returned HTTP $code"

	local location auth_code
	location=$(sed -n 's/^[Ll]ocation: //p' "$headers" | tr -d '\r' | tail -n 1)
	auth_code=$(printf '%s' "$location" |
		sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')
	[ -n "$auth_code" ] || die "no authorization code in $location"

	local token
	token=$(curl -fsS -X POST "$BASE/oauth/token" \
		--data-urlencode "grant_type=authorization_code" \
		--data-urlencode "code=$auth_code" \
		--data-urlencode "client_id=$client_id" \
		--data-urlencode "client_secret=$client_secret" \
		--data-urlencode "redirect_uri=$REDIRECT_URI" \
		--data-urlencode "code_verifier=$verifier" |
		jq -r .access_token)
	[ -n "$token" ] && [ "$token" != null ] || die "token exchange failed"
	printf '%s\n' "$token"
}

api_get() {
	curl -fsS -H "Authorization: Bearer $1" "$2"
}

account_id() {
	api_get "$1" "$BASE/api/v1/accounts/verify_credentials" | jq -r .id
}

post_status() {
	local token=$1 id=$2 text=$3
	local existing
	existing=$(api_get "$token" "$BASE/api/v1/accounts/$id/statuses?limit=40")
	# `content` is HTML, so an apostrophe comes back as `&#39;`: compare the
	# decoded text, or every seeded sentence with punctuation is posted again.
	if printf '%s' "$existing" |
		jq -e --arg text "$text" \
			'map(select(.content
				| gsub("&#39;"; "\u0027")
				| gsub("&#x27;"; "\u0027")
				| gsub("&quot;"; "\u0022")
				| gsub("&lt;"; "<")
				| gsub("&gt;"; ">")
				| gsub("&amp;"; "&")
				| contains($text))) | length > 0' \
			>/dev/null; then
		printf '  post already present for %s\n' "$text" >&2
		return 0
	fi
	curl -fsS -X POST "$BASE/api/v1/statuses" \
		-H "Authorization: Bearer $token" \
		-H 'content-type: application/json' \
		-d "$(jq -nc --arg text "$text" '{status: $text}')" >/dev/null
	printf '  posted: %s\n' "$text" >&2
}

follow() {
	local token=$1 target=$2
	curl -fsS -X POST "$BASE/api/v1/accounts/$target/follow" \
		-H "Authorization: Bearer $token" >/dev/null
}

# ---- seed ----------------------------------------------------------------

printf 'seeding ordinary accounts ...\n'
register_account "$ADA_USER" "$ADA_EMAIL" "$ADA_PASSWORD"
register_account "$GRACE_USER" "$GRACE_EMAIL" "$GRACE_PASSWORD"

ADA_TOKEN=$(login_token "$ADA_EMAIL" "$ADA_PASSWORD" ada)
GRACE_TOKEN=$(login_token "$GRACE_EMAIL" "$GRACE_PASSWORD" grace)
ADMIN_TOKEN=$(login_token "$ADMIN_EMAIL" "$ADMIN_PASSWORD" admin)

ADA_ID=$(account_id "$ADA_TOKEN")
GRACE_ID=$(account_id "$GRACE_TOKEN")
ADMIN_ID=$(account_id "$ADMIN_TOKEN")

printf 'seeding follows ...\n'
follow "$ADA_TOKEN" "$GRACE_ID"
follow "$ADA_TOKEN" "$ADMIN_ID"
follow "$GRACE_TOKEN" "$ADA_ID"
follow "$ADMIN_TOKEN" "$ADA_ID"
follow "$ADMIN_TOKEN" "$GRACE_ID"

printf 'seeding posts ...\n'
post_status "$ADA_TOKEN" "$ADA_ID" \
	"Hello from Ada. This post comes from the integration lab."
post_status "$ADA_TOKEN" "$ADA_ID" \
	"Ada's second note: the home timeline should show both accounts."
post_status "$GRACE_TOKEN" "$GRACE_ID" \
	"Grace was here. This is real data served by the lab API."
post_status "$GRACE_TOKEN" "$GRACE_ID" \
	"Grace's follow-up: profiles and timelines have something to render."
post_status "$ADMIN_TOKEN" "$ADMIN_ID" \
	"Admin check-in: bootstrap login works over plain HTTP."

printf '\nseeded accounts\n'
printf '  %-10s %-22s %s\n' USER EMAIL PASSWORD
printf '  %-10s %-22s %s\n' "$ADA_USER" "$ADA_EMAIL" "$ADA_PASSWORD"
printf '  %-10s %-22s %s\n' "$GRACE_USER" "$GRACE_EMAIL" "$GRACE_PASSWORD"
printf '  %-10s %-22s %s\n' "$ADMIN_USER" "$ADMIN_EMAIL" "$ADMIN_PASSWORD"
printf '\n  ada id %s, grace id %s, admin id %s\n' \
	"$ADA_ID" "$GRACE_ID" "$ADMIN_ID"
printf '  open http://localhost:%s and sign in with an account above\n' "$port"
