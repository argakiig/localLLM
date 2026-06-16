#!/usr/bin/env bash
# use-model.sh — helper for the Lemonade router endpoint. Models route by the
# OpenAI "model" field; this helper is mostly for listing and warming.
#
#   use-model.sh list            show available Lemonade models
#   use-model.sh load <name>     warm a model (loads it now)
#   use-model.sh unload [name]   unload one model, or all if no name given
#
# Current GPU model: qwen36-35b.
set -euo pipefail

BIND_HOST="${LOCALLLM_BIND_HOST:-10.0.0.30}"
PORT="${LEMONADE_PORT:-13305}"
BASE="http://$BIND_HOST:$PORT/api/v1"

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }

list() {
  echo "Available:"
  curl -fsS --max-time 5 "$BASE/models" 2>/dev/null \
    | python3 -c 'import sys,json; [print("  ",m["id"]) for m in json.load(sys.stdin).get("data",[])]' 2>/dev/null \
    || echo "  (Lemonade not reachable at $BASE)"
}

warm() {  # warm a model by sending a 1-token request
  local m="$1"
  echo ">>> warming $m..."
  curl -fsS --max-time 600 "$BASE/chat/completions" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$m\",\"messages\":[{\"role\":\"user\",\"content\":\"ok\"}],\"max_tokens\":1}" \
    >/dev/null 2>&1 && echo "    $m ready" || { echo "    failed to warm $m" >&2; exit 1; }
}

unload() {  # unload one or all
  if [[ -n "${1:-}" ]]; then
    lemonade --host "$BIND_HOST" --port "$PORT" unload "$1" >/dev/null 2>&1 || true
    echo "unloaded $1"
  else
    lemonade --host "$BIND_HOST" --port "$PORT" unload >/dev/null 2>&1 || true
    echo "unloaded all"
  fi
}

case "${1:-list}" in
  list|"")        list ;;
  load)           [[ -n "${2:-}" ]] || { echo "usage: $0 load <name>" >&2; exit 1; }; warm "$2"; echo; list ;;
  unload)         unload "${2:-}"; echo; list ;;
  -h|--help|help) usage ;;
  *)              echo "unknown: $1" >&2; usage; exit 1 ;;
esac
