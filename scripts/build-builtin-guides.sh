#!/bin/sh
# Build every built-in guide again (addon/guides/*.guide into addon/Pathwright_Guide/Builtin) with
# its walks: the fg CLI built once in release mode and the game data unpacked once, for all of them
# (guide_build.py would otherwise run cargo and unpack the data for each guide).
#   scripts/build-builtin-guides.sh                     every guide
#   scripts/build-builtin-guides.sh addon/guides/x.guide ...   those only
#   scripts/build-builtin-guides.sh --no-walks          without the walks (quicker)
# Other options are passed to guide_build.py (--out <dir> writes elsewhere). FG_BIN=<fg binary>
# uses that one instead of building it.
set -eu
cd "$(dirname "$0")/.."

guides=
opts=
walks=1
for a in "$@"; do
    case $a in
        *.guide) guides="$guides $a" ;;
        --no-walks)
            walks=
            opts="$opts $a"
            ;;
        *) opts="$opts $a" ;;
    esac
done
[ -n "$guides" ] || guides=$(ls addon/guides/*.guide)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
zstd -dqf data/forever.sqlite.zst -o "$tmp/forever.sqlite"
if [ -n "$walks" ] && [ -z "${FG_BIN:-}" ]; then
    cargo build --release --locked --quiet -p fg
    target=${CARGO_TARGET_DIR:-target}
    case $target in /*) ;; *) target="$PWD/$target" ;; esac
    FG_BIN="$target/release/fg"
    export FG_BIN
fi

failed=
for g in $guides; do
    # The summary line of each (not the levels of every variant); all of it when it fails.
    # shellcheck disable=SC2086 # the options are words
    if python3 addon/tools/guide_build.py "$g" --db "$tmp/forever.sqlite" $opts >"$tmp/out"; then
        grep -v '^  {' "$tmp/out" || true
    else
        cat "$tmp/out"
        failed="$failed $g"
    fi
done
if [ -n "$failed" ]; then
    echo "failed:$failed" >&2
    exit 1
fi
