#!/bin/bash
# Finds the bridge binary and execs it with the arguments the shell passed.
# A dev build in bridge/target wins, so a working copy tests its own code;
# otherwise the prebuilt binary for this machine's architecture is fetched
# once per plugin version from the plugin repository's GitHub releases —
# the repository named by manifest.json's homepage, so a fork downloads its
# own releases and not upstream's. A failed or bogus download falls back to
# the binary a previous version already cached: a stale minimap beats none.
# Failures are reported on stdout in the bridge's own error shape and on
# stderr for the omarchy-shell journal.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
args=("$@")

fail() {
  local msg=${1//\\/\\\\}
  msg=${msg//\"/\\\"}
  printf '{"type":"error","message":"%s"}\n' "$msg"
  echo "browser-minimap bridge.sh: $1" >&2
  exit 1
}

for candidate in \
  "${OMARCHY_BROWSER_MINIMAP_BRIDGE:-}" \
  "$here/bridge/target/release/omarchy-browser-minimap-bridge"; do
  [[ -n $candidate && -x $candidate ]] && exec "$candidate" "${args[@]}"
done

manifest_field() {
  sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$here/manifest.json" | head -n1
}

version="$(manifest_field version)"
[[ -n $version ]] || fail "cannot read version from manifest.json"
repo="$(manifest_field homepage)"
[[ -n $repo ]] || fail "cannot read homepage from manifest.json"

arch="$(uname -m)"
case "$arch" in
  x86_64 | aarch64) ;;
  *) fail "no prebuilt bridge for $arch; build one with cargo build --release --manifest-path $here/bridge/Cargo.toml" ;;
esac

cache="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-browser-minimap"
bin="$cache/bridge-$version-$arch"

# The newest binary an earlier version already cached. Only exact misses fall
# through to it — a cached copy of the *current* version is always preferred.
fallback() {
  local previous
  previous="$(ls -t "$cache"/bridge-*-"$arch" 2>/dev/null | head -n1 || true)"
  if [[ -n $previous && -x $previous ]]; then
    echo "browser-minimap bridge.sh: $1; falling back to cached $(basename "$previous")" >&2
    exec "$previous" "${args[@]}"
  fi
  fail "$1"
}

if [[ ! -x $bin ]]; then
  mkdir -p "$cache"
  url="${repo%/}/releases/download/v$version/omarchy-browser-minimap-bridge-$arch"
  tmp="$bin.part.$$"
  curl -fsSL --retry 2 -o "$tmp" "$url" || { rm -f "$tmp"; fallback "downloading the bridge binary failed: $url"; }
  # A captive portal or intercepting proxy answers 200 with HTML; caching that
  # under the version-keyed name would poison every later start. ELF or bust.
  [[ "$(head -c 4 "$tmp" 2>/dev/null)" == $'\x7fELF' ]] || { rm -f "$tmp"; fallback "download from $url is not an executable"; }
  chmod +x "$tmp"
  mv "$tmp" "$bin"
  # Binaries from versions this install has moved past are dead weight.
  find "$cache" -maxdepth 1 -name 'bridge-*' ! -name "bridge-$version-*" -delete 2>/dev/null || true
fi

exec "$bin" "${args[@]}"
