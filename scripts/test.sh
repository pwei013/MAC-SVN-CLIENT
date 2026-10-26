#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
exec "$task_root/scripts/swift.sh" run SVNCoreChecks "$@"
