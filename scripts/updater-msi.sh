#!/bin/sh
# Build the Windows installer of the Pathwright Updater from its built .exe, with the WiX 3
# toolset (on GitHub's Windows runners; installed with Chocolatey when it is not there).
# Run from Git Bash on Windows, after `cargo build --release -p pathwright-updater`:
#
#   scripts/updater-msi.sh [OUT.msi]        # default: PathwrightUpdater-Windows.msi
set -eu
cd "$(dirname "$0")/.."

out=${1:-PathwrightUpdater-Windows.msi}
exe=target/release/pathwright-updater.exe
[ -f "$exe" ] || { echo "$exe is not built" >&2; exit 1; }
version=$(sed -n 's/^version = "\(.*\)"$/\1/p' crates/pathwright-updater/Cargo.toml | head -n 1)

# candle.exe and light.exe: where the WIX variable says, else installed now.
bin=
if [ -n "${WIX:-}" ] && [ -f "${WIX}bin/candle.exe" ]; then
    bin="${WIX}bin"
else
    choco install wixtoolset --no-progress -y >&2
    for dir in "/c/Program Files (x86)"/WiX\ Toolset\ v3.*/bin; do
        [ -f "$dir/candle.exe" ] && bin=$dir
    done
fi
[ -n "$bin" ] || { echo "the WiX toolset was not found" >&2; exit 1; }

mkdir -p target/wix
"$bin/candle.exe" -nologo -arch x64 -ext WixUtilExtension \
    "-dVersion=$version" "-dExe=$exe" "-dIcon=app/src-tauri/icons/icon.ico" \
    -out target/wix/updater.wixobj crates/pathwright-updater/wix/main.wxs
# -sval: the validation needs Windows Installer's service, which the runners do not always give.
"$bin/light.exe" -nologo -sval -ext WixUtilExtension -out "$out" target/wix/updater.wixobj
echo "$out built (version $version)"
