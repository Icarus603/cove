#!/bin/sh
# Example Cove plugin: draws the time while its tab is open. See docs/PLUGINS.md for the protocol.
active=0
render() {
  now=$(date '+%H:%M:%S')
  printf '{"type":"render","root":{"type":"vstack","spacing":4,"children":[{"type":"text","text":"%s","style":"title"},{"type":"text","text":"%s","style":"caption","color":"secondary"}]}}\n' "$now" "$(date '+%Y-%m-%d')"
}
render
while true; do
  if IFS= read -r -t 1 line; then
    case "$line" in
      *'"type":"activate"'*) active=1; render ;;
      *'"type":"deactivate"'*) active=0 ;;
    esac
  else
    [ "$active" = 1 ] && render
  fi
done
