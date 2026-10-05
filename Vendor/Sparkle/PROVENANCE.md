# Sparkle Vendoring Provenance

RepoPrompt CE vendors the Sparkle `2.9.2` Swift Package Manager distribution from the upstream Sparkle GitHub release:

- Release: `https://github.com/sparkle-project/Sparkle/releases/tag/2.9.2`
- Asset: `Sparkle-for-Swift-Package-Manager.zip`
- Download URL: `https://github.com/sparkle-project/Sparkle/releases/download/2.9.2/Sparkle-for-Swift-Package-Manager.zip`
- SHA-256: `b83e37436774556ed055e0244b297ef2c790e0737393bf65bf495fcbba6eed65`

Vendored contents:

- `Sparkle.xcframework`
- `bin/BinaryDelta`
- `bin/generate_appcast`
- `bin/generate_keys`
- `bin/sign_update`
- `LICENSE`

The vendored binaries are copied without source modification from the upstream release asset.

The checkout omits upstream debug-symbol bundles. The outer
`Sparkle.xcframework/Info.plist` therefore removes the upstream
`DebugSymbolsPath = dSYMs` declaration so build tools do not require an absent
path. Preserve this metadata adjustment when refreshing the vendored package
unless the matching symbol bundles are also included. No framework binary or
embedded framework metadata is changed; `SHA256SUMS` remains the checksum of the
original upstream archive.

[`INSTALLED_MANIFEST.tsv`](INSTALLED_MANIFEST.tsv) records the complete installed
framework and trusted command-line tool tree, including entry types, symlink
targets, and SHA-256 checksums for regular files. Release preflight verifies that
closed-world manifest before building.
