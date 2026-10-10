#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h:h}"
binary="$project_dir/.build/performance/process-monitor"
source_file="$project_dir/scripts/performance/process-monitor.c"
mkdir -p "$project_dir/.build/performance"
if [[ ! -x "$binary" || "$source_file" -nt "$binary" ]]; then
  clang -O2 -Wall -Wextra -Werror -std=c11 "$source_file" -o "$binary"
fi
exec "$binary" "$@"
