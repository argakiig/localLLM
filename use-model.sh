#!/usr/bin/env bash
# use-model.sh — helper for the llama-swap endpoint. With llama-swap, models load
# on demand by request and the resident set is co-resident automatically, so you
# rarely need this — it's mostly for warming/evicting and inspecting state.
#
#   use-model.sh list            show available + currently-running models
#   use-model.sh load <name>     warm a model (loads it now)
#   use-model.sh heavy           warm heavy (evicts the resident set)
#   use-model.sh unload [name]   unload one model, or all if no name given
#
# Models route by NAME (smoke|thinking|coder|rust|heavy). Heavy is memory-
# exclusive: loading it evicts the residents; loading any resident evicts heavy.
set -euo pipefail

BIND_HOST="${LOCALLLM_BIND_HOST:-10.0.0.30}"
PORT="${LOCALLLM_LLAMASWAP_PORT:-9090}"
BASE="http://$BIND_HOST:$PORT"

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }

list() {
  echo "Available:"
  curl -fsS --max-time 5 "$BASE/v1/models" 2>/dev/null \
    | python3 -c 'import sys,json; [print("  ",m["id"]) for m in json.load(sys.stdin).get("data",[])]' 2>/dev/null \
    || echo "  (llama-swap not reachable at $BASE)"
  echo "Running now:"
  curl -fsS --max-time 5 "$BASE/running" 2>/dev/null \
    | python3 -c 'import sys,json
d=json.load(sys.stdin); r=d.get("running",d if isinstance(d,list) else [])
[print("  ",(m.get("model") if isinstance(m,dict) else m)) for m in r] or print("  (none)")' 2>/dev/null \
    || echo "  (unknown)"
}

warm() {  # warm a model by sending a 1-token request
  local m="$1"
  echo ">>> warming $m (this also evicts the other exclusive group if needed)…"
  curl -fsS --max-time 600 "$BASE/v1/chat/completions" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$m\",\"messages\":[{\"role\":\"user\",\"content\":\"ok\"}],\"max_tokens\":1}" \
    >/dev/null 2>&1 && echo "    $m ready" || { echo "    failed to warm $m" >&2; exit 1; }
}

unload() {  # unload one or all
  if [[ -n "${1:-}" ]]; then
    curl -fsS --max-time 10 "$BASE/models/unload?model=$1" >/dev/null 2>&1 \
      || curl -fsS -X POST --max-time 10 "$BASE/models/unload" -H 'Content-Type: application/json' -d "{\"model\":\"$1\"}" >/dev/null 2>&1 || true
    echo "unloaded $1"
  else
    curl -fsS -X POST --max-time 10 "$BASE/models/unload" >/dev/null 2>&1 || true
    echo "unloaded all"
  fi
}

case "${1:-list}" in
  list|"")        list ;;
  load)           [[ -n "${2:-}" ]] || { echo "usage: $0 load <name>" >&2; exit 1; }; warm "$2"; echo; list ;;
  heavy)          warm heavy; echo; list ;;
  unload)         unload "${2:-}"; echo; list ;;
  -h|--help|help) usage ;;
  *)              echo "unknown: $1" >&2; usage; exit 1 ;;
esac
