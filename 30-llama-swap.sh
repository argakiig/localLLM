#!/usr/bin/env bash
# 30-llama-swap.sh — install llama-swap as the single OpenAI-compatible endpoint
# that owns model lifecycle + routing-by-name for every model. Replaces the old
# per-instance `llama-server@.service` units (which are stopped/disabled here).
#
# Why llama-swap: AnythingLLM's "generic-openai" base URL is GLOBAL (only the
# model NAME is per-request/per-workspace), so to reach all our models we expose
# them by name behind ONE endpoint. llama-swap spawns each llama-server on demand
# and routes the request's `model` field to the right upstream.
#
# Tiering (Resident Core + on-demand fallbacks):
#   Resident Core = embed + rerank + qwen3_17b + qwen3_4b + qwen3_06b + coder_05b + gemma4
#     → gemma4 (12B, ~7GB) fits in the resident tier alongside the tiny specialists.
#       It's the smallest multimodal model and stays resident for fast vision/audio.
#     → qwen3_4b (~3GB Q5) is the Phase 9 mid tier between qwen3_17b and gemma4.
#     → total resident ~20-22GB — trivial on this Strix Halo's ~113GB UMA budget.
#   general_fallback = {embed, rerank, qwen36} — 35B-A3B MoE, loads on demand,
#     evicts tiny LMs but keeps retrieval warm.
#   code_fallback = {embed, rerank, coder} — 30B-A3B MoE, same pattern.
#   vision_fallback = {qwen3vl} solo — 30B-A3B + mmproj, too heavy for resident.
#
# Key insight: gemma4 is SMALLER than qwen36/coder/qwen3vl and fully multimodal
# (text + image + audio). It belongs in the resident core, not as a fallback.
# The 30B+ vision-only qwen3vl stays solo since its mmproj + weights are too heavy.
#
# Endpoint:  http://$BIND_HOST:$LLAMASWAP_PORT/v1   (LAN-facing)
# Upstreams: 127.0.0.1:$startPort+ (local only; not exposed)
set -euo pipefail

REPO_DIR="$(dirname "$(readlink -f "$0")")"
cd "$REPO_DIR"

BIND_HOST="${LOCALLLM_BIND_HOST:-}"
MODELS_DIR="${LOCALLLM_MODELS_DIR:-$HOME/models}"
THREADS="${LOCALLLM_THREADS:-16}"
GPU_LAYERS="${LOCALLLM_GPU_LAYERS:-999}"
LLAMASWAP_PORT="${LOCALLLM_LLAMASWAP_PORT:-9090}"
LLAMA_SWAP_VERSION="${LLAMA_SWAP_VERSION:-v217}"

BIN="$REPO_DIR/build/bin/llama-server"
[[ -x "$BIN" ]] || { echo "missing $BIN — run 10-llama-cpp.sh first" >&2; exit 1; }

SWAP_DIR="$REPO_DIR/build/llama-swap"
SWAP_BIN="$SWAP_DIR/llama-swap"
CONF_DIR="$HOME/.config/llama-swap"
CONF="$CONF_DIR/config.yaml"
UNIT_DIR="$HOME/.config/systemd/user"
mkdir -p "$SWAP_DIR" "$CONF_DIR" "$UNIT_DIR"

# (instance  port-unused  model_file  ctx  parallel  [extra llama-server flags])
# port is assigned dynamically by llama-swap via ${PORT}; kept here for docs only.
# The 6th field onward pins per-model sampling. Per Unsloth's tool-calling guide
# + Qwen's recs (https://docs.unsloth.ai/basics/tool-calling-guide-for-local-llms):
#   thinking/reasoning models: temp 0.6, top-p 0.95, top-k 20, min-p 0.0
#   instruct/coder models:     temp 0.7, top-p 0.8,  top-k 20, min-p 0.0, repeat 1.05
# These matter because llama.cpp's defaults (top-k 40, min-p 0.1) are too aggressive
# for these models — min-p 0.1 over-prunes. A client (e.g. the harness) that sends
# its own `temperature` overrides --temp; the other samplers it omits take effect.
# Tiered serving set (2026-06-03): a Resident Core of tiny specialists + on-demand
# big MoE fallbacks (see the matrix below for which co-reside). The other GGUFs
# (smoke/thinking/rust/deepseek-v4-flash/heavy) remain on disk and can be re-added
# here one line at a time — they're just not served by default.
# qwen3vl note: the 6th field is the --mmproj path; the generator special-cases a
# row whose extra flags start with --mmproj so vision is enabled on that server.
INSTANCES=(
  "embed     - Qwen3-Embedding-4B-Q8_0.gguf                                 8192    4  --embeddings --pooling last --ubatch-size 8192 --batch-size 8192"
  "rerank    - qwen3-reranker-0.6b-q8_0.gguf                                8192     2  --reranking --pooling rank --ubatch-size 8192 --batch-size 8192"

  "gemma4_12b - gemma-4-12B-it-qat-UD-Q4_K_XL.gguf                        1310721 1 --mmproj ${MODELS_DIR}/mmproj-gemma-4-12b-it-qat-F32.gguf --spec-type draft-mtp --spec-draft-model ${MODELS_DIR}/mtp-gemma-4-12B-it-Q4_0.gguf --spec-draft-n-max 2 --spec-draft-ngl 999 --temp 0.6 --top-p 0.95 --top-k 64 --min-p 0.0"
  "gemma4_26b - gemma-4-26B-A4B-it-qat-UD-Q4_K_XL.gguf                       131072   1  --mmproj ${MODELS_DIR}/mmproj-gemma-4-26b-a4b-qat-BF16.gguf --spec-type draft-mtp --spec-draft-model ${MODELS_DIR}/mtp-gemma-4-26B-A4B-it.gguf --spec-draft-n-max 2 --spec-draft-ngl 999 --temp 0.6 --top-p 0.95 --top-k 64 --min-p 0.0"
  "gemma4_31b - gemma-4-31B-it-qat-UD-Q4_K_XL.gguf                       131072   1  --mmproj ${MODELS_DIR}/mmproj-gemma-4-31B-it-mmproj-BF16.gguf --spec-type draft-mtp --spec-draft-model ${MODELS_DIR}/mtp-gemma-4-31B-it.gguf --spec-draft-ngl 999 --spec-draft-n-max 2 --temp 0.6 --top-p 0.95 --top-k 64 --min-p 0.0"

  "step37_q2    - Step-3.7-Flash-UD-Q2_K_XL-00001-of-00003.gguf                 131072   1  --mmproj ${MODELS_DIR}/mmproj-Step-3.7-Flash-BF16.gguf --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0.0"
  "step37_q3    - Step-3.7-Flash-UD-Q3_K_XL-00001-of-00003.gguf                 131072   1  --mmproj ${MODELS_DIR}/mmproj-Step-3.7-Flash-BF16.gguf --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0.0"
)

# Tiering, expressed as llama-swap matrix co-residency SETS (not a flat resident
# list — the old RESIDENTS/EXCLUSIVE pair couldn't express "embed+rerank stay warm
# under one big model"). RESIDENT_CORE/FALLBACKS are used only for the summary; the
# MATRIX_SETS array is the source of truth the matrix block is generated from.
RESIDENT_CORE=(embed rerank gemma4_26b)
FALLBACKS=(gemma4_26b, gemma4_31b, step37_q2, step37_q3)

MATRIX_SETS=(
  "general: embed rerank gemma4_26b"
  "gemma4_12b: embed rerank gemma4_12b"
  "gemma4_31b: embed rerank gemma4_31b"
  "step37_q2: embed rerank step37_q2"
  "step37_q3: embed rerank step37_q3"
)

# llama-swap matrix `vars` keys MUST be alphanumeric and 1-8 chars — they are
# short ALIASES for the real model name (which may be long / contain dashes, e.g.
# "deepseek-v4-flash"). Derive a safe, unique key for every matrix model so any
# model name works; sets/evict_costs reference these keys, never the model name.
declare -A VKEY VSEEN
vkey() {
  local name="$1" base k i=0
  base="$(printf '%s' "$name" | tr -cd '[:alnum:]')"; base="${base:0:8}"
  [[ -n "$base" ]] || base="m"
  k="$base"
  while [[ -n "${VSEEN[$k]:-}" ]]; do i=$((i+1)); k="${base:0:7}$i"; done
  VSEEN[$k]=1; VKEY[$name]="$k"
}
# Distinct, first-seen-ordered list of every model referenced by MATRIX_SETS
# (== every model served in the matrix). Drives `vars` and alias lookup below.
MATRIX_MODELS=()
declare -A _SEEN_MODEL
for entry in "${MATRIX_SETS[@]}"; do
  for m in ${entry#*:}; do
    [[ -n "${_SEEN_MODEL[$m]:-}" ]] && continue
    _SEEN_MODEL[$m]=1; MATRIX_MODELS+=("$m")
  done
done
for n in "${MATRIX_MODELS[@]}"; do vkey "$n"; done

# ---------------------------------------------------------------------------
# 1) Install pinned llama-swap binary (idempotent — skip if version matches).
# ---------------------------------------------------------------------------
need_install=1
if [[ -x "$SWAP_BIN" ]] && "$SWAP_BIN" --version 2>/dev/null | grep -q " ${LLAMA_SWAP_VERSION#v} "; then
  need_install=0
fi
if (( need_install )); then
  url="https://github.com/mostlygeek/llama-swap/releases/download/${LLAMA_SWAP_VERSION}/llama-swap_${LLAMA_SWAP_VERSION#v}_linux_amd64.tar.gz"
  echo ">>> downloading llama-swap ${LLAMA_SWAP_VERSION}"
  tmp="$(mktemp -d)"
  curl -fsSL --max-time 180 -o "$tmp/ls.tar.gz" "$url"
  tar xzf "$tmp/ls.tar.gz" -C "$tmp"
  install -m 0755 "$tmp/llama-swap" "$SWAP_BIN"
  rm -rf "$tmp"
fi
"$SWAP_BIN" --version 2>&1 | head -1 | sed 's/^/installed: /'
"$SWAP_BIN" --version 2>/dev/null | sed -n '1p' > "$REPO_DIR/build/.llama-swap-version" || true

# ---------------------------------------------------------------------------
# 2) Generate config.yaml (models + groups).
# ---------------------------------------------------------------------------
{
  echo "# Managed by localLLM/30-llama-swap.sh — regenerated on each run."
  echo "healthCheckTimeout: 600   # heavy (~90GB) can take minutes to load from disk"
  echo "startPort: 5800           # upstream llama-servers bind 127.0.0.1:5800+"
  echo "logLevel: info"
  echo
  echo "models:"
  for row in "${INSTANCES[@]}"; do
    # 6th field onward (optional) = extra per-model llama-server flags.
    read -r name _port model ctx par extra <<<"$row"
    echo "  \"$name\":"
    echo "    cmd: |"
    echo "      $BIN"
    echo "      --model $MODELS_DIR/$model"
    echo "      --port \${PORT}"
    echo "      --ctx-size $ctx"
    echo "      --parallel $par"
    echo "      --threads $THREADS"
    echo "      --n-gpu-layers $GPU_LAYERS"
    echo "      --jinja"
    [[ -n "$extra" ]] && echo "      $extra"
    echo "    ttl: 0"
  done
  echo
  echo "# matrix: declares which models may run CONCURRENTLY (v217 recommended form;"
  echo "# 'groups' is the legacy alternative — a config may use one or the other)."
  echo "# The solver loads a requested model by evicting the fewest/cheapest running"
  echo "# models not in a set that contains it. Subset semantics: set [a,b,c] means"
  echo "# any subset is valid, and only the requested model is started (no preload)."
  echo "# Tiered Resident Core (generated from MATRIX_SETS in 30-llama-swap.sh):"
  echo "#   tiny_residents → the tiny specialists co-reside (the default tier)."
  echo "#   each *_fallback set repeats embed+rerank with one big model → escalating"
  echo "#     that model keeps retrieval warm and evicts only the tiny LMs (cheap to"
  echo "#     reload); requesting a tiny model again evicts the big one. vision solo."
  echo "# Var keys are short alphanumeric aliases for the real model names (vkey())."
  echo "matrix:"
  echo "  vars:"
  for n in "${MATRIX_MODELS[@]}"; do echo "    ${VKEY[$n]}: $n"; done
  echo "  sets:"
  for entry in "${MATRIX_SETS[@]}"; do
    set_name="${entry%%:*}"
    expr="$(for m in ${entry#*:}; do printf '%s & ' "${VKEY[$m]}"; done)"; expr="${expr% & }"
    echo "    ${set_name}: \"$expr\""
  done
} > "$CONF"
echo "wrote $CONF"

# Warn on any missing model file (don't fail — heavy may be deferred).
for row in "${INSTANCES[@]}"; do
  read -r name _port model _ctx _par <<<"$row"
  [[ -f "$MODELS_DIR/$model" ]] || echo "  warn: $name references missing $MODELS_DIR/$model"
done

# ---------------------------------------------------------------------------
# 3) Retire the old per-instance llama-server@ units (migration).
# ---------------------------------------------------------------------------
for n in smoke thinking coder rust qwen36 deepseek-v4-flash heavy; do
  systemctl --user stop    "llama-server@$n.service" 2>/dev/null || true
  systemctl --user disable "llama-server@$n.service" 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# 4) systemd user unit for llama-swap.
# ---------------------------------------------------------------------------
UNIT="$UNIT_DIR/llama-swap.service"
cat > "$UNIT" <<EOF
[Unit]
Description=llama-swap — single OpenAI endpoint + model router (localLLM)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$SWAP_BIN --config $CONF --listen $BIND_HOST:$LLAMASWAP_PORT --watch-config
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
echo "wrote $UNIT"

systemctl --user daemon-reload
systemctl --user enable llama-swap.service >/dev/null 2>&1 || true
systemctl --user restart llama-swap.service

# Poll until the endpoint answers (the proxy is up well before any model loads;
# a fixed `sleep` races the unit's restart and gives false negatives).
ready=0
for _ in $(seq 1 20); do
  if curl -fsS --max-time 2 "http://$BIND_HOST:$LLAMASWAP_PORT/v1/models" >/dev/null 2>&1; then
    ready=1; break
  fi
  sleep 1
done
if (( ready )); then
  echo "llama-swap.service: active (endpoint responding)"
else
  echo "llama-swap.service: endpoint not responding — journalctl --user -u llama-swap -n 50" >&2
  exit 1
fi

cat <<EOF

llama-swap is up:
  Endpoint     http://$BIND_HOST:$LLAMASWAP_PORT/v1   (use the model name to pick)
  Models       ${INSTANCES[*]%% *}
  Config       $CONF
  Resident Core ${RESIDENT_CORE[*]}  (tiny, co-resident — default tier)
  Fallbacks    ${FALLBACKS[*]}  (big MoE, load on demand)

  List models: curl http://$BIND_HOST:$LLAMASWAP_PORT/v1/models
  Running now: curl http://$BIND_HOST:$LLAMASWAP_PORT/running
  Tail logs:   journalctl --user -u llama-swap -f
EOF
