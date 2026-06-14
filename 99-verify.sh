#!/usr/bin/env bash
# 99-verify.sh — read-only end-to-end check that bootstrap is in a working state.
set -uo pipefail

REPO_DIR="$(dirname "$(readlink -f "$0")")"
cd "$REPO_DIR"

BIND_HOST="${LOCALLLM_BIND_HOST:-10.0.0.30}"
MODELS_DIR="${LOCALLLM_MODELS_DIR:-$HOME/models}"
LLAMASWAP_PORT="${LOCALLLM_LLAMASWAP_PORT:-9090}"
SWAP="http://$BIND_HOST:$LLAMASWAP_PORT"

# Served set (Resident Core tiny specialists + on-demand MoE fallbacks). All are
# listed by /v1/models whether or not they're currently loaded.
EXPECT_MODELS=(embed rerank gemma4_26b gemma4_31b)
# Model used for the on-demand routing round-trip: a resident-core model that is
# cheap + fast to load. qwen3_06b is the designated router/fast tier.
PROBE_MODEL="${LOCALLLM_VERIFY_MODEL:-gemma4_26b}"

fail=0
ok()  { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=1; }
info(){ printf '  \033[36mINFO\033[0m  %s\n' "$*"; }

echo "Binaries:"
for b in llama-server llama-cli llama-bench; do
  [[ -x "build/bin/$b" ]] && ok "$b" || bad "$b missing"
done
[[ -f build/.llama-cpp-commit ]] && ok "llama.cpp commit $(cat build/.llama-cpp-commit)"
if [[ -x build/llama-swap/llama-swap ]]; then
  ok "llama-swap ($(build/llama-swap/llama-swap --version 2>/dev/null | head -1))"
else
  bad "llama-swap binary missing — run 30-llama-swap.sh"
fi

echo
echo "Models in $MODELS_DIR (from models.list):"
while IFS=$' \t' read -r rel _url _rest || [[ -n "${rel:-}" ]]; do
  [[ -z "${rel:-}" || "$rel" =~ ^# ]] && continue
  if [[ -f "$MODELS_DIR/$rel" ]] && [[ "$(head -c 4 "$MODELS_DIR/$rel" 2>/dev/null)" == "GGUF" ]]; then
    ok "$rel ($(du -h "$MODELS_DIR/$rel" | cut -f1))"
  else
    bad "$rel missing or not GGUF"
  fi
done < models.list

echo
echo "llama-swap (unified endpoint + router):"
if systemctl --user is-active --quiet llama-swap.service; then
  ok "llama-swap.service active"
else
  bad "llama-swap.service not active — journalctl --user -u llama-swap -n 50"
fi
if loginctl show-user "$USER" -p Linger --value 2>/dev/null | grep -qx yes; then
  ok "lingering enabled (services survive logout)"
else
  printf '  \033[33mWARN\033[0m  lingering not enabled — services stop on logout\n'
fi
listed=$(curl -fsS --max-time 5 "$SWAP/v1/models" 2>/dev/null \
  | python3 -c 'import sys,json; print(" ".join(m["id"] for m in json.load(sys.stdin).get("data",[])))' 2>/dev/null || echo "")
if [[ -n "$listed" ]]; then
  ok "/v1/models: $listed"
  for m in "${EXPECT_MODELS[@]}"; do
    echo " $listed " | grep -q " $m " && ok "  model '$m' present" || bad "  model '$m' missing from /v1/models"
  done
else
  bad "/v1/models did not respond at $SWAP"
fi

echo
echo "Routing round-trip (loads '$PROBE_MODEL' on demand):"
# /no_think keeps qwen3_06b out of thinking mode so a 4-token cap doesn't truncate
# inside a <think> block (Qwen3 models default to thinking under --jinja).
gen=$(curl -fsS --max-time 120 "$SWAP/v1/chat/completions" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$PROBE_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply: ok /no_think\"}],\"max_tokens\":4,\"temperature\":0}" 2>/dev/null || true)
if echo "$gen" | grep -q '"content"'; then
  ok "$PROBE_MODEL completion via llama-swap"
  slots=$(curl -fsS --max-time 5 "$SWAP/upstream/$PROBE_MODEL/props" 2>/dev/null \
    | python3 -c 'import sys,json; print(int(json.load(sys.stdin).get("total_slots",0)))' 2>/dev/null || echo 0)
  [[ "${slots:-0}" -ge 2 ]] && ok "$PROBE_MODEL upstream: $slots parallel slots" || info "$PROBE_MODEL upstream slots: ${slots:-?}"
else
  bad "$PROBE_MODEL completion round-trip failed"
fi
echo
echo
if (( fail )); then
  echo "FAIL — $fail check(s) failed."
  exit 1
fi
echo "All checks passed."
