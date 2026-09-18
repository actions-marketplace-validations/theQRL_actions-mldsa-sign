#!/bin/bash
#
# End-to-end test for the action, run against a real qrlft rather than a stub.
#
# The properties under test are the ones the manifest exists for: that it is
# signed under a context of its own, that the signature actually rejects the
# things it is supposed to, and that the same release always produces the same
# bytes. A manifest nobody can reproduce is a manifest nobody can audit.
#
# Set QRLFT to an existing binary, or let this build the pinned one.

set -e
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

ok() { pass=$((pass + 1)); echo "  ok    $1"; }
no() { fail=$((fail + 1)); echo "  FAIL  $1"; }
check() { if [ "$1" = "yes" ]; then ok "$2"; else no "$2"; fi; }

# Fails when the command succeeds, which is what most of these assert.
refuses() {
  local why="$1"; shift
  if "$@" > "$WORK/out" 2>&1; then no "$why (it was accepted)"; else ok "$why"; fi
}

if [ -z "$QRLFT" ]; then
  COMMIT="$(grep -oE 'ARG QRLFT_COMMIT=[0-9a-f]+' "$ROOT/Dockerfile" | cut -d= -f2)"
  echo "building qrlft $COMMIT"
  curl -sL "https://github.com/theQRL/qrlft/archive/${COMMIT}.tar.gz" | tar xz -C "$WORK"
  (cd "$WORK"/qrlft-* && CGO_ENABLED=0 go build -o "$WORK/qrlft" .)
  QRLFT="$WORK/qrlft"
fi
export QRLFT

cd "$WORK"
mkdir -p dist
printf 'linux payload'   > dist/testapp_v1.0.0_linux_amd64.zip
printf 'windows payload' > dist/testapp_v1.0.0_windows_amd64.zip

"$QRLFT" new -a mldsa --context="testapp-release-signatures" key > /dev/null
SEED="$(sed -n 2p key.private.hexseed | sed 's/^0x//')"

echo
echo "signing"
"$ROOT/entrypoint.sh" "$SEED" "testapp-release-signatures" "signatures.txt" "dist/*.zip" \
  "" "v1.0.0" "manifest.json" "" > /dev/null

echo
echo "the manifest"
[ -s manifest.json ] && ok "a manifest was written" || no "a manifest was written"
[ -s manifest.json.sig ] && ok "a detached signature was written" || no "a detached signature was written"

check "$([ "$(jq -r .product < manifest.json)" = "testapp" ] && echo yes)" "records the product"
check "$([ "$(jq -r .tag < manifest.json)" = "v1.0.0" ] && echo yes)" "records the tag"
check "$([ "$(jq '.artifacts | length' < manifest.json)" = "2" ] && echo yes)" "records every artifact"
check "$([ "$(jq -r '.artifacts[0].filename' < manifest.json)" = "testapp_v1.0.0_linux_amd64.zip" ] && echo yes)" \
  "records release asset names, not paths"

DIGEST="$(jq -r '.artifacts[] | select(.filename == "testapp_v1.0.0_linux_amd64.zip") | .sha256' < manifest.json)"
ACTUAL="$(sha256sum dist/testapp_v1.0.0_linux_amd64.zip 2>/dev/null | cut -d' ' -f1 || shasum -a 256 dist/testapp_v1.0.0_linux_amd64.zip | cut -d' ' -f1)"
check "$([ "$DIGEST" = "$ACTUAL" ] && echo yes)" "records the digest the file actually has"

echo
echo "the signature"
if "$QRLFT" verify -a mldsa --context="testapp-release-manifest" \
     --sigfile=manifest.json.sig --pkfile=key.pub manifest.json > /dev/null 2>&1; then
  ok "verifies under the manifest context"
else
  no "verifies under the manifest context"
fi

refuses "rejects the artifact context, so the two domains cannot be confused" \
  "$QRLFT" verify -a mldsa --context="testapp-release-signatures" \
    --sigfile=manifest.json.sig --pkfile=key.pub manifest.json

# Only the version is altered; every digest in it stays genuine. This is the
# forgery the manifest exists to stop, so it is the one that matters most.
sed 's/"v1.0.0"/"v99.0.0"/' manifest.json > tampered.json
refuses "rejects a manifest with only the tag changed" \
  "$QRLFT" verify -a mldsa --context="testapp-release-manifest" \
    --sigfile=manifest.json.sig --pkfile=key.pub tampered.json

echo
echo "reproducibility"
cp manifest.json before.json
"$ROOT/entrypoint.sh" "$SEED" "testapp-release-signatures" "signatures.txt" "dist/*.zip" \
  "" "v1.0.0" "manifest.json" "" > /dev/null
check "$(cmp -s before.json manifest.json && echo yes)" "the same release rebuilds byte for byte"

echo
echo "refusals"
refuses "will not guess a product from an unrecognised context" \
  "$ROOT/entrypoint.sh" "$SEED" "custom-ctx" "s.txt" "dist/*.zip" "" "v1" "manifest.json" ""

refuses "will not sign a manifest in the artifact context" \
  "$ROOT/entrypoint.sh" "$SEED" "testapp-release-signatures" "s.txt" "dist/*.zip" "" "v1" \
    "manifest.json" "testapp-release-signatures"

mkdir -p other && cp dist/testapp_v1.0.0_linux_amd64.zip other/
refuses "will not give one asset name two meanings" \
  "$ROOT/entrypoint.sh" "$SEED" "testapp-release-signatures" "s.txt" "dist/*.zip other/*.zip" \
    "" "v1" "manifest.json" ""

echo
echo "opting out"
rm -f manifest.json
"$ROOT/entrypoint.sh" "$SEED" "anything" "s.txt" "dist/*.zip" "" "" "" "" > /dev/null 2>&1
check "$([ ! -f manifest.json ] && [ -s s.txt ] && echo yes)" "an empty manifest input signs artifacts only"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
