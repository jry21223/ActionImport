#!/bin/zsh
# Builds the app and writes a versioned zip plus its SHA-256 into dist/.
# Publishing is left to the maintainer: the matching `gh release` command is printed, not run.
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
zsh scripts/build-app.sh >/dev/null
archive="ActionImport-$version-macOS.zip"
mv -f dist/ActionImport-macOS.zip "dist/$archive"
(cd dist && shasum -a 256 "$archive" > "$archive.sha256" && shasum -a 256 -c "$archive.sha256" >/dev/null)
# Verify what users download, not just the staging copy.
unpacked="$(mktemp -d "${TMPDIR:-/tmp}/actionimport-verify.XXXXXX")"
trap 'rm -rf "$unpacked"' EXIT
ditto -x -k "dist/$archive" "$unpacked"
codesign --verify --strict --deep "$unpacked/ActionImport.app"
print -r -- "dist/$archive"
print -r -- "dist/$archive.sha256"
print -r -- "Publish with:"
print -r -- "  gh release create v$version dist/$archive dist/$archive.sha256 --title 'ActionImport $version' --notes-file <notes.md>"
