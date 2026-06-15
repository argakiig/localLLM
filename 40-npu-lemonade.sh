#!/usr/bin/env bash
# 40-npu-lemonade.sh — stand up the AMD XDNA2 NPU backend: Lemonade Server +
# FastFlowLM, and pull the NPU models we serve. This is a *backend* (a peer of
# 10-llama-cpp.sh / 30-llama-swap.sh); the unifying gateway is 60-litellm.sh.
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
LEMONADE_PORT="${LEMONADE_PORT:-13305}"
MAX_LOADED_MODELS="${LEMONADE_MAX_LOADED_MODELS:-4}"
PPA="${LEMONADE_PPA:-ppa:lemonade-team/stable}"
FLM_VERSION="${FLM_VERSION:-0.9.43}"

# NPU models served via FastFlowLM. Edit this list to change what the NPU offers;
# 60-litellm.sh discovers whatever is downloaded and exposes it as npu/*.
NPU_MODELS=(
  qwen3-4b-FLM            # aux LLM: summarize / classify / extract (+ tool calling)
  whisper-v3-turbo-FLM    # ASR / transcription (Hermes STT -> npu/whisper)
  # embed-gemma-300m-FLM  # retired for now — Hermes does no vector embeddings
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

# If flm was just installed, the daemon cached backend availability before it
# existed — restart so it detects the flm:npu backend.
if (( flm_installed_now )); then
  echo ">>> restarting lemond so it detects the new flm backend"
  $SUDO systemctl restart lemond.service
fi

# Wait for the OpenAI API to answer before driving the CLI (it's an HTTP client).
for _ in $(seq 1 30); do
  curl -fsS --max-time 2 "http://127.0.0.1:$LEMONADE_PORT/api/v1/models" >/dev/null 2>&1 && break
  sleep 1
done

echo ">>> setting max_loaded_models=$MAX_LOADED_MODELS (keep NPU + GPU models co-resident)"
lemonade config set "max_loaded_models=$MAX_LOADED_MODELS" >/dev/null 2>&1 || \
  echo "    WARN: could not set max_loaded_models"

# ---------------------------------------------------------------------------
# 4) Pull the NPU models (idempotent — pull is a no-op if already present).
# ---------------------------------------------------------------------------
for m in "${NPU_MODELS[@]}"; do
  echo ">>> pulling NPU model: $m"
  lemonade pull "$m" >/dev/null 2>&1 && echo "    ok" || echo "    WARN: pull failed for $m"
done

cat <<EOF

NPU backend is up:
  Lemonade     http://127.0.0.1:$LEMONADE_PORT/api/v1   (recipe=flm)
  NPU models:  ${NPU_MODELS[*]}
  Validate:    flm validate
  Logs:        journalctl -u lemond -f

  Next: 60-litellm.sh exposes these (npu/*) + llama-swap (gpu/*) behind one API.
EOF
