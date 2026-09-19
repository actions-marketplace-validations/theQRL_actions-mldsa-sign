#!/bin/bash
#
# Builds and signs a release manifest.
#
# A per-artifact signature covers the artifact's bytes and a product context. It
# does not cover the filename, so it proves QRL produced these bytes for this
# product and nothing about which release they are. That gap is exploitable:
# take a correctly signed archive from an older release, present it under a
# current release's name, and a verifier checking signatures alone will accept
# it. The bytes are genuine; only the identity is a lie.
#
# The manifest closes that. It names every artifact in the release with its
# digest, and it is signed as a whole, so the binding between a set of bytes and
# the release it belongs to becomes something the release key attests to rather
# than something a filename asserts.
#
# It is signed under its own context. FIPS 204 mixes the context into the
# message, so a manifest signature cannot be presented as an artifact signature
# or the other way round, whatever the bytes happen to look like.
#
# Usage: build-manifest.sh <hexseed> <manifest-context> <artifact-context>
#                          <product> <tag> <out.json> <file>...

set -e
set -o pipefail

HEXSEED="$1"; MANIFEST_CONTEXT="$2"; ARTIFACT_CONTEXT="$3"
PRODUCT="$4"; TAG="$5"; OUT="$6"
shift 6

QRLFT="${QRLFT:-/qrlft/qrlft}"

# sha256sum in the image, shasum on a developer's machine. Same digest either
# way; only the command differs.
sha256_of() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

if [ "$#" -eq 0 ]; then
  echo "build-manifest: no files matched, refusing to sign an empty manifest" >&2
  exit 1
fi

# Artifacts are recorded under the names they are published as, which is what a
# verifier sees on the release page. Two files sharing a basename would give one
# asset name two meanings, so that is an error rather than a last-write-wins.
seen=""
entries=""
for file in "$@"; do
  [ -f "$file" ] || { echo "build-manifest: $file is not a file" >&2; exit 1; }

  name="$(basename "$file")"
  case " $seen " in
    *" $name "*) echo "build-manifest: two files are both published as $name" >&2; exit 1 ;;
  esac
  seen="$seen $name"

  entries="$entries$(jq -n \
    --arg filename "$name" \
    --arg sha256 "$(sha256_of "$file")" \
    --argjson size "$(wc -c < "$file" | tr -d ' ')" \
    '{filename: $filename, size: $size, sha256: $sha256}')"
done

# Sorted by filename and formatted by jq, so the same release always produces
# byte-identical bytes. A manifest anyone can rebuild is a manifest anyone can
# check against the signature.
printf '%s' "$entries" | jq -s \
  --arg product "$PRODUCT" \
  --arg tag "$TAG" \
  --arg context "$ARTIFACT_CONTEXT" \
  '{
     schema: "theqrl.release-manifest.v1",
     product: $product,
     tag: $tag,
     context: $context,
     artifacts: (. | sort_by(.filename))
   }' > "$OUT"

# The signature covers the file exactly as written, so a verifier hashes the
# bytes it received rather than reserialising and hoping the two agree.
"$QRLFT" sign -a mldsa --hexseed "$HEXSEED" --context "$MANIFEST_CONTEXT" "$OUT" \
  | cut -d' ' -f1 > "$OUT.sig"

echo "build-manifest: signed $(jq '.artifacts | length' < "$OUT") artifacts as $PRODUCT $TAG"
echo "build-manifest: manifest context $MANIFEST_CONTEXT"
