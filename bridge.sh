#!/bin/bash
# omarchy-shell inherits the Hyprland session PATH, which on a mise-managed box
# may not carry node. Probe the usual homes rather than assuming a system node.
set -euo pipefail

for candidate in \
  "$HOME/.local/share/mise/shims/node" \
  "$(command -v node 2>/dev/null || true)" \
  /usr/bin/node \
  /usr/local/bin/node; do
  [[ -n $candidate && -x $candidate ]] && exec "$candidate" "$@"
done

echo '{"type":"error","message":"no node runtime found"}'
exit 1
