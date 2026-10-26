#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
cd "$task_root"
"$task_root/scripts/swift.sh" build -c release --product SVNManager
task_bin_dir="$("$task_root/scripts/swift.sh" build -c release --show-bin-path)"
task_app="$task_root/build/SVN管理.app"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
cp "$task_bin_dir/SVNManager" "$task_app/Contents/MacOS/.SVNManager.new"
mv -f "$task_app/Contents/MacOS/.SVNManager.new" "$task_app/Contents/MacOS/SVNManager"
cp "$task_root/Resources/Info.plist" "$task_app/Contents/Info.plist"
CLANG_MODULE_CACHE_PATH="$task_root/work/module-cache" swift -module-cache-path "$task_root/work/module-cache" \
    "$task_root/scripts/create-icon.swift" "$task_root/work/AppIcon.iconset"
/usr/bin/iconutil -c icns "$task_root/work/AppIcon.iconset" -o "$task_app/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --sign - "$task_app"
printf '已构建本机应用：%s\n' "$task_app"
