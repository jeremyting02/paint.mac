#!/bin/sh
set -eu

usage() {
    printf '%s\n' 'Usage: sh Tests/paintnet-capture.sh {black-and-white|invert-colors} INPUT.png OUTPUT.png' >&2
    exit 2
}

[ "$#" -eq 3 ] || usage
case "$1" in black-and-white|invert-colors) operation=$1 ;; *) usage ;; esac
case "$2:$3" in *.png:*.png) ;; *) usage ;; esac

tests_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
app=${PAINTNET_APP:-"$HOME/Applications/Paint.NET.app"}
wine=${PAINTNET_WINE:-"$app/Contents/Resources/Wine Devel.app/Contents/Resources/wine/bin/wine"}
WINEPREFIX=${WINEPREFIX:-"$HOME/Library/Application Support/Paint.NET/wineprefix"}
WINEDEBUG=${WINEDEBUG:--all}
export WINEPREFIX WINEDEBUG

if [ ! -x "$wine" ] || [ ! -d "$WINEPREFIX/drive_c" ]; then
    printf '%s\n' 'Paint.NET Wine installation not found. Set PAINTNET_APP, PAINTNET_WINE or WINEPREFIX.' >&2
    exit 1
fi
if [ ! -f "$2" ] || [ -e "$3" ] || [ -L "$3" ]; then
    printf '%s\n' 'Provide an existing input PNG and a new output path.' >&2
    exit 1
fi

# Stage on the destination filesystem so publishing can use an atomic,
# no-overwrite hard link. Random filenames also identify the runner's tab.
output_dir=$(CDPATH='' cd -- "$(dirname -- "$3")" && pwd)
output="$output_dir/$(basename -- "$3")"
stage=$(mktemp -d "$output_dir/paintnet-capture.XXXXXXXX")
id=$(basename -- "$stage")
input="$stage/$id-input.png"
capture="$stage/$id-output.png"
trap 'if [ -n "$stage" ]; then printf "Capture staging files: %s\n" "$stage" >&2; fi' EXIT
cp -- "$2" "$input"

# Wine's default Z: drive maps to the host root.
windows_path() {
    printf 'Z:%s' "$(printf '%s' "$1" | tr '/' '\\')"
}

compiler='C:\windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
"$wine" "$compiler" /nologo /platform:x64 "/out:$(windows_path "$stage/Capture.exe")" \
    "$(windows_path "$tests_dir/PaintNETCapture.cs")"
"$wine" "$(windows_path "$stage/Capture.exe")" "$operation" "$(windows_path "$input")" "$(windows_path "$capture")"
link "$capture" "$output"
rm -f -- "$input" "$capture" "$stage/Capture.exe"
rmdir -- "$stage"
stage=''
printf 'Captured %s\n' "$output"
