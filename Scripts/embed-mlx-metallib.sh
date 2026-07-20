#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C
umask 077

EXPECTED_MLX_REVISION="dc43e62d7055353c7f99fa071a4e71d29dfddc44"
OUTPUT_PATH="${1:-}"

if [ -z "$OUTPUT_PATH" ]; then
  printf '%s\n' "usage: embed-mlx-metallib.sh <output-path>" >&2
  exit 64
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CANDIDATES=(
  "$ROOT/.build/checkouts/mlx-swift"
)
if [ -n "${BUILD_DIR:-}" ]; then
  CANDIDATES+=("$BUILD_DIR/../../SourcePackages/checkouts/mlx-swift")
fi

MLX_CHECKOUT=""
for candidate in "${CANDIDATES[@]}"; do
  if [ ! -d "$candidate/Source/Cmlx/mlx-generated/metal" ]; then
    continue
  fi
  revision="$(/usr/bin/git -C "$candidate" rev-parse HEAD 2>/dev/null || true)"
  if [ "$revision" = "$EXPECTED_MLX_REVISION" ]; then
    MLX_CHECKOUT="$candidate"
    break
  fi
done

if [ -z "$MLX_CHECKOUT" ]; then
  printf '%s\n' \
    "Pinned mlx-swift checkout $EXPECTED_MLX_REVISION was not found. Resolve packages first." >&2
  exit 66
fi

if ! /usr/bin/xcrun metal --version >/dev/null 2>&1; then
  printf '%s\n' \
    "The Xcode Metal Toolchain is missing. Install it with: xcodebuild -downloadComponent metalToolchain" >&2
  exit 69
fi

METAL_DIRECTORY="$MLX_CHECKOUT/Source/Cmlx/mlx-generated/metal"
WORK_DIRECTORY="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/flusterflow-mlx-metal.XXXXXX")"
cleanup() {
  /bin/rm -rf "$WORK_DIRECTORY"
}
trap cleanup EXIT HUP INT TERM

AIR_FILES=()
while IFS= read -r source; do
  relative="${source#$METAL_DIRECTORY/}"
  air="$WORK_DIRECTORY/${relative//\//_}.air"
  /usr/bin/xcrun -sdk macosx metal \
    -std=metal3.1 \
    -mmacosx-version-min=14.0 \
    -Wno-c++17-extensions \
    -I "$METAL_DIRECTORY" \
    -c "$source" \
    -o "$air"
  AIR_FILES+=("$air")
done < <(/usr/bin/find "$METAL_DIRECTORY" -type f -name '*.metal' | /usr/bin/sort)

if [ "${#AIR_FILES[@]}" -eq 0 ]; then
  printf '%s\n' "No MLX Metal shader sources were found." >&2
  exit 65
fi

/usr/bin/xcrun -sdk macosx metallib \
  "${AIR_FILES[@]}" \
  -o "$WORK_DIRECTORY/mlx.metallib"

/bin/mkdir -p "$(/usr/bin/dirname "$OUTPUT_PATH")"
/bin/mv "$WORK_DIRECTORY/mlx.metallib" "$OUTPUT_PATH"
/bin/chmod 0644 "$OUTPUT_PATH"
