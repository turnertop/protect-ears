#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
cd "$task_root"

# Keep release builds separate from an app already running from dist/.
zsh "$task_root/scripts/build-app.sh" --universal
task_app="$task_root/dist/release/Protect Ears.app"
task_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$task_app/Contents/Info.plist")"
task_stage="$(mktemp -d "$task_root/.build/release-stage.XXXXXX")"
trap 'rm -rf "$task_stage"' EXIT
ditto "$task_app" "$task_stage/Protect Ears.app"
ln -s /Applications "$task_stage/Applications"
cp "$task_root/LICENSE" "$task_root/DISCLAIMER.md" "$task_root/Resources/INSTALL.txt" "$task_stage/"

task_output="$task_root/dist/release"
task_archive="$task_output/Protect-Ears-macOS-universal.zip"
task_image="$task_output/Protect-Ears-macOS-universal.dmg"
# ZIP extracts to a folder; the disk image presents the same files at its root.
mkdir -p "$task_stage/Protect Ears"
mv "$task_stage/Protect Ears.app" "$task_stage/Applications" "$task_stage/LICENSE" \
    "$task_stage/DISCLAIMER.md" "$task_stage/INSTALL.txt" "$task_stage/Protect Ears/"
ditto -c -k --sequesterRsrc --keepParent "$task_stage/Protect Ears" "$task_archive"
hdiutil create -ov -volname "Protect Ears $task_version" -srcfolder "$task_stage/Protect Ears" \
    -format UDZO "$task_image"
(
    cd "$task_output"
    shasum -a 256 Protect-Ears-macOS-universal.dmg Protect-Ears-macOS-universal.zip > SHA256SUMS.txt
    shasum -a 256 -c SHA256SUMS.txt
)
printf 'Packaged version %s in %s\n' "$task_version" "$task_output"
