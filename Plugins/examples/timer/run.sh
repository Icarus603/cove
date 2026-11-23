#!/bin/sh
# Example Cove plugin: a countdown timer. Buttons add minutes, start, pause and reset; the remaining time shows
# next to the closed notch while it runs, and the notch opens on this tab when it reaches zero.
# See docs/PLUGINS.md for the protocol.
parent=$PPID
set_secs=300       # what Reset goes back to
left=$set_secs
running=0
done_flag=0

fmt() { printf '%02d:%02d' $(($1 / 60)) $(($1 % 60)); }

render() {
  if [ "$running" = 1 ]; then toggle='{"type":"button","id":"pause","title":"Pause","symbol":"pause.fill"}'
  else toggle='{"type":"button","id":"start","title":"Start","symbol":"play.fill"}'; fi
  frac=$(awk -v l="$left" -v s="$set_secs" 'BEGIN {if (s<=0) s=1; v=l/s; if (v>1) v=1; printf "%.3f", v}')
  printf '{"type":"render","root":{"type":"vstack","spacing":8,"children":[{"type":"text","text":"%s","style":"title"},{"type":"progress","value":%s},{"type":"hstack","spacing":8,"children":[{"type":"button","id":"minus","title":"-1 min"},%s,{"type":"button","id":"plus","title":"+1 min"},{"type":"button","id":"reset","title":"Reset","symbol":"arrow.counterclockwise"}]}]}}\n' \
    "$(fmt $left)" "$frac" "$toggle"
  if [ "$running" = 1 ]; then
    printf '{"type":"accessory","symbol":"timer","text":"%s"}\n' "$(fmt $left)"
  else
    printf '{"type":"accessory","symbol":""}\n'
  fi
}

render
while true; do
  if IFS= read -r -t 1 line; then
    case "$line" in
      *'"id":"start"'*) [ "$left" -le 0 ] && left=$set_secs; running=1; done_flag=0 ;;
      *'"id":"pause"'*) running=0 ;;
      *'"id":"reset"'*) running=0; left=$set_secs; done_flag=0; printf '{"type":"attention","level":"none"}\n' ;;
      *'"id":"plus"'*)  set_secs=$((set_secs + 60)); [ "$running" = 0 ] && left=$set_secs || left=$((left + 60)) ;;
      *'"id":"minus"'*) [ "$set_secs" -gt 60 ] && set_secs=$((set_secs - 60)); [ "$running" = 0 ] && left=$set_secs || { left=$((left - 60)); [ "$left" -lt 1 ] && left=1; } ;;
      *) ;;
    esac
    render
  elif ! kill -0 "$parent" 2>/dev/null; then
    exit 0   # Cove is gone
  elif [ "$running" = 1 ]; then
    left=$((left - 1))
    if [ "$left" -le 0 ]; then
      left=0; running=0
      printf '{"type":"attention","level":"needsInput"}\n'
    fi
    render
  fi
done
