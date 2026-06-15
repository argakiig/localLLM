#!/usr/bin/env bash
# 50-stable-diffusion.sh — build stable-diffusion.cpp (Vulkan) + fetch SD-Turbo
# and run sd-server as a service so image generation is routable through LiteLLM
# (60-litellm.sh exposes it as image/sd and gpt-image-2). Mirrors 10-llama-cpp.sh
# (pinned commit, Vulkan/Release, binaries linked into build/bin). Idempotent.
#
# Produces:  build/bin/sd-cli, build/bin/sd-server   (Vulkan-accelerated)
#            systemd --user sd-server.service on $SD_BIND_HOST:$SD_PORT (OpenAI image API)
# Model set: SD-Turbo — ungated, single self-contained checkpoint, under
#   $SD_MODELS_DIR (default ~/sdmodels):
#     sd_turbo.safetensors  UNet + VAE + text encoder  (~5.2 GB; everything in one file)
#   (Replaced SD 3.5 Medium — SD-Turbo is a *distilled* model: 1-4 steps at cfg ~1
#    instead of ~28 steps, so generation is seconds not minutes. It's SD2.1-based, so
#    512px and CLIP-only — no T5/clip_g, dropping ~10 GB of encoders → ~6 GB resident.)
#
# Why this repo: stabilityai/sd-turbo is ungated, keeping the bootstrap unauthenticated.
# The checkpoint carries its own VAE + text encoder, so no separate encoder files.
#
# Generate after this runs (see the printed example):
#   build/bin/sd-cli -m ~/sdmodels/sd_turbo.safetensors \
#     --cfg-scale 1.0 --sampling-method euler_a --steps 4 -W 512 -H 512 \
#     -p "isometric stone defense tower, game asset, plain white background" -o tower.png
#
# Env: SD_CPP_REF SD_CPP_REPO SD_MODELS_DIR SD_FETCH_MODELS(1) SD_SMOKE_TEST(1)
#      SD_BIND_HOST SD_PORT SD_STEPS SD_CFG SD_SIZE SD_RUN_SERVER(1)
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

# SD-Turbo model file + sd-server runtime settings (distilled: few steps, cfg ~1).
SD_BIND_HOST="${LOCALLLM_BIND_HOST:-10.0.0.30}"   # match the rest of the stack
SD_PORT="${SD_PORT:-1234}"
SD_STEPS="${SD_STEPS:-4}"
SD_CFG="${SD_CFG:-1.0}"
SD_SIZE="${SD_SIZE:-512}"                          # SD-Turbo is 512px native
RUN_SERVER="${SD_RUN_SERVER:-1}"
MODEL="$SD_MODELS_DIR/sd_turbo.safetensors"        # self-contained (UNet+VAE+text encoder)

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
# 3) Fetch SD-Turbo (resumable, skips if already present). One self-contained
#    safetensors — not in models.list (that validates GGUF magic; this is safetensors).
# ---------------------------------------------------------------------------
fetch() {  # <url> <dest>
  local url="$1" dest="$2" name; name="$(basename "$dest")"
  if [[ -s "$dest" ]]; then echo "  have   $name"; return; fi
  echo "  fetch  $name"
  curl -fL --retry 3 --retry-delay 2 -C - -o "$dest" "$url"
}
if [[ "$FETCH_MODELS" == "1" ]]; then
  echo ">>> fetching SD-Turbo into $SD_MODELS_DIR (~5.2 GB; resumable)"
  fetch "https://huggingface.co/stabilityai/sd-turbo/resolve/main/sd_turbo.safetensors" "$MODEL"
else
  echo ">>> SD_FETCH_MODELS=0 — skipping model download"
fi

# ---------------------------------------------------------------------------
# 4) Smoke test: generate one image to prove the Vulkan path works end-to-end.
# ---------------------------------------------------------------------------
if [[ "$SMOKE_TEST" == "1" && "$FETCH_MODELS" == "1" ]]; then
  out="build/sd-smoke.png"
  echo ">>> smoke test: generating $out (${SD_SIZE}x${SD_SIZE}, $SD_STEPS steps)"
  if "$BIN_DIR/sd-cli" \
       -m "$MODEL" \
       -p "isometric stone defense tower, game asset, plain white background" \
       --cfg-scale "$SD_CFG" --sampling-method euler_a --steps "$SD_STEPS" \
       -W "$SD_SIZE" -H "$SD_SIZE" -o "$out" 2>&1 | tail -6; then
    echo ">>> OK — wrote $out"
  else
    echo "!! smoke test failed (see output above)"; exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 5) Run sd-server as a systemd --user service so LiteLLM (60-litellm.sh) can
#    route to it. Serves the OpenAI image API at
#    http://$SD_BIND_HOST:$SD_PORT/v1/images/generations.
#    NOTE: this holds the model resident (~6 GB UMA). `systemctl --user stop
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
ExecStart=$SD_BIN -m $MODEL --steps $SD_STEPS --cfg-scale $SD_CFG --listen-ip $SD_BIND_HOST --listen-port $SD_PORT
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
echo "  Models     $SD_MODELS_DIR  (SD-Turbo: sd_turbo.safetensors, self-contained)"
echo "  Server     http://$SD_BIND_HOST:$SD_PORT/v1/images/generations  (sd-server.service)"
echo "  Logs       journalctl --user -u sd-server -f"
echo "  Generate   build/bin/sd-cli -m $MODEL \\"
echo "               --cfg-scale $SD_CFG --sampling-method euler_a --steps $SD_STEPS \\"
echo "               -W $SD_SIZE -H $SD_SIZE -p 'your prompt' -o asset.png"
echo "  Gateway    60-litellm.sh exposes this as image/sd + gpt-image-2 through LiteLLM :4000"
