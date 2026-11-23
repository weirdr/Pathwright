#!/bin/sh
# The version of the next addon release (.github/workflows/addon-release.yml), tagged Pathwright-vX.Y.Z.
#
# addon/VERSION holds the version the release line starts from. Each release after it bumps the
# patch number of the newest Pathwright-v tag; to start a new minor or major version, set addon/VERSION
# to it (1.1.0, 2.0.0): the next release takes it, and the ones after go on from there (1.1.1...).
#
#   scripts/addon-version.sh            # 1.0.3
set -eu
cd "$(dirname "$0")/.."
base=$(head -n 1 addon/VERSION | tr -d '[:space:]')
case $base in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *)
        echo "addon/VERSION is not X.Y.Z: $base" >&2
        exit 1
        ;;
esac
latest=$(git tag --list 'Pathwright-v[0-9]*.[0-9]*.[0-9]*' | sed 's/^Pathwright-v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
newer() { # $1 is above $2
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)" = "$1" ]
}
if [ -z "$latest" ] || newer "$base" "$latest"; then
    echo "$base"
else
    echo "$latest" | awk -F. '{ printf "%d.%d.%d\n", $1, $2, $3 + 1 }'
fi
