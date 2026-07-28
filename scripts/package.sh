#!/usr/bin/env bash
# Package the mod into a Factorio-compatible zip. Its root directory must match
# the mod name and version exactly, as required by Factorio and the Mod Portal.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mod_dir="$repo_root/mod/hmph-wiretap"
name="$(python3 -c "import json; print(json.load(open('$mod_dir/info.json'))['name'])")"
version="$(python3 -c "import json; print(json.load(open('$mod_dir/info.json'))['version'])")"
out_dir="$repo_root/dist"
stage="$out_dir/${name}_$version"

rm -rf "$stage" "$out_dir/${name}_$version.zip"
mkdir -p "$stage"
cp -r "$mod_dir/." "$stage/"
cp "$repo_root/thumbnail.png" "$stage/thumbnail.png"

(cd "$out_dir" && zip -qr "${name}_$version.zip" "${name}_$version")
rm -rf "$stage"
echo "Built $out_dir/${name}_$version.zip"
echo "Copy it into your Factorio mods folder:"
echo "  Windows: %APPDATA%\\Factorio\\mods\\"
echo "  Linux:   ~/.factorio/mods/"
