#!/usr/bin/env bash
# 10-llama-cpp.sh — build llama.cpp with the Vulkan backend.
# Idempotent. Override LLAMA_CPP_REF to track a branch or a different tag/commit.
# Pinned to a known-good commit for reproducible bootstrap (set to "master" to float).
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

LLAMA_CPP_REPO="${LLAMA_CPP_REPO:-https://github.com/ggml-org/llama.cpp.git}"
# 7d2b45b4f (2026-06-08): adds the gemma4-assistant arch — the Gemma-4 MTP draft
# models (PRs #23398 "add Gemma4 MTP" + #24282 "gemma-4 E2B/E4B assistants"), which
# `--spec-type draft-mtp` on the gemma4 servers needs. Supersedes 7c158fbb (b9518,
# 2026-06-04), which first added gemma4uv unified vision+audio mmproj support (still
# present here) but predates the MTP arch, so its draft load failed with
# "unknown model architecture: 'gemma4-assistant'".
LLAMA_CPP_REF="${LLAMA_CPP_REF:-7d2b45b4f}"

SRC="build/llama.cpp"
BUILD_DIR="$SRC/build"
BIN_DIR="build/bin"

mkdir -p build "$BIN_DIR"

if [[ ! -d "$SRC/.git" ]]; then
  echo ">>> cloning $LLAMA_CPP_REPO"
  git clone --filter=blob:none "$LLAMA_CPP_REPO" "$SRC"
fi

echo ">>> fetching + checking out $LLAMA_CPP_REF"
git -C "$SRC" fetch --tags --prune origin
git -C "$SRC" checkout --quiet "$LLAMA_CPP_REF"
# If the ref is a branch (e.g. master), fast-forward.
if git -C "$SRC" symbolic-ref -q HEAD >/dev/null; then
  git -C "$SRC" pull --ff-only --quiet
fi
built_commit=$(git -C "$SRC" rev-parse --short HEAD)

echo ">>> configuring (Vulkan, Release)"
# LLAMA_BUILD_UI=OFF: skip llama.cpp's embedded web UI. We front inference with
# a separate router + OpenAI gateway and never use the built-in server UI, and its build runs
# `npm run build` (vite), which fails on upstream with a missing dev dependency
# (@vitest/browser-playwright -> ERR_MODULE_NOT_FOUND). Disabling it keeps the build
# clean; only the /v1 OpenAI API and ops endpoints are used anyway.
cmake -S "$SRC" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_VULKAN=ON \
  -DLLAMA_CURL=ON \
  -DGGML_NATIVE=ON \
  -DLLAMA_BUILD_UI=OFF

echo ">>> building"
cmake --build "$BUILD_DIR" --config Release -j "$(nproc)"

echo ">>> linking binaries to $BIN_DIR"
for f in "$BUILD_DIR"/bin/llama-*; do
  [[ -x "$f" && ! -d "$f" ]] || continue
  ln -sfn "../../$f" "$BIN_DIR/$(basename "$f")"
done

# Record what was built so 99-verify can read it back.
echo "$built_commit" > build/.llama-cpp-commit
echo "$LLAMA_CPP_REF" > build/.llama-cpp-ref

echo
echo "Built llama.cpp @ $built_commit (ref: $LLAMA_CPP_REF)"
"$BIN_DIR/llama-cli" --version 2>&1 | head -5 || true
