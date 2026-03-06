#!/bin/bash
# Ensure mlx-swift_Cmlx.bundle with default.metallib is available.
# Prefers Xcode-built metallib; falls back to compiling from source.
set -euo pipefail

OUTPUT_DIR="${1:-.build/metallib}"
BUNDLE_DIR="${OUTPUT_DIR}/mlx-swift_Cmlx.bundle/Contents/Resources"

if [ -f "${BUNDLE_DIR}/default.metallib" ]; then
    exit 0
fi

mkdir -p "${BUNDLE_DIR}"

# Try Xcode build output first (debug then release)
for xcode_dir in \
    ".build/xcode/Build/Products/Debug" \
    ".build/xcode/Build/Products/Release"; do
    src="${xcode_dir}/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
    if [ -f "${src}" ]; then
        cp "${src}" "${BUNDLE_DIR}/default.metallib"
        echo "Copied metallib from Xcode build"
        exit 0
    fi
done

# Fall back to compiling from Metal sources
MLX_SWIFT_DIR=".build/checkouts/mlx-swift"
METAL_SRC_DIR="${MLX_SWIFT_DIR}/Source/Cmlx/mlx-generated/metal"
KERNELS_DIR="${MLX_SWIFT_DIR}/Source/Cmlx/mlx/mlx/backend/metal/kernels"
INCLUDE_DIR="${MLX_SWIFT_DIR}/Source/Cmlx/mlx"

METAL_FILES=$(/usr/bin/find "${METAL_SRC_DIR}" -name "*.metal" 2>/dev/null || true)
if [ -z "${METAL_FILES}" ]; then
    echo "Error: No metallib found and no .metal sources available." >&2
    echo "Build once with Xcode or install Metal Toolchain:" >&2
    echo "  xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
fi

echo "Building default.metallib from source..."
mkdir -p "${OUTPUT_DIR}/air"

AIR_FILES=""
for metal_file in ${METAL_FILES}; do
    base=$(basename "${metal_file}" .metal)
    air_file="${OUTPUT_DIR}/air/${base}.air"
    xcrun metal -c \
        -I "${METAL_SRC_DIR}" \
        -I "${KERNELS_DIR}" \
        -I "${INCLUDE_DIR}" \
        -std=metal3.2 \
        -o "${air_file}" \
        "${metal_file}"
    AIR_FILES="${AIR_FILES} ${air_file}"
done

xcrun metallib -o "${BUNDLE_DIR}/default.metallib" ${AIR_FILES}
rm -rf "${OUTPUT_DIR}/air"
echo "Built default.metallib"
