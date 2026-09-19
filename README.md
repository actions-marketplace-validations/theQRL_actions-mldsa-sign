# actions-mldsa-sign

GitHub Action to generate ML-DSA-87 (FIPS 204) post-quantum signatures for files,
and a signed manifest binding each artifact to the release it belongs to.

This action supersedes [actions-dilithium-sign](https://github.com/theQRL/actions-dilithium-sign), which is deprecated. See [Migrating from actions-dilithium-sign](#migrating-from-actions-dilithium-sign) below.

## Usage

```yaml
- uses: theQRL/actions-mldsa-sign@v2
  with:
    patterns: |
      dist/*.zip
      dist/*.tar.gz
    hexseed: ${{ secrets.MLDSA_HEXSEED }}
    context: my-app-release-signatures
    output: signatures.txt
```

This writes three files: `signatures.txt` as before, plus `manifest.json` and
`manifest.json.sig`. Upload all three to the release.

## The manifest

A signature covers a file's bytes and a context string. It does not cover the
filename, so it establishes that the key holder produced these bytes for this
product, and nothing about which release they belong to.

The manifest supplies that. It lists every artifact in the release with its
digest, names the product and tag, and is signed as a whole:

```json
{
  "schema": "theqrl.release-manifest.v1",
  "product": "my-app",
  "tag": "v1.2.0",
  "context": "my-app-release-signatures",
  "artifacts": [
    {
      "filename": "my-app_v1.2.0_linux_amd64.zip",
      "size": 1898273,
      "sha256": "bb5de924a2f4f17f392f17d602d50a6d9038220891670664e46801d8b02f5089"
    }
  ]
}
```

A verifier hashes the file, finds that digest in the manifest, and checks the
manifest's signature. The lookup is by digest, so the filename is an output
rather than an input.

It is signed under `<product>-release-manifest`, never the artifact context.
FIPS 204 mixes the context into the message, so neither signature can be
presented as the other. The action refuses to run if the two are equal.

Artifacts are sorted by filename and the formatting is fixed, so the manifest is
byte-reproducible from the release.

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `hexseed` | ML-DSA hexseed for signing | Yes | - |
| `context` | Context string for domain separation (0-255 bytes) | Yes | - |
| `patterns` | Glob patterns for files to sign (one per line) | Yes | - |
| `output` | Output file path for signatures | No | `signatures.txt` |
| `product` | Product name recorded in the manifest, and the stem of its context | No | `context` minus `-release-signatures` |
| `tag` | Release tag recorded in the manifest | No | `github.ref_name` |
| `manifest` | Output path for the signed manifest. Empty string signs artifacts only | No | `manifest.json` |
| `manifest-context` | Context for the manifest signature. Must differ from `context` | No | `<product>-release-manifest` |

### Determining the product

The product picks the manifest's context, so the action will not guess it. It is
derived from `context` where that follows the `<product>-release-signatures`
convention. Otherwise set `product`, or set `manifest: ''` to opt out; the
action fails rather than inventing one.

## Context Parameter

ML-DSA-87 (FIPS 204) requires a context string for domain separation. This
ensures signatures created for one purpose cannot be reused for another.

- Name it `<product>-release-signatures`. The action reads the product from that
  to derive the manifest's context, so following the convention means there is
  nothing else to configure. Any other shape needs `product` set explicitly.
- The same context must be used for both signing and verification, forever
- Context can be 0-255 bytes

Two contexts are in play per product, and they must never be the same string:
`<product>-release-signatures` for the artifacts, `<product>-release-manifest`
for the manifest.

## Outputs

`signatures.txt`, one line per signed file, signature first:

```
3b4e5f...signature_hex... filename1.zip
7a8b9c...signature_hex... filename2.tar.gz
```

`manifest.json`, as described above, and `manifest.json.sig`, a hex signature
over that file's exact bytes. Publish all three: the signatures file checks each
artifact on its own, the manifest establishes which release it belongs to.

## Example: Sign release artifacts

```yaml
name: Release

on:
  push:
    tags:
      - 'v*'

jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4

      - name: Build
        run: make build

      - name: Sign artifacts with ML-DSA
        uses: theQRL/actions-mldsa-sign@v2
        with:
          patterns: |
            dist/*.zip
          hexseed: ${{ secrets.MLDSA_HEXSEED }}
          context: myapp-release-signatures
          # Naming the outputs for the release is worth doing: they are published
          # side by side with every other release's, and a bare manifest.json
          # collides the moment anyone downloads two of them.
          output: myapp_${{ github.ref_name }}_signatures.txt
          manifest: myapp_${{ github.ref_name }}_manifest.json

      - name: Upload signatures and manifest to release
        uses: softprops/action-gh-release@v1
        with:
          files: |
            myapp_${{ github.ref_name }}_signatures.txt
            myapp_${{ github.ref_name }}_manifest.json
            myapp_${{ github.ref_name }}_manifest.json.sig
```

## Generating a hexseed

Use [qrlft](https://github.com/theQRL/qrlft) to generate a new ML-DSA keypair:

```bash
qrlft new -a mldsa --context="my-app-release-signatures" mykey
```

This creates:
- `mykey` - Private key (PEM format)
- `mykey.pub` - Public key (PEM format)
- `mykey.private.hexseed` - Hexseed for use with this action

Store the hexseed as a GitHub secret (`MLDSA_HEXSEED`).

## Verifying

An artifact, which establishes that the key holder signed those bytes:

```bash
qrlft verify -a mldsa --context="my-app-release-signatures" \
  --signature=<sig_hex> --pkfile=my-app.pub file.zip
```

The manifest, which additionally establishes which release the bytes are:

```bash
qrlft verify -a mldsa --context="my-app-release-manifest" \
  --sigfile=manifest.json.sig --pkfile=my-app.pub manifest.json

# then confirm your file is the one the manifest names
sha256sum file.zip
jq -r '.artifacts[] | select(.filename == "file.zip") | .sha256' manifest.json
```

The second check establishes the release; the first only establishes the
bytes.

## Signing a manifest for an older release

A manifest can be produced after the fact, so a release published before v2 can
be given one without rebuilding or re-tagging:

```bash
QRLFT=/path/to/qrlft ./backfill-manifest.sh "$MLDSA_HEXSEED" qrlft v4.0.3
```

`QRLFT` points at a qrlft binary; inside the action's image it is already
`/qrlft/qrlft` and can be left unset. `jq` and `curl` are needed too. A fourth
argument overrides the repository, which defaults to `theQRL/<product>`.

This downloads the release's artifacts, hashes them, cross-checks each digest
against the one the release page publishes, and writes
`qrlft_v4.0.3_manifest.json` and its `.sig`. Upload both to the existing release
as additional assets.

Digests are computed locally rather than taken from the release page. A release
whose served bytes disagree with its published digests is refused.

## Upgrading from v1

v1 wrote only a signatures file. v2 adds a signed manifest, so for most
workflows the only change is uploading the two extra files to the release.

One case fails where v1 would not: a `context` not ending in
`-release-signatures` leaves the product underivable and the action stops. Set
`product`, or `manifest: ''` for v1 behaviour.

## Testing

`./test/run.sh` signs a fixture release with a real qrlft and checks the context
separation, the refusals, and a byte-identical rebuild.

It builds the qrlft commit the Dockerfile pins, so it needs Go and `jq`; set
`QRLFT` to use an existing binary instead. CI runs it on every push.

## Migrating from actions-dilithium-sign

Three changes when switching a workflow from `actions-dilithium-sign@v2`:

1. `uses: theQRL/actions-mldsa-sign@v2` (or pin the commit SHA)
2. Add the new required `context` input and pick a stable, application-specific value — verifiers must use the same string forever after
3. The `hexseed` secret must be a **fresh ML-DSA hexseed** (generate one as below). Dilithium and ML-DSA-87 seeds are both 32 bytes, so an old Dilithium hexseed is accepted and expanded into a different ML-DSA key, producing signatures that fail against the published public key. Generate a new keypair and publish its public key

`patterns` and `output` are unchanged, and the signatures file format is the same.

## ML-DSA vs Dilithium

| Feature | ML-DSA-87 | Dilithium |
|---------|-----------|-----------|
| Standard | FIPS 204 | Pre-FIPS |
| Context | Required | Not supported |
| Use case | New applications | Legacy compatibility |

For new projects, ML-DSA-87 is recommended as it follows the FIPS 204 standard.

## Releasing

Cutting a version of this action is documented in [RELEASE.md](RELEASE.md).

## License

MIT
