#!/usr/bin/env bash
# 50-stable-diffusion.sh — build stable-diffusion.cpp (Vulkan) + fetch SD 3.5 Medium
# and run sd-server as a service so image generation is routable through LiteLLM
# (60-litellm.sh exposes it as image/sd). Mirrors 10-llama-cpp.sh (pinned commit,
# Vulkan/Release, binaries linked into build/bin). Idempotent + safely re-runnable.
#
# Produces:  build/bin/sd-cli, build/bin/sd-server   (Vulkan-accelerated)
#            systemd --user sd-server.service on $SD_BIND_HOST:$SD_PORT (OpenAI image API)
# Model set: Stable Diffusion 3.5 Medium — ungated mirror, ~6.5 GB to fetch, under
#   $SD_MODELS_DIR (default ~/sdmodels):
#     sd3.5_medium.safetensors  MMDiT + VAE   (~5.1 GB; combined checkpoint, own VAE)
#     clip_g.safetensors        text encoder  (~1.4 GB)
#     clip_l.safetensors        text encoder  (~250 MB; reused from the FLUX set)
#     t5xxl_fp16.safetensors    text encoder  (~9 GB;   reused from the FLUX set)
#   (Replaced FLUX.1-schnell — smaller + higher quality at the medium tier.)
#
# Why this mirror: stabilityai/stable-diffusion-3.5-medium is GATED (needs HF_TOKEN);
# ckpt/stable-diffusion-3.5-medium is an ungated copy, keeping the bootstrap
# unauthenticated. clip_l + t5xxl are shared with FLUX so we only fetch ~6.5 GB.
#
# Generate after this runs (see the printed example):
#   build/bin/sd-cli -m ~/sdmodels/sd3.5_medium.safetensors \
#     --clip_l ~/sdmodels/clip_l.safetensors --clip_g ~/sdmodels/clip_g.safetensors \
#     --t5xxl ~/sdmodels/t5xxl_fp16.safetensors \
#     --cfg-scale 4.5 --sampling-method euler --steps 28 -W 1024 -H 1024 \
#     -p "isometric stone defense tower, game asset, plain white background" -o tower.png
#
# Env: SD_CPP_REF SD_CPP_REPO SD_MODELS_DIR SD_FETCH_MODELS(1) SD_SMOKE_TEST(1)
#      SD_BIND_HOST SD_PORT SD_STEPS SD_CFG SD_RUN_SERVER(1)
set -euo pipefail
REPO_DIR="$(dirname "$(readlink -f "$0")")"
cd "$REPO_DIR"

SD_CPP_REPO="${SD_CPP_REPO:-https://github.com/leejet/stable-diffusion.cpp.git}"
# be65ac7 (2026-06-01): verified to support FLUX / SD3.5 / Qwen-Image / Chroma and
# the Vulkan backend. Override SD_CPP_REF=master to float.
SD_CPP_REF="${SD_CPP_REF:-be65ac7}"
SD_MODELS_DIR="${SD_MODELS_DIR:-$HOME/sdmodels}"
FETCH_MODELS="${SD_FETCH_MODELS:-1}"
SMOKE_TEST="${SD_SMOKE_TEST:-1}"

# SD 3.5 Medium model files + sd-server runtime settings.
SD_BIND_HOST="${LOCALLLM_BIND_HOST:-10.0.0.30}"   # match the rest of the stack
SD_PORT="${SD_PORT:-1234}"
SD_STEPS="${SD_STEPS:-28}"
SD_CFG="${SD_CFG:-4.5}"
RUN_SERVER="${SD_RUN_SERVER:-1}"
MODEL="$SD_MODELS_DIR/sd3.5_medium.safetensors"   # combined checkpoint (carries its VAE)
CLIP_L="$SD_MODELS_DIR/clip_l.safetensors"
CLIP_G="$SD_MODELS_DIR/clip_g.safetensors"
T5="$SD_MODELS_DIR/t5xxl_fp16.safetensors"

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
  echo ">>> fetching SD 3.5 Medium into $SD_MODELS_DIR (~6.5 GB new; resumable)"
  fetch "https://huggingface.co/ckpt/stable-diffusion-3.5-medium/resolve/main/sd3.5_medium.safetensors"              "$MODEL"
  fetch "https://huggingface.co/ckpt/stable-diffusion-3.5-medium/resolve/main/text_encoder_2/model.fp16.safetensors" "$CLIP_G"
  # clip_l + t5xxl are shared with the FLUX set; fetched only if missing.
  fetch "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors"     "$CLIP_L"
  fetch "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp16.safetensors" "$T5"
else
  echo ">>> SD_FETCH_MODELS=0 — skipping model download"
fi

# ---------------------------------------------------------------------------
# 4) Smoke test: generate one image to prove the Vulkan path works end-to-end.
# ---------------------------------------------------------------------------
if [[ "$SMOKE_TEST" == "1" && "$FETCH_MODELS" == "1" ]]; then
  out="build/sd-smoke.png"
  echo ">>> smoke test: generating $out (768x768, $SD_STEPS steps)"
  if "$BIN_DIR/sd-cli" \
       -m "$MODEL" --clip_l "$CLIP_L" --clip_g "$CLIP_G" --t5xxl "$T5" \
       -p "isometric stone defense tower, game asset, plain white background" \
       --cfg-scale "$SD_CFG" --sampling-method euler --steps "$SD_STEPS" \
       -W 768 -H 768 -o "$out" 2>&1 | tail -6; then
    echo ">>> OK — wrote $out"
  else
    echo "!! smoke test failed (see output above)"; exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 5) Run sd-server as a systemd --user service so LiteLLM (60-litellm.sh) can
#    route to it. Serves the OpenAI image API at
#    http://$SD_BIND_HOST:$SD_PORT/v1/images/generations.
#    NOTE: this holds the model resident (~16 GB UMA). `systemctl --user stop
#    sd-server` to free it when you're not generating images.
# ---------------------------------------------------------------------------
if [[ "$RUN_SERVER" == "1" ]]; then
  SD_BIN="$REPO_DIR/$BIN_DIR/sd-server"
  UNIT_DIR="$HOME/.config/systemd/user"; mkdir -p "$UNIT_DIR"
  UNIT="$UNIT_DIR/sd-server.service"
  cat > "$UNIT" <<EOF
[Unit]
Description=stable-diffusion.cpp server — OpenAI image API (localLLM)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$SD_BIN -m $MODEL --clip_l $CLIP_L --clip_g $CLIP_G --t5xxl $T5 --steps $SD_STEPS --cfg-scale $SD_CFG --listen-ip $SD_BIND_HOST --listen-port $SD_PORT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
  echo ">>> wrote $UNIT"
  systemctl --user daemon-reload
  systemctl --user enable sd-server.service >/dev/null 2>&1 || true
  systemctl --user restart sd-server.service
  for _ in $(seq 1 60); do
    curl -fsS --max-time 2 "http://$SD_BIND_HOST:$SD_PORT/v1/models" >/dev/null 2>&1 && { echo ">>> sd-server responding on $SD_BIND_HOST:$SD_PORT"; break; }
    sleep 2
  done
fi

echo
echo "stable-diffusion.cpp ready:"
echo "  Binaries   $BIN_DIR/sd-cli  $BIN_DIR/sd-server"
echo "  Models     $SD_MODELS_DIR  (SD 3.5 Medium: sd3.5_medium + clip_l + clip_g + t5xxl)"
echo "  Server     http://$SD_BIND_HOST:$SD_PORT/v1/images/generations  (sd-server.service)"
echo "  Logs       journalctl --user -u sd-server -f"
echo "  Generate   build/bin/sd-cli -m $MODEL \\"
echo "               --clip_l $CLIP_L --clip_g $CLIP_G --t5xxl $T5 \\"
echo "               --cfg-scale $SD_CFG --sampling-method euler --steps $SD_STEPS \\"
echo "               -W 1024 -H 1024 -p 'your prompt' -o asset.png"
echo "  Gateway    60-litellm.sh exposes this as image/sd through LiteLLM :4000"
