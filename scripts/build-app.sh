#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
cd "$task_root"
export CLANG_MODULE_CACHE_PATH="$task_root/.build/clang-module-cache"

if (( $# == 0 )); then
    task_mode=native
elif (( $# == 1 )) && [[ "$1" == --universal ]]; then
    task_mode=universal
else
    print -u2 'Usage: zsh scripts/build-app.sh [--universal]'
    exit 2
fi

task_build_args=(--product ProtectEars -c release --disable-sandbox
    --cache-path "$task_root/.build/cache" --config-path "$task_root/.build/config"
    --security-path "$task_root/.build/security")

if [[ "$task_mode" == universal ]]; then
    task_binaries=()
    for task_arch in arm64 x86_64; do
        task_arch_args=("${task_build_args[@]}" --scratch-path "$task_root/.build/universal-$task_arch"
            --triple "$task_arch-apple-macosx13.0")
        swift build "${task_arch_args[@]}"
        task_binary_dir="$(swift build "${task_arch_args[@]}" --show-bin-path)"
        task_binaries+=("$task_binary_dir/ProtectEars")
    done
    task_app="$task_root/dist/release/Protect Ears.app"
else
    task_native_args=("${task_build_args[@]}" --scratch-path "$task_root/.build")
    swift build "${task_native_args[@]}"
    task_binary_dir="$(swift build "${task_native_args[@]}" --show-bin-path)"
    task_app="$task_root/dist/Protect Ears.app"
fi

mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
if [[ "$task_mode" == universal ]]; then
    lipo -create "${task_binaries[@]}" -output "$task_app/Contents/MacOS/ProtectEars"
    lipo "$task_app/Contents/MacOS/ProtectEars" -verify_arch arm64 x86_64
    # Download builds should not expose the builder's local paths in debug metadata.
    strip -S "$task_app/Contents/MacOS/ProtectEars"
else
    cp "$task_binary_dir/ProtectEars" "$task_app/Contents/MacOS/ProtectEars"
fi
cp "$task_root/Resources/Info.plist" "$task_app/Contents/Info.plist"
cp "$task_root/LICENSE" "$task_root/DISCLAIMER.md" "$task_root/Resources/INSTALL.txt" \
    "$task_app/Contents/Resources/"
codesign --force --sign - "$task_app"
codesign --verify --deep --strict "$task_app"
plutil -lint "$task_app/Contents/Info.plist"
printf 'Built %s\n' "$task_app"
