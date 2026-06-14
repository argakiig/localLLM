#!/usr/bin/env bash
# 50-stable-diffusion.sh — build stable-diffusion.cpp (Vulkan) + fetch a FLUX.1
# image-generation model. The image-gen layer on top of the llama.cpp inference
# stack; mirrors 10-llama-cpp.sh (pinned commit, Vulkan/Release, binaries linked
# into build/bin). Idempotent + safely re-runnable.
#
# Produces:  build/bin/sd-cli, build/bin/sd-server   (Vulkan-accelerated)
# Model set: FLUX.1 [schnell] — Apache-2.0, ungated, ~21.5 GB — under $SD_MODELS_DIR
#   (default ~/sdmodels):
#     flux1-schnell-q8_0.gguf  diffusion model (~12 GB, near-lossless q8)
#     ae.safetensors           VAE             (~320 MB)
#     clip_l.safetensors       text encoder 1  (~250 MB)
#     t5xxl_fp16.safetensors   text encoder 2  (~9 GB; full fp16 — this APU has the UMA)
#
# Why FLUX.1 [schnell]: best open-weight quality at 1-4 steps, Apache-2.0 (commercial
# OK), and every file is ungated so the bootstrap stays fully unauthenticated. Swap to
# [dev] (top quality, non-commercial, gated → needs HF_TOKEN) or an SDXL checkpoint +
# pixel-art LoRA (lighter, better for flat 2D sprites) by changing the URLs below.
#
# Generate after this runs (see the printed example):
#   build/bin/sd-cli --diffusion-model ~/sdmodels/flux1-schnell-q8_0.gguf \
#     --vae ~/sdmodels/ae.safetensors --clip_l ~/sdmodels/clip_l.safetensors \
#     --t5xxl ~/sdmodels/t5xxl_fp16.safetensors --cfg-scale 1.0 \
#     --sampling-method euler --steps 4 -W 1024 -H 1024 \
#     -p "isometric stone defense tower, game asset, plain white background" -o tower.png
#
# Env: SD_CPP_REF SD_CPP_REPO SD_MODELS_DIR SD_FETCH_MODELS(1) SD_SMOKE_TEST(1)
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

SD_CPP_REPO="${SD_CPP_REPO:-https://github.com/leejet/stable-diffusion.cpp.git}"
# be65ac7 (2026-06-01): verified to support FLUX / SD3.5 / Qwen-Image / Chroma and
# the Vulkan backend. Override SD_CPP_REF=master to float.
SD_CPP_REF="${SD_CPP_REF:-be65ac7}"
SD_MODELS_DIR="${SD_MODELS_DIR:-$HOME/sdmodels}"
FETCH_MODELS="${SD_FETCH_MODELS:-1}"
SMOKE_TEST="${SD_SMOKE_TEST:-1}"

SRC="build/stable-diffusion.cpp"
BUILD_DIR="$SRC/build"
BIN_DIR="build/bin"
mkdir -p build "$BIN_DIR" "$SD_MODELS_DIR"

# ---------------------------------------------------------------------------
# 1) Clone / checkout the pinned sd.cpp (ggml is a submodule — needs --recursive).
# ---------------------------------------------------------------------------
if [[ ! -d "$SRC/.git" ]]; then
  echo ">>> cloning $SD_CPP_REPO"
  git clone --recursive --filter=blob:none "$SD_CPP_REPO" "$SRC"
fi
echo ">>> fetching + checking out $SD_CPP_REF"
git -C "$SRC" fetch --tags --prune origin
git -C "$SRC" checkout --quiet "$SD_CPP_REF"
git -C "$SRC" submodule update --init --recursive
# If the ref is a branch (e.g. master), fast-forward.
if git -C "$SRC" symbolic-ref -q HEAD >/dev/null; then
  git -C "$SRC" pull --ff-only --quiet
fi
built_commit=$(git -C "$SRC" rev-parse --short HEAD)

# ---------------------------------------------------------------------------
# 2) Configure + build (Vulkan, Release). SD_WEBP/WEBM off to drop optional deps.
# ---------------------------------------------------------------------------
echo ">>> configuring (Vulkan, Release)"
cmake -S "$SRC" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DSD_VULKAN=ON \
  -DSD_WEBP=OFF \
  -DSD_WEBM=OFF

echo ">>> building"
cmake --build "$BUILD_DIR" --config Release -j "$(nproc)"

echo ">>> linking binaries to $BIN_DIR"
for f in "$BUILD_DIR"/bin/sd-*; do
  [[ -x "$f" && ! -d "$f" ]] || continue
  ln -sfn "../../$f" "$BIN_DIR/$(basename "$f")"
done
echo "$built_commit" > build/.sd-cpp-commit
echo "$SD_CPP_REF"  > build/.sd-cpp-ref
echo ">>> built stable-diffusion.cpp @ $built_commit (ref: $SD_CPP_REF)"

# ---------------------------------------------------------------------------
# 3) Fetch the FLUX.1-schnell model set (resumable, skips files already present).
#    Not in models.list because 20-models.sh validates GGUF magic and these are
#    mixed GGUF + safetensors — this step owns the image-model download.
# ---------------------------------------------------------------------------
fetch() {  # <url> <dest>
  local url="$1" dest="$2" name; name="$(basename "$dest")"
  if [[ -s "$dest" ]]; then echo "  have   $name"; return; fi
  echo "  fetch  $name"
  curl -fL --retry 3 --retry-delay 2 -C - -o "$dest" "$url"
}
if [[ "$FETCH_MODELS" == "1" ]]; then
  echo ">>> fetching FLUX.1-schnell into $SD_MODELS_DIR (~21.5 GB; resumable)"
  fetch "https://huggingface.co/leejet/FLUX.1-schnell-gguf/resolve/main/flux1-schnell-q8_0.gguf"      "$SD_MODELS_DIR/flux1-schnell-q8_0.gguf"
  fetch "https://huggingface.co/ffxvs/vae-flux/resolve/main/ae.safetensors"                            "$SD_MODELS_DIR/ae.safetensors"
  fetch "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors"     "$SD_MODELS_DIR/clip_l.safetensors"
  fetch "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp16.safetensors" "$SD_MODELS_DIR/t5xxl_fp16.safetensors"
else
  echo ">>> SD_FETCH_MODELS=0 — skipping model download"
fi

# ---------------------------------------------------------------------------
# 4) Smoke test: generate one image to prove the Vulkan path works end-to-end.
# ---------------------------------------------------------------------------
if [[ "$SMOKE_TEST" == "1" && "$FETCH_MODELS" == "1" ]]; then
  out="build/sd-smoke.png"
  echo ">>> smoke test: generating $out (512x512, 4 steps)"
  if "$BIN_DIR/sd-cli" \
       --diffusion-model "$SD_MODELS_DIR/flux1-schnell-q8_0.gguf" \
       --vae "$SD_MODELS_DIR/ae.safetensors" \
       --clip_l "$SD_MODELS_DIR/clip_l.safetensors" \
       --t5xxl "$SD_MODELS_DIR/t5xxl_fp16.safetensors" \
       -p "isometric stone defense tower, game asset, plain white background" \
       --cfg-scale 1.0 --sampling-method euler --steps 4 \
       -W 512 -H 512 -o "$out" 2>&1 | tail -6; then
    echo ">>> OK — wrote $out"
  else
    echo "!! smoke test failed (see output above)"; exit 1
  fi
fi

echo
echo "stable-diffusion.cpp ready:"
echo "  Binaries   $BIN_DIR/sd-cli  $BIN_DIR/sd-server"
echo "  Models     $SD_MODELS_DIR  (FLUX.1-schnell q8_0 + ae + clip_l + t5xxl)"
echo "  Generate   build/bin/sd-cli --diffusion-model $SD_MODELS_DIR/flux1-schnell-q8_0.gguf \\"
echo "               --vae $SD_MODELS_DIR/ae.safetensors --clip_l $SD_MODELS_DIR/clip_l.safetensors \\"
echo "               --t5xxl $SD_MODELS_DIR/t5xxl_fp16.safetensors --cfg-scale 1.0 \\"
echo "               --sampling-method euler --steps 4 -W 1024 -H 1024 \\"
echo "               -p 'your prompt, plain white background' -o asset.png"
echo "  Server     build/bin/sd-server --diffusion-model ... (OpenAI-ish image endpoint)"
