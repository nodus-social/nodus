# Sourced by release-118.sh and release-100.sh; not executable on its own.
#
# deploy/build.sh writes BUILD-INFO and SHA256SUMS into the artifact directory. This
# check refuses a directory that names a different target or whose contents no longer
# match its checksums, and prints the pins so the release log records what is shipping.
# A directory with no BUILD-INFO is a hand-built set: accepted with one line, because
# the release scripts are old enough to have been fed one, but never silently.
#
# usage: artifact_manifest_check <artifact-dir> <backend|web>
artifact_manifest_check() {
    local dir=$1 required=$2
    local manifest="$1/BUILD-INFO"
    local target='' source='' created='' glibc='' pins=''
    local key value sums out count repo

    if [ ! -f "$manifest" ]; then
        printf '   no BUILD-INFO in %s: assuming a hand-built artifact set; its pins and target are unverified\n' "$dir"
        return 0
    fi

    while IFS='=' read -r key value; do
        case $key in
        '' | '#'*) continue ;;
        target) target=$value ;;
        source) source=$value ;;
        created) created=$value ;;
        glibc_ceiling) glibc=$value ;;
        nodus-backend | recommender | sdk | server-sdk | web) pins="$pins$key=$value " ;;
        esac
    done <"$manifest"

    case ${target:-}:$required in
    backend:backend | all:backend | web:web | all:web) ;;
    *)
        printf 'FAIL: %s was built for target %s; this release needs %s or all\n' \
            "$dir" "${target:-unknown}" "$required"
        printf '      rebuild with: deploy/build.sh %s <out-dir>\n' "$required"
        return 1
        ;;
    esac

    sums="$dir/SHA256SUMS"
    if [ ! -f "$sums" ]; then
        printf 'FAIL: %s/BUILD-INFO exists but SHA256SUMS is missing; the artifact set is incomplete\n' "$dir"
        return 1
    fi
    if ! out=$(cd "$dir" && sha256sum -c --quiet SHA256SUMS 2>&1); then
        printf '%s\n' "$out" | sed 's/^/   /' >&2
        printf 'FAIL: %s no longer matches its SHA256SUMS; it is not the set deploy/build.sh produced\n' "$dir"
        return 1
    fi
    count=$(wc -l <"$sums")

    printf '   BUILD-INFO: target=%s source=%s built=%s' "$target" "${source:-unknown}" "${created:-unknown}"
    if [ -n "$glibc" ]; then printf ' glibc<=%s' "$glibc"; fi
    printf '\n'
    printf '   pins: %s\n' "${pins% }"
    printf '   SHA256SUMS: %s artifact(s) verified\n' "$count"

    # Artifacts older than the checkout are legitimate — a release is cut from pins and
    # the branch may move on — but the operator should see the difference before deploying.
    repo=${REPO:-$(git rev-parse --show-toplevel 2>/dev/null || true)}
    if [ -n "$repo" ] && [ "$source" = pins ]; then
        for key in nodus-backend recommender sdk server-sdk web; do
            value=$(sed -n "s/^$key=//p" "$manifest" | head -1)
            current=$(git -C "$repo" ls-tree HEAD -- "$key" 2>/dev/null | awk '{print $3}')
            if [ -n "$value" ] && [ -n "$current" ] && [ "$value" != "$current" ]; then
                printf '   note: %s in the artifact is %s, the checkout records %s\n' "$key" "$value" "$current"
            fi
        done
    fi

    return 0
}
