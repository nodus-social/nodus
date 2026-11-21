#!/bin/bash
# Removes the statuses that spec runs create for their own arrangement, and the
# favourites and bookmarks the seed accounts put on the seeded ones.
#
# The specs delete what they created, but a run that fails before its cleanup
# leaves it behind. A stray is newer than the seed, so it fills the first page of
# the home timeline and changes every visual baseline that reads that page; a
# leftover favourite or bookmark changes the card itself. seed.sh calls this
# before it reports, so a used lab converges to the seeded graph instead of
# needing a reset.
#
#   prune-strays.sh BASE TOKEN:ACCOUNT ... -- SEED_TEXT ...
#
# Only statuses authored by the named accounts are touched, and only when their
# text is none of the seed's own. Deletion goes through
# DELETE /api/v1/statuses/{id} with the author's own token; a 404 counts as
# already gone, and the reaction deletes are idempotent for the same reason.
set -euo pipefail

for tool in curl jq; do
	command -v "$tool" >/dev/null || {
		printf 'prune-strays.sh needs %s\n' "$tool" >&2
		exit 1
	}
done

base=$1
shift
accounts=()
while [ "$1" != -- ]; do
	accounts+=("$1")
	shift
done
shift
keep=$(printf '%s\n' "$@" | jq -R . | jq -sc .)

# `content` is HTML; compare the decoded sentence, the same way seed.sh does
# when it decides a post already exists.
classify='
	def text: gsub("&#39;"; "\u0027") | gsub("&#x27;"; "\u0027")
		| gsub("&quot;"; "\u0022") | gsub("&lt;"; "<")
		| gsub("&gt;"; ">") | gsub("&amp;"; "&");
	.[] | ((.content | text) as $c
		| [$keep[] as $seed | $c | contains($seed)] | any) as $kept
	| (if $kept then "keep" else "stray" end) + " " + .id'

kept_ids=()
for entry in "${accounts[@]}"; do
	token=${entry%%:*}
	id=${entry#*:}
	cursor=
	while :; do
		page=$(curl -fsS -H "Authorization: Bearer $token" \
			"$base/api/v1/accounts/$id/statuses?limit=40${cursor:+&max_id=$cursor}")
		[ "$(printf '%s' "$page" | jq length)" -gt 0 ] || break
		while read -r kind stray; do
			[ "$kind" = stray ] || continue
			code=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
				-H "Authorization: Bearer $token" \
				"$base/api/v1/statuses/$stray")
			case "$code" in
			200) printf '  pruned stray status %s\n' "$stray" >&2 ;;
			404) ;;
			*)
				printf 'prune-strays.sh: deleting status %s returned HTTP %s\n' \
					"$stray" "$code" >&2
				exit 1
				;;
			esac
		done <<<"$(printf '%s' "$page" | jq -r --argjson keep "$keep" "$classify")"
		while read -r kind kept; do
			[ "$kind" = keep ] && kept_ids+=("$kept")
		done <<<"$(printf '%s' "$page" | jq -r --argjson keep "$keep" "$classify")"
		cursor=$(printf '%s' "$page" | jq -r '.[-1].id')
	done
done

# A card shows the reader's favourite and bookmark state, so a reaction a failed
# run left on a seeded status is visible state, not incidental data.
for entry in "${accounts[@]}"; do
	token=${entry%%:*}
	for id in "${kept_ids[@]}"; do
		for reaction in favourite bookmark; do
			code=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
				-H "Authorization: Bearer $token" \
				"$base/api/v1/statuses/$id/$reaction")
			case "$code" in
			200 | 404) ;;
			*)
				printf 'prune-strays.sh: clearing %s on %s returned HTTP %s\n' \
					"$reaction" "$id" "$code" >&2
				exit 1
				;;
			esac
		done
	done
done
printf '  seeded statuses carry no favourite or bookmark from a seed account\n' >&2
