#!/bin/bash
#
# Signs a manifest for a release that was published before manifests existed.
#
# A manifest does not have to be made at release time. It is a statement about
# which bytes belong to which release, and that is just as true afterwards — so
# a past release can be given one without rebuilding or re-tagging anything. The
# two files are uploaded to the existing release as additional assets.
#
# The artifacts are downloaded and hashed here rather than taking the digests
# from the release page, because this signs a statement about them. Signing a
# digest you have not computed is attesting to something you did not check. The
# published digest is compared as well, so a mismatch between what the release
# page says and what it serves is caught rather than signed over.
#
# Usage: backfill-manifest.sh <hexseed> <product> <tag> [repo]

set -e
set -o pipefail

HEXSEED="$1"; PRODUCT="$2"; TAG="$3"; REPO="${4:-theQRL/$PRODUCT}"
HERE="$(cd "$(dirname "$0")" && pwd)"
QRLFT="${QRLFT:-/qrlft/qrlft}"

if [ -z "$HEXSEED" ] || [ -z "$PRODUCT" ] || [ -z "$TAG" ]; then
  echo "usage: backfill-manifest.sh <hexseed> <product> <tag> [owner/repo]" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

auth=()
[ -n "$GITHUB_TOKEN" ] && auth=(-H "authorization: Bearer $GITHUB_TOKEN")

echo "reading $REPO $TAG"
curl -sfL "${auth[@]}" -H 'accept: application/vnd.github+json' \
  "https://api.github.com/repos/$REPO/releases/tags/$TAG" > "$WORK/release.json" \
  || { echo "backfill: no release $TAG in $REPO" >&2; exit 1; }

# Everything except the metadata files, which describe the release rather than
# being part of it.
jq -r '.assets[]
       | select(.name | test("_(signatures|checksums)\\.txt$|^manifest\\.json(\\.sig)?$") | not)
       | [.name, .browser_download_url, (.digest // "")] | @tsv' \
  < "$WORK/release.json" > "$WORK/assets.tsv"

if [ ! -s "$WORK/assets.tsv" ]; then
  echo "backfill: $REPO $TAG has no artifacts to sign" >&2
  exit 1
fi

mkdir -p "$WORK/dist"
count=0
while IFS=$'\t' read -r name url published; do
  echo "  fetching $name"
  curl -sfL -o "$WORK/dist/$name" "$url"

  actual="$(sha256sum "$WORK/dist/$name" 2>/dev/null | cut -d' ' -f1 \
    || shasum -a 256 "$WORK/dist/$name" | cut -d' ' -f1)"

  # Only a cross-check. The digest that gets signed is the one computed above.
  if [ -n "$published" ] && [ "${published#sha256:}" != "$actual" ]; then
    echo "backfill: $name hashes to $actual but the release page publishes ${published#sha256:}" >&2
    echo "  Refusing to sign a manifest over a release that does not agree with itself." >&2
    exit 1
  fi
  count=$((count + 1))
done < "$WORK/assets.tsv"

echo "hashed $count artifacts"

QRLFT="$QRLFT" "$HERE/build-manifest.sh" \
  "$HEXSEED" "${PRODUCT}-release-manifest" "${PRODUCT}-release-signatures" \
  "$PRODUCT" "$TAG" "${PRODUCT}_${TAG}_manifest.json" "$WORK"/dist/*

echo
echo "wrote ${PRODUCT}_${TAG}_manifest.json and ${PRODUCT}_${TAG}_manifest.json.sig"
echo "upload both to the $TAG release, then commit them to validate's signatures/$PRODUCT/"
