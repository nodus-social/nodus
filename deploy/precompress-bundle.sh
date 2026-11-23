#!/bin/sh
# Emits precompressed siblings for the bundle Caddy serves from disk.
#
#   deploy/precompress-bundle.sh web/dist
#
# The hashed `.wasm`, `.js` and `.css` files are 92% of a first visit, and Caddy's
# `encode` middleware leaves `application/wasm` alone because it is not in its default
# content-type set. The asset handler therefore uses `file_server { precompressed zstd gzip }`
# and needs `<asset>.zst` / `<asset>.gz` next to each asset. A missing sibling is not fatal:
# Caddy falls back to the identity file.
#
# `gzip -n` keeps the output reproducible (no timestamp), and both tools keep the original.
# Both binaries are required: a skipped step is how the bundle silently ships uncompressed.
set -eu

if [ $# -ne 1 ]; then
    printf 'usage: %s <dist-dir>\n' "$0" >&2
    exit 2
fi

dist=$1
[ -d "$dist" ] || {
    printf 'precompress: bundle directory not found: %s\n' "$dist" >&2
    exit 1
}

for tool in gzip zstd; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf 'precompress: %s is not installed; refusing to ship an uncompressed bundle\n' "$tool" >&2
        exit 1
    }
done

count=0
# `find` is not ordered, but the output is only a count and the hashed names make the
# result independent of traversal order.
while IFS= read -r file; do
    gzip -9 -n -k -f "$file"
    zstd -19 -q -f "$file" -o "$file.zst"
    count=$((count + 1))
done <<EOF
$(find "$dist" -type f \( -name '*.wasm' -o -name '*.js' -o -name '*.css' \) | sort)
EOF

if [ "$count" -eq 0 ]; then
    printf 'precompress: no .wasm/.js/.css files under %s\n' "$dist" >&2
    exit 1
fi

printf 'precompress: %s asset(s) in %s now have .gz and .zst siblings\n' "$count" "$dist"
