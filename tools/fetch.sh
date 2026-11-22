#!/usr/bin/env bash
# fetch.sh - download and verify what upstream.conf names into cache/:
#
#   cache/apache-ant-<version>-bin.tar.gz   the binary distribution
#   cache/apache-ant-<version>-src.tar.gz   the source distribution (patched classes)
#
# Each file is checked against its pinned SHA-512 and its detached signature
# (.asc) against the pinned key in keys/ only (a throwaway keyring).
set -euo pipefail

top=$(cd "$(dirname "$0")/.." && pwd)
. "$top/upstream.conf"
cache=$top/cache
mkdir -p "$cache"

keyring=$cache/keyring.gpg
rm -f "$keyring"
for k in "$top"/keys/*.asc; do
    gpg -q --no-default-keyring --keyring "$keyring" --import "$k" 2>/dev/null
done

# get <url> <file> <sha512> <key>
get() {
    local url=$1 f=$2 sum=$3 key=$4
    if [ ! -f "$f" ]; then
        echo "fetch: $url"
        curl -sSfL -o "$f.tmp" "$url"
        mv "$f.tmp" "$f"
    fi
    [ -f "$f.asc" ] || curl -sSfL -o "$f.asc" "$url.asc"
    echo "$sum  $f" | sha512sum -c --quiet - ||
        { echo "fetch: $f: SHA-512 mismatch" >&2; rm -f "$f"; exit 1; }
    gpg --no-default-keyring --keyring "$keyring" --status-fd 1 --verify "$f.asc" "$f" 2>/dev/null |
        grep -q "^\[GNUPG:\] VALIDSIG .* $key\$" ||
        { echo "fetch: $f: not validly signed by $key" >&2; exit 1; }
    echo "fetch: $(basename "$f") OK (SHA-512, signed by $key)"
}

get "$UPSTREAM_URL" "$cache/$(basename "$UPSTREAM_URL")" "$UPSTREAM_SHA512" "$UPSTREAM_GPG_KEY"
get "$SOURCE_URL" "$cache/$(basename "$SOURCE_URL")" "$SOURCE_SHA512" "$UPSTREAM_GPG_KEY"
