#!/bin/bash

# Builds and pushes the fs-portal image to Docker Hub as
# xerofuzzion/fs-portal:<tag>, where <tag> is "v<N>-<arch>" plus
# "latest-<arch>".
#
# amd64 is built by default. arm64 is only built when --arm64 is passed:
# dumbpipe is compiled from the vendored Rust source (vendor/dumbpipe), so an
# arm64 build on an x86 host runs under QEMU emulation and takes a long time.
#
# version.json records the release history:
#   {
#     "latest_version": <N>,
#     "versions": [
#       {"version": <N>, "digests": {"x86_64": "sha256:...", "aarch64": "sha256:..."}},
#       ...
#     ]
#   }
# It is only updated after every push has succeeded, so a failed release
# does not burn a version number.
#
# Requires `docker login` for the xerofuzzion account.

# -E so the ERR trap also fires for failures inside functions/subshells
set -eE

# Change to the directory of the script
cd "$(dirname "$0")"

IMAGE_NAME="xerofuzzion/fs-portal"

# File containing the version history
VERSION_FILE="version.json"

BUILD_ARM64=0
for arg in "$@"; do
  case "$arg" in
    --arm64 | --all)
      BUILD_ARM64=1
      ;;
    -h | --help)
      echo "Usage: $0 [--arm64]"
      echo "  --arm64  also build and push the aarch64 image (slow: emulated Rust build of dumbpipe)"
      exit 0
      ;;
    *)
      echo "error: unknown argument '$arg' (see --help)" >&2
      exit 1
      ;;
  esac
done

# Check if version.json exists, if not initialize it
if [ ! -f "$VERSION_FILE" ]; then
  echo '{"latest_version": -1, "versions": []}' > "$VERSION_FILE"
fi

# Read current version (".version" fallback migrates the old flat format)
CURRENT_VERSION=$(jq -r '.latest_version // .version // -1' "$VERSION_FILE")

# Increment version
NEW_VERSION=$((CURRENT_VERSION + 1))

TAGNAME="v${NEW_VERSION}"

METADATA_DIR=$(mktemp -d)
trap 'rm -rf "$METADATA_DIR"' EXIT

build_and_push() {
  local platform="$1"
  local arch="$2"
  echo "Building and pushing version ${TAGNAME}-${arch} and latest-${arch}..."
  docker buildx build \
    --platform "$platform" \
    -t "${IMAGE_NAME}:${TAGNAME}-${arch}" -t "${IMAGE_NAME}:latest-${arch}" \
    --metadata-file "${METADATA_DIR}/${arch}.json" \
    --output type=image,push=true,compression=zstd,force-compression=true,compression-level=3 .
}

# sha256 digest of the pushed image for an arch, from buildx metadata
pushed_digest() {
  jq -r '."containerimage.digest"' "${METADATA_DIR}/$1.json"
}

build_and_push linux/amd64 x86_64

if [ "$BUILD_ARM64" -eq 1 ]; then
  build_and_push linux/arm64 aarch64
else
  echo "Skipping aarch64 — pass --arm64 to build it."
fi

DIGEST_X86=$(pushed_digest x86_64)
DIGEST_ARM=""
if [ "$BUILD_ARM64" -eq 1 ]; then
  DIGEST_ARM=$(pushed_digest aarch64)
fi

# Record the release (migrating any old flat {"version": N} file shape).
jq --arg v "$NEW_VERSION" --arg dx "$DIGEST_X86" --arg da "$DIGEST_ARM" '
  {latest_version: ($v | tonumber), versions: (.versions // [])}
  | .versions += [{
      version: ($v | tonumber),
      digests: ({x86_64: $dx} + (if $da != "" then {aarch64: $da} else {} end))
    }]
' "$VERSION_FILE" > version.tmp.json && mv version.tmp.json "$VERSION_FILE"

echo "Successfully built and pushed ${IMAGE_NAME}:${TAGNAME}-x86_64 (and latest-x86_64): ${DIGEST_X86}"
if [ "$BUILD_ARM64" -eq 1 ]; then
  echo "Successfully built and pushed ${IMAGE_NAME}:${TAGNAME}-aarch64 (and latest-aarch64): ${DIGEST_ARM}"
fi
echo "version.json updated: latest_version=${NEW_VERSION}"
