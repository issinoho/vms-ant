#!/usr/bin/env bash
# prepare.sh - build the VMS-ready tree in staging/apache-ant-<version>/
#
#   1. fetch + verify the binary and source distributions (fetch.sh)
#   2. extract the binary distribution
#   3. unpack, from the source distribution's src/main/, the files the patches
#      touch into vmsport/src/ant/, and list them in vmsport/patched.lis
#   4. apply patches/series, then lay overlay/ over the top
#
# Nothing in staging/ is ever edited by hand: fix things in patches/ or overlay/.
set -euo pipefail

top=$(cd "$(dirname "$0")/.." && pwd)
. "$top/upstream.conf"
name=$UPSTREAM_NAME-$UPSTREAM_VERSION
stage=$top/staging/$name

step() { echo "prepare: $*"; }
die() { echo "prepare: error: $*" >&2; exit 1; }

"$top/tools/fetch.sh" >/dev/null

step "extracting $name"
rm -rf "$stage"
mkdir -p "$top/staging"
tar -xzf "$top/cache/$(basename "$UPSTREAM_URL")" -C "$top/staging"
[ -f "$stage/lib/ant.jar" ] || die "tarball did not unpack to $stage"

# Files the patches change under vmsport/src/ant/ (all classes of lib/ant.jar).
touched=$(while read -r p; do
              case $p in ''|'#'*) continue ;; esac
              sed -n 's|^+++ b/vmsport/src/ant/\([^[:space:]]*\).*|\1|p' "$top/patches/$p"
          done < "$top/patches/series" | sort -u)
mkdir -p "$stage/vmsport/src/ant"
: > "$stage/vmsport/patched.lis"
if [ -n "$touched" ]; then
    step "sources: $(wc -w <<< "$touched") files"
    srcdir=$name/src/main
    tar -xzf "$top/cache/$(basename "$SOURCE_URL")" -C "$stage/vmsport/src/ant" \
        --strip-components=3 $(sed "s|^|$srcdir/|" <<< "$touched") ||
        die "a patched file is not in the source distribution"
    for f in $touched; do echo "ant $UPSTREAM_VERSION $f" >> "$stage/vmsport/patched.lis"; done
fi

while read -r p; do
    case $p in ''|'#'*) continue ;; esac
    step "patch $p"
    patch -d "$stage" -p1 -s --no-backup-if-mismatch -F0 < "$top/patches/$p" ||
        die "patch $p does not apply cleanly"
done < "$top/patches/series"

# overlay/ may only add files; changes to upstream files belong in patches/.
(cd "$top/overlay" && find . -type f) | while read -r f; do
    [ -e "$stage/$f" ] && die "overlay/$f would replace an upstream file; use a patch"
    true
done
cp -a "$top/overlay/." "$stage/"
printf 'ANT_VERSION=%s\nKIT_VERSION=%s-vms%s\n' "$UPSTREAM_VERSION" "$UPSTREAM_VERSION" \
    "$VMS_PATCH_LEVEL" > "$stage/vmsport/VERSION.ENV"

step "staged $stage"
