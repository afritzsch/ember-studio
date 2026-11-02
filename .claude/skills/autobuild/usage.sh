#!/bin/sh
# Prints plan usage from Patchbay's status-line cache, one key=value per line:
#   week=<int %> week_resets=<epoch> five=<int %> five_resets=<epoch> age=<seconds since update>
# Exit 1 if the cache is missing. The cache updates whenever any Claude session in Patchbay
# redraws its status line, so age stays small while sessions are working.
f="$HOME/Library/Application Support/Patchbay/usage.json"
[ -f "$f" ] || { echo "error=no usage.json at $f"; exit 1; }
LC_ALL=C; export LC_ALL
get() { plutil -extract "$1" raw -o - "$f" 2>/dev/null; }
printf 'week=%.0f\n' "$(get seven_day.used_percentage)"
echo "week_resets=$(get seven_day.resets_at)"
printf 'five=%.0f\n' "$(get five_hour.used_percentage)"
echo "five_resets=$(get five_hour.resets_at)"
echo "age=$(( $(date +%s) - $(stat -f %m "$f") ))"
