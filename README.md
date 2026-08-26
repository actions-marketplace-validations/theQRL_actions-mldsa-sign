# actions-mldsa-sign

GitHub Action to generate ML-DSA-87 (FIPS 204) post-quantum signatures for files.

This action supersedes [actions-dilithium-sign](https://github.com/theQRL/actions-dilithium-sign), which is deprecated. See [Migrating from actions-dilithium-sign](#migrating-from-actions-dilithium-sign) below.

## Usage

```yaml
- uses: theQRL/actions-mldsa-sign@v1
  with:
    patterns: |
      dist/*.zip
      dist/*.tar.gz
    hexseed: ${{ secrets.MLDSA_HEXSEED }}
    context: my-app-releases
    output: signatures.txt
```

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `hexseed` | ML-DSA hexseed for signing | Yes | - |
| `context` | Context string for domain separation (0-255 bytes) | Yes | - |
| `patterns` | Glob patterns for files to sign (one per line) | Yes | - |
| `output` | Output file path for signatures | No | `signatures.txt` |

## Context Parameter

ML-DSA-87 (FIPS 204) requires a context string for domain separation. This ensures signatures created for one purpose cannot be reused for another.

- Use a unique, application-specific context (e.g., `myapp-releases-v1`)
- The same context must be used for both signing and verification
- Context can be 0-255 bytes

## Outputs

The action generates a signatures file containing one line per signed file, signature first:

```
3b4e5f...signature_hex... filename1.zip
7a8b9c...signature_hex... filename2.tar.gz
```

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
          context: myapp-github-releases
          output: signatures.txt

      - name: Upload signatures to release
        uses: softprops/action-gh-release@v1
        with:
          files: signatures.txt
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

## Verifying signatures

Use qrlft to verify signatures:

```bash
qrlft verify -a mldsa --context="my-app-releases" --signature=<sig_hex> --publickey=<pk_hex> file.zip
```

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
