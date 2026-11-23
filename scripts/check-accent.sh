#!/bin/zsh
# Fails when code reaches for the system accent colour (blue), which ignores the user's own accent. Use Color.effectiveAccent /
# NSColor.effectiveAccent, and put .coveAccent() on the root of every new window or panel (see Color+AccentColor.swift).
cd "$(dirname "$0")/.." || exit 1
bad=$(grep -rnE 'controlAccentColor|Color\.accentColor|NSColor\.selectedContentBackgroundColor|alternateSelectedControlColor|selectedMenuItemColor' boringNotch Packages --include='*.swift' | grep -v 'Color+AccentColor.swift' | grep -v 'Packages/AgentHub.*Color\.accentColor' | grep -v '/Tests/')
if [[ -n $bad ]]; then echo "System accent colour used:"; echo "$bad"; exit 1; fi
roots=$(grep -rnE 'NSHostingController\(rootView|NSHostingView\(rootView' boringNotch --include='*.swift' | grep -v UISnapshot | grep -v coveAccent | grep -v 'NotchHostingView')
if [[ -n $roots ]]; then echo "Window root without .coveAccent():"; echo "$roots"; exit 1; fi
echo "accent check ok"
