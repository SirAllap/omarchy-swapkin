#!/usr/bin/env bash
# Usage: bash sync-write.sh <dir> <file-name>   (JSON snapshot on stdin)
# Writes this device's usage snapshot into the sync folder. The folder is a
# trust boundary (any peer can drop entries in it), so a symlink planted at the
# snapshot path must never redirect the write: refuse it, otherwise write a temp
# file created inside the folder (mktemp is O_EXCL, never follows) and rename it
# over the target (rename replaces a link itself, never what it points at).
set -u
dir=$1 name=$2
case $name in ''|*/*|.|..) echo "refusing bad snapshot name: $name" >&2; exit 2 ;; esac
[[ -d $dir ]] || { echo "sync folder missing: $dir" >&2; exit 1; }
target=$dir/$name
if [[ -L $target ]]; then
  echo "refusing to write snapshot: $target is a symlink" >&2
  exit 3
fi
if [[ -e $target && ! -f $target ]]; then
  echo "refusing to write snapshot: $target is not a regular file" >&2
  exit 3
fi
tmp=$(mktemp "$dir/.swapkin-snapshot.XXXXXX") || exit 1
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" || exit 1
[[ -s $tmp ]] && [[ $(tail -c1 "$tmp" | wc -l) -eq 0 ]] && echo >> "$tmp"
mv -T -- "$tmp" "$target" || exit 1
trap - EXIT
