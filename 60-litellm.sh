#!/usr/bin/env bash
# 60-litellm.sh — the unifying gateway. Runs LiteLLM (Docker, host network) as a
# single local OpenAI API in front of EVERY backend, discovered live:
#
#     OpenAI-compatible clients  ->  http://$BIND_HOST:$LITELLM_PORT/v1
#                                       │  LiteLLM (Docker, --network host)
#                          ┌────────────┴─────────────┐
#                     npu/*  -> Lemonade :13305    gpu/*  -> llama-swap :9090
#                     (XDNA2 NPU / FastFlowLM)     (Radeon 8060S / llama.cpp)
#
# This is the front door, so it runs AFTER the backends (40-npu-lemonade.sh and
# 30-llama-swap.sh). It hardcodes no model list — it queries each backend's
# /v1/models and regenerates the config. Idempotent; needs no sudo.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

# ---------------------------------------------------------------------------
# Config (override via env)
# ---------------------------------------------------------------------------
BIND_HOST="${LOCALLLM_BIND_HOST:-10.0.0.30}"     # same LAN IP llama-swap binds
LEMONADE_PORT="${LEMONADE_PORT:-13305}"
LLAMASWAP_PORT="${LOCALLLM_LLAMASWAP_PORT:-9090}"
LLAMASWAP_ADDR="${LLAMASWAP_ADDR:-$BIND_HOST:$LLAMASWAP_PORT}"
SD_ADDR="${SD_ADDR:-$BIND_HOST:1234}"            # stable-diffusion.cpp sd-server (50-…)

LITELLM_PORT="${LITELLM_PORT:-4000}"
LITELLM_IMAGE="${LITELLM_IMAGE:-ghcr.io/berriai/litellm:main-stable}"
LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-sk-local}"

CONF_DIR="$HOME/.config/litellm"
CONF="$CONF_DIR/config.yaml"
LEM_BASE="http://127.0.0.1:$LEMONADE_PORT/api/v1"   # loopback (reachable via host net)
GPU_BASE="http://$LLAMASWAP_ADDR/v1"
SD_BASE="http://$SD_ADDR/v1"

command -v docker >/dev/null 2>&1 || { echo "docker not found — install Docker first" >&2; exit 1; }
mkdir -p "$CONF_DIR"

# ---------------------------------------------------------------------------
# 1) Discover models from each backend (fall back to a static set if down).
# ---------------------------------------------------------------------------
mapfile -t NPU_IDS < <(curl -fsS --max-time 5 "$LEM_BASE/models" 2>/dev/null \
  | python3 -c "import sys,json;[print(m['id']) for m in json.load(sys.stdin).get('data',[]) if m.get('recipe')=='flm' and m.get('downloaded')]" 2>/dev/null)
if (( ${#NPU_IDS[@]} == 0 )); then
  echo "    WARN: Lemonade ($LEM_BASE) returned no flm models — using defaults"
  NPU_IDS=(qwen3-4b-FLM embed-gemma-300m-FLM whisper-v3-turbo-FLM)
fi

mapfile -t GPU_IDS < <(curl -fsS --max-time 5 "$GPU_BASE/models" 2>/dev/null \
  | python3 -c "import sys,json;[print(m['id']) for m in json.load(sys.stdin).get('data',[])]" 2>/dev/null)
if (( ${#GPU_IDS[@]} == 0 )); then
  echo "    WARN: llama-swap ($GPU_BASE) unreachable — using defaults"
  GPU_IDS=(embed rerank qwen36_35b)
fi

# ---------------------------------------------------------------------------
# 2) Generate the LiteLLM config.
# ---------------------------------------------------------------------------
echo ">>> writing $CONF"
EMITTED=()
emit_model() {  # name  backend_model  api_base  [mode]
  local name="$1" bmodel="$2" base="$3" mode="${4:-}"
  {
    echo "  - model_name: $name"
    echo "    litellm_params:"
    echo "      model: openai/$bmodel"
    echo "      api_base: $base"
    echo "      api_key: dummy"
    if [[ -n "$mode" ]]; then
      echo "    model_info:"
      echo "      mode: $mode"
    fi
  } >> "$CONF"
  EMITTED+=("$name")
}

{
  echo "# Managed by localLLM/60-litellm.sh — regenerated on each run."
  echo "# One local OpenAI API fronting NPU (Lemonade) + GPU (llama-swap)."
  echo "# Pick a model by name: npu/* -> XDNA2 NPU, gpu/* -> Radeon iGPU."
  echo "# Run the gateway with --network host so loopback api_base values resolve."
  echo
  echo "model_list:"
} > "$CONF"

echo "  # ---- NPU (Lemonade / FastFlowLM) ----" >> "$CONF"
for m in "${NPU_IDS[@]}"; do
  case "$m" in
    *embed*)   continue ;;                       # embed retired — see 40-npu-lemonade.sh
    *whisper*) name="npu/whisper"; mode="audio_transcription" ;;
    *)         s="${m%-FLM}";      name="npu/${s,,}"; mode="" ;;
  esac
  emit_model "$name" "$m" "$LEM_BASE" "$mode"
done

echo "  # ---- GPU (llama-swap / llama.cpp) ----" >> "$CONF"
for id in "${GPU_IDS[@]}"; do
  case "$id" in
    rerank)  continue ;;                      # no clean OpenAI mode for llama.cpp rerank
    default) continue ;;                      # router's implicit empty preset
    embed)  continue ;;                       # embed retired — see 30-llama-servers.sh
    *)      name="gpu/${id//_/-}"; mode="" ;;
  esac
  emit_model "$name" "$id" "$GPU_BASE" "$mode"
done

# --- Image (stable-diffusion.cpp sd-server, only if it's running) ---
sd_id="$(curl -fsS --max-time 5 "$SD_BASE/models" 2>/dev/null \
  | python3 -c "import sys,json;d=json.load(sys.stdin).get('data',[]);print(d[0]['id'] if d else '')" 2>/dev/null)"
if [[ -n "$sd_id" ]]; then
  echo "  # ---- Image (stable-diffusion.cpp) ----" >> "$CONF"
  emit_model "image/sd" "$sd_id" "$SD_BASE" "image_generation"
else
  echo "    note: sd-server ($SD_BASE) not running — skipping image/sd (run 50-stable-diffusion.sh)"
fi

{
  echo
  echo "litellm_settings:"
  echo "  drop_params: true          # tolerate backend-specific param gaps"
} >> "$CONF"

# NPU aux LLM -> biggest available GPU model, if both ends exist.
has() { printf '%s\n' "${EMITTED[@]}" | grep -qx "$1"; }
gpu_fallback=""
for cand in gpu/qwen36-35b; do
  if has "$cand"; then gpu_fallback="$cand"; break; fi
done
if has "npu/qwen3-4b" && [[ -n "$gpu_fallback" ]]; then
  {
    echo
    echo "router_settings:"
    echo "  fallbacks:"
    echo "    - npu/qwen3-4b: [\"$gpu_fallback\"]"
  } >> "$CONF"
fi

{
  echo
  echo "general_settings:"
  echo "  master_key: $LITELLM_MASTER_KEY"
} >> "$CONF"

# ---------------------------------------------------------------------------
# 3) Install + run the gateway (Docker, host network).
# ---------------------------------------------------------------------------
echo ">>> pulling $LITELLM_IMAGE"
docker pull "$LITELLM_IMAGE" >/dev/null

echo ">>> (re)starting litellm container on :$LITELLM_PORT"
docker rm -f litellm >/dev/null 2>&1 || true
docker run -d --name litellm --restart unless-stopped --network host \
  -e LITELLM_MASTER_KEY="$LITELLM_MASTER_KEY" \
  -v "$CONF:/app/config.yaml" \
  "$LITELLM_IMAGE" \
  --config /app/config.yaml --port "$LITELLM_PORT" >/dev/null

ready=0
for _ in $(seq 1 40); do
  if curl -fsS --max-time 2 -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
       "http://127.0.0.1:$LITELLM_PORT/v1/models" >/dev/null 2>&1; then
    ready=1; break
  fi
  sleep 1
done
if (( ! ready )); then
  echo "litellm: endpoint not responding — docker logs litellm" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
cat <<EOF

Gateway is up:
  Endpoint     http://$BIND_HOST:$LITELLM_PORT/v1   (key: $LITELLM_MASTER_KEY)
  NPU backend  Lemonade   $LEM_BASE   (npu/*)
  GPU backend  llama-swap $GPU_BASE   (gpu/*)
  Config       $CONF

  Models:       curl -H "Authorization: Bearer $LITELLM_MASTER_KEY" http://$BIND_HOST:$LITELLM_PORT/v1/models
  Gateway logs: docker logs -f litellm

  NOTE: change the master key (LITELLM_MASTER_KEY) before exposing this on the LAN.
EOF
