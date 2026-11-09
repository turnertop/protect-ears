#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
cd "$task_root"
export CLANG_MODULE_CACHE_PATH="$task_root/.build/clang-module-cache"
swift build -c release --disable-sandbox --scratch-path "$task_root/.build" \
    --cache-path "$task_root/.build/cache" --config-path "$task_root/.build/config" \
    --security-path "$task_root/.build/security"
task_app="$task_root/dist/Protect Ears.app"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
cp "$task_root/.build/release/ProtectEars" "$task_app/Contents/MacOS/ProtectEars"
cp "$task_root/Resources/Info.plist" "$task_app/Contents/Info.plist"
codesign --force --sign - "$task_app"
printf 'Built %s\n' "$task_app"
