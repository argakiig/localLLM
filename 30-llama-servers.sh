#!/usr/bin/env bash
# 30-llama-servers.sh — serve every GPU model from ONE llama-server in *router
# mode* (native llama.cpp multi-model hosting, since b~9270 / Dec 2025).
#
# Replaces 30-llama-swap.sh: same models, same flags (mmproj, MTP spec-decode,
# per-model sampling), co-resident — but no external swapper. The router holds up
# to --models-max model instances at once and routes each request to the instance
# named by its "model" field (= the preset section header). `load-on-startup`
# keeps them WARM at boot, so there's no first-request cold load.
#
#   Endpoint:  http://$BIND_HOST:$PORT/v1   (same :9090 as before — 60-litellm.sh
#                                            needs no change)
set -euo pipefail

REPO_DIR="$(dirname "$(readlink -f "$0")")"
cd "$REPO_DIR"

# ---------------------------------------------------------------------------
# Config (override via env)
# ---------------------------------------------------------------------------
BIND_HOST="${LOCALLLM_BIND_HOST:-10.0.0.30}"
PORT="${LOCALLLM_LLAMASWAP_PORT:-9090}"          # keep 9090 so the gateway is unchanged
MODELS_DIR="${LOCALLLM_MODELS_DIR:-$HOME/models}"
THREADS="${LOCALLLM_THREADS:-16}"
GPU_LAYERS="${LOCALLLM_GPU_LAYERS:-999}"
MODELS_MAX="${LOCALLLM_MODELS_MAX:-4}"            # max co-resident model instances

BIN="$REPO_DIR/build/bin/llama-server"
[[ -x "$BIN" ]] || { echo "missing $BIN — run 10-llama-cpp.sh first" >&2; exit 1; }
# Capture help to a var first: piping a binary into `grep -q` trips SIGPIPE under
# `pipefail` (grep exits on first match before the binary finishes writing).
BIN_HELP="$("$BIN" --help 2>&1 || true)"
grep -q -- "--models-preset" <<<"$BIN_HELP" || {
  echo "this llama-server has no router mode — bump 10-llama-cpp.sh (need >= b9270)" >&2; exit 1; }

CONF_DIR="$HOME/.config/llama-server"
PRESET="$CONF_DIR/models.ini"
UNIT_DIR="$HOME/.config/systemd/user"
mkdir -p "$CONF_DIR" "$UNIT_DIR"

# ---------------------------------------------------------------------------
# 1) Generate the router preset (.ini). Keys are llama-server flag names without
#    leading dashes; [*] is inherited by every model; sampling/MTP are per-model.
#    Sampling rationale matches 30-llama-swap.sh (Unsloth/Qwen tool-calling recs).
# ---------------------------------------------------------------------------
echo ">>> writing $PRESET"
cat > "$PRESET" <<EOF
version = 1

# Inherited by all models; per-model sections override. NOTE: load-on-startup is
# set per-model (NOT here) — the router has an implicit empty "default" preset, and
# putting it in [*] would try to preload that too, tripping --models-max.
[*]
n-gpu-layers = $GPU_LAYERS
threads = $THREADS
jinja = true

[embed]
model = $MODELS_DIR/Qwen3-Embedding-4B-Q8_0.gguf
load-on-startup = true
ctx-size = 8192
parallel = 4
embeddings = true
pooling = last
ubatch-size = 8192
batch-size = 8192

[rerank]
model = $MODELS_DIR/qwen3-reranker-0.6b-q8_0.gguf
load-on-startup = true
ctx-size = 8192
parallel = 2
reranking = true
pooling = rank
ubatch-size = 8192
batch-size = 8192

# Qwen3.6 MTP is embedded in the main GGUF — draft points at the model itself.
[qwen36_35b]
model = $MODELS_DIR/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf
load-on-startup = true
ctx-size = 262144
parallel = 1
mmproj = $MODELS_DIR/mmproj-qwen3.6-35b-a3b-BF16.gguf
spec-type = draft-mtp
model-draft = $MODELS_DIR/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf
spec-draft-n-max = 2
spec-draft-ngl = 999
temp = 0.6
top-p = 0.95
top-k = 20
min-p = 0.0
EOF

# Warn on any missing model file referenced by the preset.
grep -E '^(model|model-draft|mmproj) = ' "$PRESET" | awk '{print $3}' | sort -u | while read -r f; do
  [[ -f "$f" ]] || echo "  warn: preset references missing $f"
done

# ---------------------------------------------------------------------------
# 2) Retire llama-swap (this script replaces it).
# ---------------------------------------------------------------------------
if systemctl --user list-unit-files llama-swap.service >/dev/null 2>&1; then
  echo ">>> stopping + disabling llama-swap.service (replaced by the router)"
  systemctl --user stop    llama-swap.service 2>/dev/null || true
  systemctl --user disable llama-swap.service 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 3) systemd user unit for the router server.
# ---------------------------------------------------------------------------
UNIT="$UNIT_DIR/llama-router.service"
cat > "$UNIT" <<EOF
[Unit]
Description=llama-server router — one OpenAI endpoint hosting all GPU models (localLLM)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN --models-preset $PRESET --models-max $MODELS_MAX --host $BIND_HOST --port $PORT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
echo ">>> wrote $UNIT"

systemctl --user daemon-reload
systemctl --user enable llama-router.service >/dev/null 2>&1 || true
systemctl --user restart llama-router.service

# ---------------------------------------------------------------------------
# 4) Wait for the endpoint, then for models to finish loading on startup.
# ---------------------------------------------------------------------------
ready=0
for _ in $(seq 1 30); do
  curl -fsS --max-time 2 "http://$BIND_HOST:$PORT/v1/models" >/dev/null 2>&1 && { ready=1; break; }
  sleep 1
done
if (( ! ready )); then
  echo "llama-router: endpoint not responding — journalctl --user -u llama-router -n 50" >&2
  exit 1
fi

echo ">>> waiting for load-on-startup models (big MoEs load from disk)"
for _ in $(seq 1 120); do
  n=$(curl -fsS --max-time 3 "http://$BIND_HOST:$PORT/v1/models" 2>/dev/null \
        | python3 -c "import sys,json;print(len(json.load(sys.stdin).get('data',[])))" 2>/dev/null || echo 0)
  [[ "$n" -ge 4 ]] && break
  sleep 2
done

loaded=$(curl -fsS --max-time 3 "http://$BIND_HOST:$PORT/v1/models" 2>/dev/null \
  | python3 -c "import sys,json;print(', '.join(m['id'] for m in json.load(sys.stdin).get('data',[])))" 2>/dev/null)

cat <<EOF

llama-server router is up:
  Endpoint     http://$BIND_HOST:$PORT/v1   (route by "model" = preset section)
  Preset       $PRESET
  Max resident $MODELS_MAX
  Loaded now   ${loaded:-<none yet>}

  Models:      curl http://$BIND_HOST:$PORT/v1/models
  Logs:        journalctl --user -u llama-router -f

  Next: 60-litellm.sh fronts this (gpu/*) + Lemonade NPU (npu/*).
EOF
