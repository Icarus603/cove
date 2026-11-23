#!/bin/sh
# Example Cove plugin: CPU load and memory use, refreshed every 2 seconds while its tab is open.
# See docs/PLUGINS.md for the protocol.
active=0
parent=$PPID
cores=$(sysctl -n hw.ncpu)
total=$(sysctl -n hw.memsize)

render() {
  # Sum of every process's CPU share, spread over the cores (ps is instant, unlike top's two samples).
  cpu=$(ps -A -o %cpu | awk -v n="$cores" 'NR>1 {s+=$1} END {v=s/n; if (v>100) v=100; printf "%.0f", v}')
  # Memory in use = active + wired + compressed pages.
  mem=$(vm_stat | awk -v total="$total" '
    /page size of/ {ps=$8}
    /Pages active/ {a=$3} /Pages wired down/ {w=$4} /occupied by compressor/ {c=$5}
    END {gsub("\\.","",a); gsub("\\.","",w); gsub("\\.","",c); printf "%.3f %.1f", (a+w+c)*ps/total, (a+w+c)*ps/1073741824}')
  frac=${mem% *}; gb=${mem#* }
  total_gb=$(awk -v t="$total" 'BEGIN {printf "%.0f", t/1073741824}')
  printf '{"type":"render","root":{"type":"vstack","spacing":8,"children":[{"type":"progress","value":%s,"label":"CPU %s%%"},{"type":"progress","value":%s,"label":"RAM %s / %s GB"}]}}\n' \
    "$(awk -v c="$cpu" 'BEGIN {printf "%.2f", c/100}')" "$cpu" "$frac" "$gb" "$total_gb"
}

render
while true; do
  if IFS= read -r -t 2 line; then
    case "$line" in
      *'"type":"activate"'*) active=1; render ;;
      *'"type":"deactivate"'*) active=0 ;;
    esac
  else
    kill -0 "$parent" 2>/dev/null || exit 0   # Cove is gone
    [ "$active" = 1 ] && render
  fi
done
