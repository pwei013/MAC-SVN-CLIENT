#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
cd "$task_root"
mkdir -p "$task_root/work/module-cache" "$task_root/work/swift-cache" "$task_root/work/swift-config" "$task_root/work/swift-security"
export CLANG_MODULE_CACHE_PATH="$task_root/work/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_root/work/module-cache"
task_command="${1:-build}"
if (( $# > 0 )); then shift; fi
task_sdk_options=()
case "$task_command" in
    build|run|test)
        task_sdk="${SVN_MANAGER_SDK:-}"
        if [[ -z "$task_sdk" ]]; then
            task_developer="$(/usr/bin/xcode-select -p)"
            task_default_sdk="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
            task_default_sdk="${task_default_sdk:A}"
            # CLT 27 exposes SwiftUI's State macro without shipping its plugin.
            # Use the installed 26 SDK's compatible property wrapper in this case.
            if [[ "$task_developer" == */CommandLineTools && "$task_default_sdk" == */MacOSX27* &&
                  ! -f "$task_developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" &&
                  -d "$task_developer/SDKs/MacOSX26.sdk" ]]; then
                task_sdk="$task_developer/SDKs/MacOSX26.sdk"
            fi
        fi
        if [[ -n "$task_sdk" ]]; then
            [[ -d "$task_sdk/System/Library/Frameworks" ]] || { print -u2 'SVN_MANAGER_SDK 不是有效的 macOS SDK 目录。'; exit 1; }
            task_sdk_options=(--sdk "$task_sdk")
        fi
        ;;
esac
exec swift "$task_command" --scratch-path "$task_root/work/swift-build" \
    --cache-path "$task_root/work/swift-cache" --config-path "$task_root/work/swift-config" \
    --security-path "$task_root/work/swift-security" "${task_sdk_options[@]}" "$@"
