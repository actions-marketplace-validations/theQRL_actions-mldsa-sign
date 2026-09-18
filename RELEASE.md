# Release Process

No semantic-release here, unlike [qrlft](https://github.com/theQRL/qrlft).
Releases are cut by hand: a release is a git tag plus a container image that
`action.yml` pins by exact version, and nothing derives one from the other.

## What ships

| Artefact | Produced by | Referenced by |
|---|---|---|
| Tag `vX.Y.Z` | `git push origin vX.Y.Z` | Exact-version pins |
| Tag `vX` (floating) | Moved each release in that major | `uses: theQRL/actions-mldsa-sign@vX` |
| Image `ghcr.io/theqrl/actions-mldsa-sign:vX.Y.Z` | `ci.yml`, on the tag push | `action.yml`'s `image:` |

`action.yml` pins the image by exact version, never by floating tag, so the
image under a consumer cannot change without a tag moving.

## Versioning

Semver, judged by what a verifier has to change rather than what a workflow
author would notice.

**Major** — anything that changes the bytes signed, the context they are signed
under, or an existing verification procedure:

- how the manifest context is derived from the product
- the manifest's schema, field names, sort order or formatting (a verifier that
  rebuilds and compares breaks; signatures already issued stay valid)
- an optional input becoming required
- bumping the pinned qrlft

**Minor** — new optional inputs or outputs.

**Patch** — fixes that change no output for any input that previously succeeded.

The manifest carries `schema`, currently `theqrl.release-manifest.v1`. A shape
change means a new schema string and a major version.

## Pre-flight

```bash
./test/run.sh
```

15 assertions against a real qrlft: context separation, the refusals, and a
byte-identical rebuild. Needs Go and `jq`; set `QRLFT` to reuse a binary.

Then the image, which `test/run.sh` does not cover:

```bash
docker build -t mldsa-sign:test .

WORK=$(mktemp -d) && cd "$WORK" && mkdir dist
printf 'payload' > dist/testapp_v1.0.0_linux_amd64.zip
docker run --rm -v "$PWD:/w" -w /w --entrypoint /qrlft/qrlft mldsa-sign:test \
  new -a mldsa --context="testapp-release-signatures" key
SEED=$(sed -n 2p key.private.hexseed | sed 's/^0x//')

docker run --rm -v "$PWD:/w" -w /w mldsa-sign:test \
  "$SEED" testapp-release-signatures signatures.txt 'dist/*.zip' '' v1.0.0 manifest.json ''

jq -r '.product, .tag' manifest.json   # testapp / v1.0.0
cd - && rm -rf "$WORK"
```

`jq: not found` means the image's apt layer did not take.

## Cutting a release

```bash
git checkout main && git pull
git tag -a v2.0.0 -m "v2.0.0 — signed release manifests"
git push origin v2.0.0
```

`ci.yml` runs on the tag push, gated on `refs/tags/v`.
`docker/metadata-action` emits `type=ref,event=tag`, so the image lands as
`:v2.0.0`, matching `action.yml`.

Confirm it exists:

```bash
gh run list --repo theQRL/actions-mldsa-sign --limit 3
docker pull ghcr.io/theqrl/actions-mldsa-sign:v2.0.0
```

Then move the floating tag:

```bash
git tag -f v2 v2.0.0
git push -f origin v2
```

Order matters: `@v2` resolves to an `action.yml` naming an exact image, so
moving `v2` first points consumers at an image that is not there yet.

### If no run appears

`ci.yml` has `paths-ignore` for `**.md`, `**.toml` and `.vscode/**`, which can
suppress a tag push:

```bash
gh workflow run "Manual Push" --repo theQRL/actions-mldsa-sign -f tag=v2.0.0
```

Same image, no path filtering.

## Bumping the pinned qrlft

`Dockerfile` pins `ARG QRLFT_COMMIT` to a release commit; an unpinned clone
would track `main` and change behaviour with no version signal. Bumping is a
major release.

1. Confirm `sign -a mldsa` emits 4627-byte signatures (ML-DSA-87) and not
   4595-byte (Dilithium5). Public key sizes are identical, so length is the only
   distinguishing signal.
2. `./test/run.sh` — 15/15.
3. Verify a signature from the new qrlft against a public key written by the
   old one, so a key-derivation change cannot pass as a green test.

qrlft has supported `-a mldsa` since v4.0.0.

## Contexts and keys

Two contexts per product, never the same string:

| Purpose | Context |
|---|---|
| Artifact signatures | `<product>-release-signatures` |
| Release manifest | `<product>-release-manifest` |

FIPS 204 mixes the context into the message. The action refuses to run if the
two are equal. Changing either derivation rule is a major release.

The action holds no key material: the hexseed is an input and lives only for the
life of the container, so cutting a release never touches a signing key. Key
rotation belongs in each product's own RELEASE.md.

## After a release

Consumers need two changes:

1. `uses: theQRL/actions-mldsa-sign@v2`
2. Upload the manifest and its `.sig` alongside the signatures file

Without the second, nothing downstream can use the manifest.

## Rolling back

```bash
git push --delete origin v2.0.1
git tag -d v2.0.1
git tag -f v2 v2.0.0 && git push -f origin v2
```

Leave the published image. Deleting it breaks exact-version pins.
