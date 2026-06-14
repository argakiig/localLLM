#!/usr/bin/env bash
# 20-models.sh — fetch GGUF models listed in models.list into LOCALLLM_MODELS_DIR.
# Idempotent: skips files that already exist and pass a GGUF magic check.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

MODELS_DIR="${LOCALLLM_MODELS_DIR:-$HOME/models}"
LIST="${1:-models.list}"

mkdir -p "$MODELS_DIR"

is_gguf() {
  # GGUF files begin with the ASCII magic "GGUF".
  [[ -f "$1" ]] && [[ "$(head -c 4 "$1" 2>/dev/null)" == "GGUF" ]]
}

count=0
while IFS=$' \t' read -r rel url _rest || [[ -n "${rel:-}" ]]; do
  [[ -z "${rel:-}" ]] && continue
  [[ "$rel" =~ ^# ]] && continue
  [[ -z "${url:-}" ]] && { echo "skipping malformed line: $rel"; continue; }

  count=$((count+1))
  dst="$MODELS_DIR/$rel"
  mkdir -p "$(dirname "$dst")"

  if is_gguf "$dst"; then
    echo "OK   $rel ($(du -h "$dst" | cut -f1))"
    continue
  fi

  echo ">>>  $rel"
  echo "     from $url"
  curl --location --fail --progress-bar --continue-at - --output "$dst.part" "$url"
  mv "$dst.part" "$dst"

  if ! is_gguf "$dst"; then
    echo "ERR  $rel — downloaded file is not a valid GGUF" >&2
    exit 1
  fi
  echo "OK   $rel ($(du -h "$dst" | cut -f1))"
done < "$LIST"

if (( count == 0 )); then
  echo "No model entries in $LIST." >&2
  exit 1
fi

# Drop a marker the server and verify scripts can read.
ln -sfn "$MODELS_DIR" build/models-dir 2>/dev/null || true
echo "$MODELS_DIR" > build/.models-dir

echo
echo "Models present in $MODELS_DIR:"
ls -lh "$MODELS_DIR" | awk 'NR>1 {printf "  %s  %s\n", $5, $NF}'
