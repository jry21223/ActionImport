#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
swift build -c release --product ActionImport
binary_dir="$(swift build -c release --show-bin-path)"
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/actionimport-build.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
bundle_dir="$staging_dir/ActionImport.app"
mkdir -p "$bundle_dir/Contents/MacOS" "$bundle_dir/Contents/Resources"
cp "$binary_dir/ActionImport" "$bundle_dir/Contents/MacOS/ActionImport"
cp "$project_dir/Resources/Info.plist" "$bundle_dir/Contents/Info.plist"
cp "$project_dir/Resources/AppLogo.png" "$bundle_dir/Contents/Resources/AppLogo.png"
xattr -cr "$bundle_dir"
codesign --force --sign - --identifier local.actionimport.desktop "$bundle_dir"
codesign --verify --strict "$bundle_dir"
# Sign and archive outside File Provider folders, which may add FinderInfo after xattr cleanup.
mkdir -p "$project_dir/dist"
ditto -c -k --sequesterRsrc --keepParent "$bundle_dir" "$project_dir/dist/ActionImport-macOS.zip"
ditto --noextattr "$bundle_dir" "$project_dir/dist/ActionImport.app"
print -r -- "$project_dir/dist/ActionImport.app"
