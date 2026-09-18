#!/bin/bash

set -e
set -o pipefail

HEXSEED="$1"
CONTEXT="$2"
OUTPUT="$3"
PATTERNS="$4"
PRODUCT="$5"
TAG="$6"
MANIFEST="$7"
MANIFEST_CONTEXT="$8"

QRLFT="${QRLFT:-/qrlft/qrlft}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# Unquoted on purpose: the patterns input is a list of globs, and this is where
# they expand. Long-standing behaviour, kept as it is.
# shellcheck disable=SC2086
"$QRLFT" sign -a mldsa --hexseed "$HEXSEED" --context "$CONTEXT" $PATTERNS > "$OUTPUT"

if [ -z "$MANIFEST" ]; then
  echo "entrypoint: manifest disabled, wrote signatures only" >&2
  exit 0
fi

# The product names the release and picks the manifest's context, so it has to
# be right. Where the artifact context follows the house convention it is
# already stated, and deriving it keeps the two from drifting apart. Where it
# does not, guessing would be worse than stopping.
if [ -z "$PRODUCT" ]; then
  case "$CONTEXT" in
    *-release-signatures) PRODUCT="${CONTEXT%-release-signatures}" ;;
    *)
      echo "entrypoint: cannot tell which product this is." >&2
      echo "  The context '$CONTEXT' does not end in '-release-signatures', so set the" >&2
      echo "  'product' input explicitly, or set 'manifest' to '' to sign artifacts only." >&2
      exit 1
      ;;
  esac
fi

if [ -z "$TAG" ]; then
  TAG="${GITHUB_REF_NAME:-}"
  if [ -z "$TAG" ]; then
    echo "entrypoint: cannot tell which release this is. Set the 'tag' input." >&2
    exit 1
  fi
fi

# Its own domain. A manifest signature must never be mistakable for an artifact
# signature, and FIPS 204 gives that for free as long as the contexts differ.
if [ -z "$MANIFEST_CONTEXT" ]; then
  MANIFEST_CONTEXT="${PRODUCT}-release-manifest"
fi

if [ "$MANIFEST_CONTEXT" = "$CONTEXT" ]; then
  echo "entrypoint: the manifest context and the artifact context are both" >&2
  echo "  '$CONTEXT'. They must differ, or a signature over one could be" >&2
  echo "  presented as a signature over the other." >&2
  exit 1
fi

# The manifest covers the same files the signatures file does.
# shellcheck disable=SC2086
"$HERE/build-manifest.sh" \
  "$HEXSEED" "$MANIFEST_CONTEXT" "$CONTEXT" "$PRODUCT" "$TAG" "$MANIFEST" $PATTERNS
