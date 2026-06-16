#!/usr/bin/env bash
# 99-verify.sh — read-only end-to-end check that Lemonade is the local router.
set -uo pipefail

REPO_DIR="$(dirname "$(readlink -f "$0")")"
cd "$REPO_DIR"

BIND_HOST="${LOCALLLM_BIND_HOST:-10.0.0.30}"
MODELS_DIR="${LOCALLLM_MODELS_DIR:-$HOME/models}"
LEMONADE_PORT="${LEMONADE_PORT:-13305}"
LEMONADE_BASE="http://$BIND_HOST:$LEMONADE_PORT/api/v1"
PROBE_MODEL="${LOCALLLM_VERIFY_MODEL:-qwen36-35b}"
EXPECT_MODELS=(qwen3.5-4b-FLM whisper-v3-turbo-FLM qwen36-35b SD-Turbo)

fail=0
ok()  { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=1; }
info(){ printf '  \033[36mINFO\033[0m  %s\n' "$*"; }

echo "Binaries:"
for b in llama-server llama-cli llama-bench; do
  [[ -x "build/bin/$b" ]] && ok "$b" || bad "$b missing"
done
[[ -f build/.llama-cpp-commit ]] && ok "llama.cpp commit $(cat build/.llama-cpp-commit)"

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
echo "Lemonade router:"
if systemctl is-active --quiet lemond.service; then
  ok "lemond.service active"
else
  bad "lemond.service not active — journalctl -u lemond -n 50"
fi

cfg="$(lemonade --host "$BIND_HOST" --port "$LEMONADE_PORT" config 2>/dev/null || lemonade config 2>/dev/null || true)"
cfg_host="$(awk '$1=="host" {print $2; exit}' <<<"$cfg")"
cfg_backend="$(awk '$1=="llamacpp.backend" {print $2; exit}' <<<"$cfg")"
cfg_sdcpp="$(awk '$1=="sdcpp.backend" {print $2; exit}' <<<"$cfg")"
[[ "$cfg_host" == "$BIND_HOST" ]] && ok "Lemonade host $cfg_host" || info "Lemonade host ${cfg_host:-?}"
[[ "$cfg_backend" == "vulkan" ]] && ok "llamacpp.backend vulkan" || bad "llamacpp.backend is ${cfg_backend:-?}"
[[ "$cfg_sdcpp" == "vulkan" ]] && ok "sdcpp.backend vulkan" || bad "sdcpp.backend is ${cfg_sdcpp:-?}"

listed=$(curl -fsS --max-time 5 "$LEMONADE_BASE/models" 2>/dev/null \
  | python3 -c 'import sys,json; print(" ".join(m["id"] for m in json.load(sys.stdin).get("data",[])))' 2>/dev/null || echo "")
if [[ -n "$listed" ]]; then
  ok "/api/v1/models: $listed"
  for m in "${EXPECT_MODELS[@]}"; do
    echo " $listed " | grep -q " $m " && ok "  model '$m' present" || bad "  model '$m' missing from /api/v1/models"
  done
else
  bad "/api/v1/models did not respond at $LEMONADE_BASE"
fi

echo
echo "Routing round-trip (loads '$PROBE_MODEL' through Lemonade):"
gen=$(curl -fsS --max-time 600 "$LEMONADE_BASE/chat/completions" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$PROBE_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply: ok /no_think\"}],\"max_tokens\":8,\"temperature\":0}" 2>/dev/null || true)
if echo "$gen" | grep -q '"content"'; then
  ok "$PROBE_MODEL completion via Lemonade"
else
  bad "$PROBE_MODEL completion round-trip failed"
fi

echo
echo "Image round-trip (loads 'SD-Turbo' through Lemonade):"
img=$(curl -fsS --max-time 300 "$LEMONADE_BASE/images/generations" -H 'Content-Type: application/json' \
  -d '{"model":"SD-Turbo","prompt":"a simple red cube on a white background","size":"512x512","n":1}' 2>/dev/null || true)
if echo "$img" | grep -q '"b64_json"'; then
  ok "SD-Turbo image generation via Lemonade"
else
  bad "SD-Turbo image generation round-trip failed"
fi

echo
echo "Retired services:"
if systemctl --user is-active --quiet llama-router.service 2>/dev/null; then
  bad "llama-router.service still active"
else
  ok "llama-router.service inactive"
fi
if systemctl --user is-active --quiet sd-server.service 2>/dev/null; then
  bad "standalone sd-server.service still active"
else
  ok "standalone sd-server.service inactive"
fi
if command -v docker >/dev/null 2>&1; then
  if docker inspect litellm >/dev/null 2>&1 || docker inspect litellm-postgres >/dev/null 2>&1; then
    bad "LiteLLM/Postgres containers still exist"
  else
    ok "LiteLLM/Postgres containers removed"
  fi
fi

echo
if (( fail )); then
  echo "FAIL — $fail check(s) failed."
  exit 1
fi
echo "All checks passed."
