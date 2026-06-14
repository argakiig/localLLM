#!/usr/bin/env bash
# bench-mtp.sh — measure the MTP (draft-mtp) speculative-decoding speedup for a
# gemma4 model. Launches llama-server DIRECTLY (bypassing llama-swap) twice on the
# same prompt — once WITH the MTP drafter, once WITHOUT — and reports prompt/gen
# tok/s plus draft acceptance, so you get an apples-to-apples on/off comparison.
#
# Why direct, not through llama-swap: the live config bakes the MTP flags into each
# served model, so there is no in-band way to toggle the drafter off. Running the
# server directly lets the script flip exactly one variable (the drafter) and hold
# everything else constant.
#
# Usage:   ./bench-mtp.sh [gemma4_31b|gemma4_26b]      (default gemma4_31b)
# Env:     BENCH_PORT(5998)  BENCH_CTX(8192)  BENCH_NPREDICT(256)  BENCH_REPS(3)
#          BENCH_TEMP(1.0)   BENCH_FREE_SWAP(1 = unload llama-swap models first)
#          LOCALLLM_MODELS_DIR  LOCALLLM_GPU_LAYERS  LOCALLLM_THREADS
#
# Notes:
#  - Uses --parallel 1 for a clean single-stream decode rate (the live llama-swap
#    config serves --parallel 2; speculation behaves differently under contention).
#  - Acceptance rises sharply as temperature drops. Try BENCH_TEMP=0 to see MTP's
#    best case (greedy), and the default 1.0 (the production gemma sampler) for the
#    realistic case.
#  - Requires the llama.cpp build to support arch 'gemma4-assistant' (10-llama-cpp.sh
#    pin >= 7d2b45b4f / b9568). Older builds crash loading the drafter.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

MODELS_DIR="${LOCALLLM_MODELS_DIR:-$HOME/models}"
BIN="build/bin/llama-server"
PORT="${BENCH_PORT:-5998}"
HOST=127.0.0.1
NGL="${LOCALLLM_GPU_LAYERS:-999}"
THREADS="${LOCALLLM_THREADS:-16}"
CTX="${BENCH_CTX:-8192}"
NPREDICT="${BENCH_NPREDICT:-256}"
REPS="${BENCH_REPS:-3}"
TEMP="${BENCH_TEMP:-1.0}"
FREE_SWAP="${BENCH_FREE_SWAP:-1}"

MODEL_KEY="${1:-gemma4_31b}"
case "$MODEL_KEY" in
  gemma4_31b)
    MODEL="$MODELS_DIR/gemma-4-31B-it-qat-UD-Q4_K_XL.gguf"
    MMPROJ="$MODELS_DIR/mmproj-gemma-4-31B-it-mmproj-BF16.gguf"
    DRAFT="$MODELS_DIR/mtp-gemma-4-31B-it.gguf" ;;
  gemma4_26b)
    MODEL="$MODELS_DIR/gemma-4-26B-A4B-it-qat-UD-Q4_K_XL.gguf"
    MMPROJ="$MODELS_DIR/mmproj-gemma-4-26b-a4b-qat-BF16.gguf"
    DRAFT="$MODELS_DIR/mtp-gemma-4-26B-A4B-it.gguf" ;;
  *) echo "usage: $0 [gemma4_31b|gemma4_26b]"; exit 1 ;;
esac

for f in "$BIN" "$MODEL" "$MMPROJ" "$DRAFT"; do
  [[ -e "$f" ]] || { echo "!! missing: $f"; exit 1; }
done

PROMPT="Write a detailed technical explanation of how speculative decoding speeds up large language model inference. Cover the draft model, verification of drafted tokens, and what determines the acceptance rate. Write several full paragraphs."

TMP="$(mktemp -d)"
SRV_PID=""
cleanup() { [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

# Best-effort: free the GPU of any llama-swap-resident models so the benchmark has
# the device to itself (idle models still consume VRAM/UMA and can perturb timings).
# Reuse use-model.sh's unload (the verified endpoint) rather than reimplement it;
# /models/unload returns an empty non-2xx body, so a raw curl exit code is not a
# reliable success signal.
if [[ "$FREE_SWAP" == "1" && -x ./use-model.sh ]]; then
  echo ">>> unloading any llama-swap-resident models for a clean run"
  ./use-model.sh unload >/dev/null 2>&1 || true
fi

# bench.py: warm up once (uncounted), then REPS timed requests; print one pipe-
# delimited summary line. Parses llama-server's timings block for decode rate and
# any draft/acceptance counters (field names vary across builds, so we dump them raw).
cat > "$TMP/bench.py" <<'PY'
import json, sys, urllib.request
host, port, label, prompt, npred, reps, temp = (
    sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4],
    int(sys.argv[5]), int(sys.argv[6]), float(sys.argv[7]))
url = f"http://{host}:{port}/v1/chat/completions"
def ask():
    body = json.dumps({"model": "x",
                       "messages": [{"role": "user", "content": prompt}],
                       "max_tokens": npred, "temperature": temp}).encode()
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=300) as r:
        return json.load(r)
ask()  # warmup, not counted
gen, pp, gen_n, draft_n, draft_acc, last = [], [], 0, 0, 0, {}
for _ in range(reps):
    t = ask().get("timings", {}); last = t
    gen.append(t.get("predicted_per_second", 0.0))
    pp.append(t.get("prompt_per_second", 0.0))
    gen_n += t.get("predicted_n", 0)
    for k, v in t.items():
        if not isinstance(v, (int, float)): continue
        if "accept" in k:                          draft_acc += v
        elif k in ("draft_n", "n_draft", "n_drafted"): draft_n += v
avg = lambda a: sum(a) / len(a) if a else 0.0
acc = (100.0 * draft_acc / draft_n) if draft_n else -1.0
draftkeys = {k: v for k, v in last.items() if "draft" in k or "accept" in k}
print(f"{label}|{avg(pp):.1f}|{avg(gen):.2f}|{acc:.1f}|{gen_n}|{json.dumps(draftkeys)}")
PY

start_server() {
  local logf="$1"; shift
  "$BIN" --model "$MODEL" --mmproj "$MMPROJ" --port "$PORT" \
    --ctx-size "$CTX" --parallel 1 --threads "$THREADS" --n-gpu-layers "$NGL" \
    --jinja --temp "$TEMP" --top-p 0.95 --top-k 64 --min-p 0.0 "$@" \
    >"$logf" 2>&1 &
  SRV_PID=$!
  local i
  for i in $(seq 1 180); do
    curl -fsS "http://$HOST:$PORT/health" >/dev/null 2>&1 && return 0
    kill -0 "$SRV_PID" 2>/dev/null || { echo "!! server exited during load:"; tail -25 "$logf"; return 1; }
    sleep 1
  done
  echo "!! server not ready after 180s:"; tail -25 "$logf"; return 1
}
stop_server() { [[ -n "$SRV_PID" ]] && { kill "$SRV_PID" 2>/dev/null || true; wait "$SRV_PID" 2>/dev/null || true; SRV_PID=""; }; }

echo ">>> MTP benchmark: $MODEL_KEY  (ctx=$CTX n_predict=$NPREDICT reps=$REPS temp=$TEMP, --parallel 1)"
echo ">>> [1/2] MTP OFF  — loading model..."
start_server "$TMP/off.log"
OFF=$(python3 "$TMP/bench.py" "$HOST" "$PORT" "MTP_off" "$PROMPT" "$NPREDICT" "$REPS" "$TEMP")
stop_server

echo ">>> [2/2] MTP ON   — loading model + drafter..."
start_server "$TMP/on.log" --spec-type draft-mtp --model-draft "$DRAFT" --spec-draft-ngl "$NGL"
ON=$(python3 "$TMP/bench.py" "$HOST" "$PORT" "MTP_on" "$PROMPT" "$NPREDICT" "$REPS" "$TEMP")
stop_server

IFS='|' read -r _ off_pp off_gen _ _ _            <<<"$OFF"
IFS='|' read -r _ on_pp  on_gen  on_acc _ on_keys <<<"$ON"
speedup=$(awk -v a="$on_gen" -v b="$off_gen" 'BEGIN{ if (b>0) printf "%.2f", a/b; else printf "n/a" }')

printf '\n================  MTP benchmark: %s  ================\n' "$MODEL_KEY"
printf '%-9s  %13s  %10s\n' ""        "prompt tok/s" "gen tok/s"
printf '%-9s  %13s  %10s\n' "MTP off" "$off_pp"      "$off_gen"
printf '%-9s  %13s  %10s\n' "MTP on"  "$on_pp"       "$on_gen"
printf -- '----------------------------------------------------\n'
printf 'Gen speedup (on/off):  %sx\n' "$speedup"
[[ "$on_acc" != "-1.0" ]] && printf 'Draft acceptance:      %s%%\n' "$on_acc"
printf 'Draft timings (raw):   %s\n' "$on_keys"
printf 'Settings:              temp=%s  n_predict=%s  reps=%s  parallel=1\n' "$TEMP" "$NPREDICT" "$REPS"
echo
echo "Tip: lower acceptance at temp=1.0 is expected; re-run with BENCH_TEMP=0 for the greedy best case."
