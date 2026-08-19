#!/bin/bash
# Finds the bridge binary and execs it with the arguments the shell passed.
# A dev build in bridge/target wins, so a working copy tests its own code;
# otherwise the prebuilt binary for this machine's architecture is fetched
# once per plugin version from the plugin repository's GitHub releases —
# the repository named by manifest.json's homepage, so a fork downloads its
# own releases and not upstream's.
#
# A release asset is mutable, so being able to fetch it proves nothing about
# what it contains. Every download is therefore checked against the digest
# committed in bridge.sha256 and executed only on an exact match: the bytes
# that run are the bytes this commit names, whatever the network, the release
# or a compromised account later serves. A mismatch is fatal rather than
# something to work around — there is no fallback to a binary cached by an
# earlier version, since those bytes are not named by this commit either and
# silently downgrading on a failed fetch would hand the choice of which
# version runs to whoever can break the connection.
#
# The dev build and OMARCHY_BROWSER_MINIMAP_BRIDGE are deliberately exempt:
# both name a local path, and anyone who can write there or set the plugin's
# environment can already run code as this user.
#
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

command -v sha256sum >/dev/null || fail "sha256sum is required to verify the bridge binary"

asset="omarchy-browser-minimap-bridge-$arch"
want="$(sed -n 's/^\([0-9a-f]\{64\}\)[[:space:]][[:space:]]*'"$asset"'$/\1/p' "$here/bridge.sha256" | head -n1)"
[[ -n $want ]] || fail "bridge.sha256 names no digest for $asset"

digest_of() { sha256sum <"$1" | cut -d' ' -f1; }

# Keyed by digest rather than by version, so a re-tagged release or an edited
# bridge.sha256 can never be answered by a stale cache entry.
cache="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-browser-minimap"
bin="$cache/bridge-$arch-$want"

if [[ ! -x $bin || "$(digest_of "$bin")" != "$want" ]]; then
  rm -f "$bin"
  mkdir -p "$cache"
  url="${repo%/}/releases/download/v$version/$asset"
  tmp="$bin.part.$$"
  trap 'rm -f "$tmp"' EXIT
  curl -fsSL --retry 2 -o "$tmp" "$url" || fail "downloading the bridge binary failed: $url"
  got="$(digest_of "$tmp")"
  [[ $got == "$want" ]] || fail "refusing to run $url: it hashes to $got, but bridge.sha256 names $want"
  chmod +x "$tmp"
  mv "$tmp" "$bin"
  trap - EXIT
fi

# Anything this version does not name is dead weight.
find "$cache" -maxdepth 1 -name 'bridge-*' ! -name "bridge-$arch-$want" -delete 2>/dev/null || true

exec "$bin" "${args[@]}"
