#!/usr/bin/env bash
# run-all.sh — execute every numbered step in order. Stops on first failure.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

STEPS=(
  00-prereq-check.sh
  10-llama-cpp.sh
  20-models.sh
  30-llama-swap.sh
  99-verify.sh
)

for s in "${STEPS[@]}"; do
  echo
  echo "================================================================"
  echo "  $s"
  echo "================================================================"
  bash "./$s"
done

echo
echo "All steps completed."
