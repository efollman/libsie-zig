# libsie_jll build notes

This directory contains the [BinaryBuilder.jl](https://docs.binarybuilder.org/)
recipe used to package `libsie-z` as a Julia JLL (`libsie_jll`).

## Building the JLL

### Local single-platform build (no deploy)

This is the fastest way to confirm the recipe is healthy. Pass any one of
the platforms listed in `build_tarballs.jl` as a positional argument:

```bash
julia --project=. build_tarballs.jl --verbose --debug x86_64-linux-gnu
```

`--debug` drops you into a sandbox shell on failure so you can inspect the
build tree.

### Full multi-platform build + deploy

After tagging a release upstream and computing the tree hash:

```bash
# Resolve the commit SHA1 of the tag (despite the `tree_hash` name in the
# recipe, GitSource wants the commit hash, not the git tree hash):
git clone --bare --filter=blob:none \
    https://github.com/efollman/libsie-z.git /tmp/libsie-z.git
git -C /tmp/libsie-z.git rev-list -n 1 v0.2.0

# Then update LIBSIE_TREE_HASH (or the hard-coded value) and run:
BINARYBUILDER_AUTOMATIC_APPLE=true\
LIBSIE_VERSION=0.2.0 \
LIBSIE_TREE_HASH=<hash from above> \
julia --project=. build_tarballs.jl --verbose \
    --deploy="efollman/libsie_jll.jl"
```

This will:
1. Build the shared library for every platform listed in `platforms`.
2. Run BB's audit (checks RPATHs, license placement, exported symbols, …).
3. Push tarballs to a GitHub release on `efollman/libsie_jll.jl` (will need to request merge to official later)
