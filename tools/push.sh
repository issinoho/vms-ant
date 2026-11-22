#!/usr/bin/env bash
# push.sh <node> - upload the prepared tree (staging/) to <node>'s work directory,
# into <workdir>.APACHE-ANT-<version with dots as underscores>], e.g.
# [.APACHE-ANT-1_10_18]. Only files whose content changed since the last push
# to this node are uploaded (PUSH_ALL=1 uploads everything). The manual (about
# 1,500 files) is left out unless PUSH_MANUAL=1: only the kit needs it.
#
set -euo pipefail
export LC_ALL=C   # sort and comm must agree on collation

top=$(cd "$(dirname "$0")/.." && pwd)
node=${1:?usage: push.sh <node>}
. "$top/upstream.conf"
name=$UPSTREAM_NAME-$UPSTREAM_VERSION
stage=$top/staging/$name
remote=$(echo "$name" | tr . _)
[ -d "$stage/vmsport" ] || { echo "push: run tools/prepare.sh first" >&2; exit 1; }

echo "push: -> $node:[.$(echo "$remote" | tr a-z A-Z)]"
read -r _ _ HOST PORT USER WORKDIR SFTPDIR < <(awk -v n="$node" '$1==n' "$top/tools/nodes.conf")
[ -n "${HOST:-}" ] || { echo "push: unknown node '$node'" >&2; exit 2; }
manifest=$top/cache/pushed-$name-$node.sha
[ "${PUSH_ALL:-}" = 1 ] && rm -f "$manifest"
touch "$manifest"
now=$top/cache/push-$name-$node.sha
skip=(-path "$name/manual" -prune -o)
[ "${PUSH_MANUAL:-}" = 1 ] && skip=()
(cd "$stage/.." && find "$name" "${skip[@]}" -type f -print0 | sort -z | xargs -0 sha256sum) |
    sed "s| $name/| $remote/|" > "$now"
changed=$(comm -23 <(awk '{print $2" "$1}' "$now" | sort) \
                   <(awk '{print $2" "$1}' "$manifest" | sort) | awk '{print $1}')
echo "push: $(echo "$changed" | grep -c . || true) changed of $(wc -l < "$now") files"
batch=$top/cache/push-$node.batch
{
    echo "-mkdir $SFTPDIR"
    echo "cd $SFTPDIR"
    (cd "$stage" && find . ${skip:+-path ./manual -prune -o} -type d -print) | sed "s|^\.|$remote|; s|^|-mkdir |"
    # Explicit put per file: 'put -r' into an existing directory nests a copy.
    for f in $changed; do echo "put $stage/${f#"$remote"/} $f"; done
} > "$batch"
sftp -P "$PORT" -i "${VMS_SSH_KEY:-$HOME/.ssh/vms_ed25519}" -o BatchMode=yes -b "$batch" "$USER@$HOST" \
    2>&1 >/dev/null | grep -vE '^ *Welcome to|^ *$|^remote mkdir .*Failure' >&2 || true
cp "$now" "$manifest"
echo "push: done"
