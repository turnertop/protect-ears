#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
cd "$task_root"
export CLANG_MODULE_CACHE_PATH="$task_root/.build/clang-module-cache"
swift build --product GuardEngineChecks --disable-sandbox --scratch-path "$task_root/.build" \
    --cache-path "$task_root/.build/cache" --config-path "$task_root/.build/config" \
    --security-path "$task_root/.build/security"
"$task_root/.build/debug/GuardEngineChecks"
