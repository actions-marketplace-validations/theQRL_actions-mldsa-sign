# actions-mldsa-sign

GitHub Action to generate ML-DSA-87 (FIPS 204) post-quantum signatures for files,
and a signed manifest binding each artifact to the release it belongs to.

This action supersedes [actions-dilithium-sign](https://github.com/theQRL/actions-dilithium-sign), which is deprecated. See [Migrating from actions-dilithium-sign](#migrating-from-actions-dilithium-sign) below.

## Usage

```yaml
- uses: theQRL/actions-mldsa-sign@v1
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

## Why there is a manifest

A signature covers a file's bytes and a context string. It does not cover the
filename, so it proves the key holder produced these bytes for this product —
and nothing about *which release they are*.

That gap is exploitable. Take a correctly signed archive from an old release
with a known flaw, present it under a current release's filename, and a verifier
checking signatures alone accepts it. Nothing cryptographic fails, because the
bytes really were signed. What is false is the identity, and the identity is
exactly what the signature omits.

The manifest is the missing statement. It lists every artifact in the release
with its digest, names the product and tag, and is signed as a whole:

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

A verifier hashes the file in front of it, finds that digest in the manifest,
and checks the manifest's signature. Renaming the file changes nothing, because
the digest does the looking up and the name is what the manifest returns.

It is signed under a context of its own, `<product>-release-manifest`, never the
one used for artifacts. FIPS 204 mixes the context into the message, so a
manifest signature cannot be presented as an artifact signature or the reverse.
The action refuses to run if the two contexts are equal.

The manifest is byte-reproducible: artifacts are sorted by filename and the
formatting is fixed, so anyone can rebuild it from the release and check it
against the published signature.

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

The product names the release and picks the manifest's context, so the action
will not guess it. Where `context` follows the `<product>-release-signatures`
convention it is derived from there. Where it does not, set `product` explicitly
or set `manifest: ''` to opt out — the action fails rather than inventing one.

## Context Parameter

ML-DSA-87 (FIPS 204) requires a context string for domain separation. This ensures signatures created for one purpose cannot be reused for another.

- Use a unique, application-specific context (e.g., `myapp-releases-v1`)
- The same context must be used for both signing and verification
- Context can be 0-255 bytes

## Outputs

`signatures.txt`, one line per signed file, signature first:

```
3b4e5f...signature_hex... filename1.zip
7a8b9c...signature_hex... filename2.tar.gz
```

`manifest.json`, the release's contents as described above, and
`manifest.json.sig`, a hex signature over that file's exact bytes. Publish all
three: the signatures file lets each artifact be checked on its own, and the
manifest is what establishes which release an artifact belongs to.

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
        uses: theQRL/actions-mldsa-sign@v1
        with:
          patterns: |
            dist/*.zip
          hexseed: ${{ secrets.MLDSA_HEXSEED }}
          context: myapp-release-signatures
          output: signatures.txt

      - name: Upload signatures and manifest to release
        uses: softprops/action-gh-release@v1
        with:
          files: |
            signatures.txt
            manifest.json
            manifest.json.sig
```

## Generating a hexseed

Use [qrlft](https://github.com/theQRL/qrlft) to generate a new ML-DSA keypair:

```bash
qrlft new -a mldsa --context="my-app-releases" mykey
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

The second check is the stronger one, and it is the one that catches an old
build wearing a new build's name.

## Upgrading from v1

v1 wrote only a signatures file. v2 writes a signed manifest as well, which is a
new output and, for most workflows, the only change needed is uploading the two
extra files to the release.

It can fail where v1 would not, in one case: if `context` does not end in
`-release-signatures`, the action cannot tell what the product is and stops. Set
`product`, or set `manifest: ''` to keep v1's behaviour exactly.

## Testing

`./test/run.sh` signs a fixture release with a real qrlft and checks the
properties the manifest exists for — the context separation, the refusals, and
that a rebuild is byte-identical. It builds the qrlft commit the Dockerfile pins,
or uses `QRLFT` if set.

## Migrating from actions-dilithium-sign

Three changes when switching a workflow from `actions-dilithium-sign@v2`:

1. `uses: theQRL/actions-mldsa-sign@v1` (or pin the commit SHA)
2. Add the new required `context` input and pick a stable, application-specific value — verifiers must use the same string forever after
3. The `hexseed` secret must be a **fresh ML-DSA hexseed** (generate one as below). Dilithium and ML-DSA-87 seeds are both 32 bytes (64 hex characters), so reusing an old Dilithium hexseed is *not* rejected — it is silently expanded into a different ML-DSA key, producing signatures that fail against whichever public key you published. Generate a new keypair and publish its public key

`patterns` and `output` are unchanged, and the signatures file format is the same.

## ML-DSA vs Dilithium

| Feature | ML-DSA-87 | Dilithium |
|---------|-----------|-----------|
| Standard | FIPS 204 | Pre-FIPS |
| Context | Required | Not supported |
| Use case | New applications | Legacy compatibility |

For new projects, ML-DSA-87 is recommended as it follows the FIPS 204 standard.

## License

MIT
