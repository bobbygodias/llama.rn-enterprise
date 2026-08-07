#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LLAMA_GGML_DIR="$ROOT_DIR/third_party/llama.cpp/ggml"
UPSTREAM_VULKAN_DIR="$LLAMA_GGML_DIR/src/ggml-vulkan"
UPSTREAM_VULKAN_HEADER="$LLAMA_GGML_DIR/include/ggml-vulkan.h"
CPP_DIR="$ROOT_DIR/cpp"
VULKAN_DIR="$CPP_DIR/ggml-vulkan"
VULKAN_HEADER="$CPP_DIR/ggml-vulkan.h"

if [[ ! -d "$UPSTREAM_VULKAN_DIR" || ! -f "$UPSTREAM_VULKAN_HEADER" ]]; then
  echo "error: llama.cpp Vulkan sources are missing." >&2
  echo "Run git submodule update --init --recursive and npm run bootstrap again." >&2
  exit 1
fi

echo "Syncing llama.cpp Vulkan backend into cpp/..."
rm -rf "$VULKAN_DIR"
mkdir -p "$VULKAN_DIR"
cp -R "$UPSTREAM_VULKAN_DIR"/. "$VULKAN_DIR"/
cp "$UPSTREAM_VULKAN_HEADER" "$VULKAN_HEADER"

# llama.rn prefixes the embedded llama.cpp/ggml C API so it can coexist with
# other React Native bindings that also ship ggml. Only the target backend and
# its public header participate in that API. The host shader generator and GLSL
# sources deliberately remain unmodified: their GGML_VULKAN_* feature switches
# are build-tool flags, not exported runtime symbols.
prefix_backend_file() {
  local file="$1"

  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' \
      -e 's/GGML_/LM_GGML_/g' \
      -e 's/ggml_/lm_ggml_/g' \
      "$file"
    sed -i '' -E \
      -e 's/(LM_)+GGML_/LM_GGML_/g' \
      -e 's/(lm_)+ggml_/lm_ggml_/g' \
      "$file"
  else
    sed -i \
      -e 's/GGML_/LM_GGML_/g' \
      -e 's/ggml_/lm_ggml_/g' \
      "$file"
    sed -i -E \
      -e 's/(LM_)+GGML_/LM_GGML_/g' \
      -e 's/(lm_)+ggml_/lm_ggml_/g' \
      "$file"
  fi
}

prefix_backend_file "$VULKAN_DIR/ggml-vulkan.cpp"
prefix_backend_file "$VULKAN_HEADER"

# The upstream CMakeLists assumes llama.cpp's ggml_add_backend_library helper.
# Android integration is maintained in android/src/main/rnllama/cmake instead.
rm -f "$VULKAN_DIR/CMakeLists.txt"

echo "Vulkan backend synced:"
echo "  source: $VULKAN_DIR/ggml-vulkan.cpp"
echo "  header: $VULKAN_HEADER"
echo "  shaders: $VULKAN_DIR/vulkan-shaders"
