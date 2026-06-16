#!/usr/bin/env bash
# 40-npu-lemonade.sh — stand up Lemonade as the local OpenAI-compatible router:
# NPU models via FastFlowLM, Qwen3.6 via Lemonade's llama.cpp Vulkan backend,
# and SD-Turbo via Lemonade's sd-cpp Vulkan backend. This replaces the separate
# llama-router, sd-server, and LiteLLM gateway.
#
# Idempotent. Re-running only does the missing work. Host package installs use
# sudo; a fully-provisioned host needs none.
#
# NOTE: we install libxrt-npu2 but deliberately NOT amdxdna-dkms — kernel 7.0+
# already binds the in-tree amdxdna driver here, and the DKMS module would
# conflict with it (and may fail to build against the znver5 kernel).
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

# ---------------------------------------------------------------------------
# Config (override via env)
# ---------------------------------------------------------------------------
BIND_HOST="${LOCALLLM_BIND_HOST:-10.0.0.30}"
LEMONADE_PORT="${LEMONADE_PORT:-13305}"
MAX_LOADED_MODELS="${LEMONADE_MAX_LOADED_MODELS:-4}"
PPA="${LEMONADE_PPA:-ppa:lemonade-team/stable}"
FLM_VERSION="${FLM_VERSION:-0.9.43}"
GPU_MODEL_ID="${LEMONADE_GPU_MODEL_ID:-qwen36-35b}"
GPU_CHECKPOINT="${LEMONADE_GPU_CHECKPOINT:-unsloth/Qwen3.6-35B-A3B-MTP-GGUF:Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf}"
IMAGE_MODEL_ID="${LEMONADE_IMAGE_MODEL_ID:-SD-Turbo}"
GPU_CTX_SIZE="${LEMONADE_GPU_CTX_SIZE:-262144}"
GPU_ARGS="${LEMONADE_LLAMACPP_ARGS:---temp 0.6 --top-p 0.95 --top-k 20 --min-p 0.0}"
IMAGE_SIZE="${LEMONADE_IMAGE_SIZE:-512}"
IMAGE_STEPS="${LEMONADE_IMAGE_STEPS:-4}"
IMAGE_CFG="${LEMONADE_IMAGE_CFG:-1.0}"

# NPU models served via FastFlowLM.
NPU_MODELS=(
  qwen3.5-4b-FLM            # aux LLM: summarize / classify / extract (+ tool calling)
  whisper-v3-turbo-FLM    # ASR / transcription (Hermes STT -> npu/whisper)
  # qwen3-0.6b-FLM        # omitted: FLM emits invalid UTF-8 on short outputs
  #                         (json.exception.type_error.316) — re-add if upstream fixes it
)

SUDO=""; [[ $EUID -ne 0 ]] && SUDO=sudo

# ---------------------------------------------------------------------------
# 1) Install the NPU stack (Lemonade + XRT + FastFlowLM) — idempotent.
# ---------------------------------------------------------------------------
flm_installed_now=0

if ! dpkg -s lemonade-server >/dev/null 2>&1; then
  echo ">>> installing lemonade-server (+ libxrt-npu2) from $PPA"
  if ! grep -rqi "lemonade" /etc/apt/sources.list.d/ 2>/dev/null; then
    $SUDO add-apt-repository -y "$PPA"
    $SUDO apt-get update
  fi
  $SUDO apt-get install -y lemonade-server libxrt-npu2
else
  echo ">>> lemonade-server present ($(dpkg-query -W -f='${Version}' lemonade-server))"
fi

if ! command -v flm >/dev/null 2>&1; then
  echo ">>> installing FastFlowLM $FLM_VERSION (.deb)"
  . /etc/os-release
  ostag="${ID}${VERSION_ID}"              # ubuntu26.04 / ubuntu25.10 / debian13 ...
  deb="fastflowlm_${FLM_VERSION}_${ostag}_amd64.deb"
  url="https://github.com/FastFlowLM/FastFlowLM/releases/download/v${FLM_VERSION}/${deb}"
  tmp="$(mktemp -d)"
  echo "    fetching $deb"
  curl -fsSL --max-time 300 -o "$tmp/$deb" "$url"
  $SUDO apt-get install -y "$tmp/$deb"     # pulls XRT/ffmpeg deps; NO amdxdna-dkms
  rm -rf "$tmp"
  flm_installed_now=1
else
  echo ">>> flm present ($(flm --version 2>/dev/null | head -1))"
fi

# ---------------------------------------------------------------------------
# 2) Validate the NPU stack (kernel / driver / firmware / memlock).
# ---------------------------------------------------------------------------
echo ">>> flm validate"
flm validate || echo "    WARN: flm validate reported issues (see above)"

# ---------------------------------------------------------------------------
# 3) Start Lemonade (system service) and configure it.
# ---------------------------------------------------------------------------
if systemctl is-enabled --quiet lemond.service && systemctl is-active --quiet lemond.service; then
  echo ">>> lemond.service already enabled + running"
else
  echo ">>> enabling + starting lemond.service"
  $SUDO systemctl enable --now lemond.service
fi

lemonade_cli() {
  lemonade --host "$BIND_HOST" --port "$LEMONADE_PORT" "$@" || \
    lemonade --host 127.0.0.1 --port "$LEMONADE_PORT" "$@"
}

wait_for_lemonade() {
  local host
  for _ in $(seq 1 30); do
    for host in "$BIND_HOST" 127.0.0.1; do
      curl -fsS --max-time 2 "http://$host:$LEMONADE_PORT/api/v1/models" >/dev/null 2>&1 && return 0
    done
    sleep 1
  done
  return 1
}

echo ">>> ensuring Lemonade Vulkan backends are installed"
lemonade_cli backends install llamacpp:vulkan >/dev/null 2>&1 || \
  echo "    WARN: could not install llamacpp:vulkan (it may already be installed or need manual attention)"
lemonade_cli backends install sd-cpp:vulkan >/dev/null 2>&1 || \
  echo "    WARN: could not install sd-cpp:vulkan (it may already be installed or need manual attention)"

# If flm was just installed, the daemon cached backend availability before it
# existed — restart so it detects the flm:npu backend.
if (( flm_installed_now )); then
  echo ">>> restarting lemond so it detects the new flm backend"
  $SUDO systemctl restart lemond.service
fi

# Wait for the OpenAI API to answer before driving the CLI (it's an HTTP client).
wait_for_lemonade || echo "    WARN: Lemonade API did not answer during startup wait"

echo ">>> setting max_loaded_models=$MAX_LOADED_MODELS (keep NPU + GPU models co-resident)"
lemonade_cli config set \
  "host=$BIND_HOST" \
  "disable_model_filtering=false" \
  "extra_models_dir=" \
  "max_loaded_models=$MAX_LOADED_MODELS" \
  "global_timeout=600" \
  "llamacpp.backend=vulkan" \
  "llamacpp.vulkan_args=$GPU_ARGS" \
  "sdcpp.backend=vulkan" \
  "sdcpp.width=$IMAGE_SIZE" \
  "sdcpp.height=$IMAGE_SIZE" \
  "sdcpp.steps=$IMAGE_STEPS" \
  "sdcpp.cfg_scale=$IMAGE_CFG" >/dev/null 2>&1 || \
  echo "    WARN: could not set Lemonade router options"

echo ">>> restarting lemond so router settings take effect"
if [[ -n "$SUDO" ]]; then
  restart_ok=0
  sudo -n systemctl restart lemond.service 2>/dev/null && restart_ok=1
else
  restart_ok=0
  systemctl restart lemond.service 2>/dev/null && restart_ok=1
fi
if (( ! restart_ok )); then
  echo "    WARN: could not restart lemond non-interactively; restart it manually if bind/backend changes do not apply"
fi
wait_for_lemonade || echo "    WARN: Lemonade API did not answer after restart"

# ---------------------------------------------------------------------------
# 4) Pull the NPU models (idempotent — pull is a no-op if already present).
# ---------------------------------------------------------------------------
for m in "${NPU_MODELS[@]}"; do
  echo ">>> pulling NPU model: $m"
  lemonade_cli pull "$m" >/dev/null 2>&1 && echo "    ok" || echo "    WARN: pull failed for $m"
done

echo ">>> pulling GPU model: $GPU_MODEL_ID"
lemonade_cli pull "$GPU_MODEL_ID" \
  --checkpoint main "$GPU_CHECKPOINT" \
  --recipe llamacpp \
  --label reasoning \
  --label tool-calling \
  --label mtp >/dev/null 2>&1 && echo "    ok" || echo "    WARN: pull failed for $GPU_MODEL_ID"

echo ">>> saving GPU load options for $GPU_MODEL_ID"
lemonade_cli load "$GPU_MODEL_ID" \
  --llamacpp vulkan \
  --ctx-size "$GPU_CTX_SIZE" \
  --llamacpp-args "$GPU_ARGS" \
  --save-options >/dev/null 2>&1 && echo "    ok" || echo "    WARN: load failed for $GPU_MODEL_ID"

echo ">>> pulling image model: $IMAGE_MODEL_ID"
lemonade_cli pull "$IMAGE_MODEL_ID" >/dev/null 2>&1 && echo "    ok" || echo "    WARN: pull failed for $IMAGE_MODEL_ID"

cat <<EOF

Lemonade router is up:
  Endpoint     http://$BIND_HOST:$LEMONADE_PORT/api/v1
  NPU models:  ${NPU_MODELS[*]}
  GPU model:   $GPU_MODEL_ID
  Image model: $IMAGE_MODEL_ID
  Validate:    flm validate
  Logs:        journalctl -u lemond -f
EOF
