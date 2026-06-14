#!/usr/bin/env bash
# 00-prereq-check.sh — verify host meets prereqs from ../nucOptimized.
# Read-only. Exits non-zero on the first missing prereq with a pointer to
# the nucOptimized step that installs it.
set -euo pipefail

fail=0
note() { printf '  %s\n' "$*"; }
ok()   { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[31mMISS\033[0m  %s\n' "$*"; fail=1; }

need_cmd() {
  local cmd=$1 source=$2
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd ($(command -v "$cmd"))"
  else
    bad "$cmd — install via nucOptimized/$source"
  fi
}

echo "Host prereqs (provided by ../nucOptimized):"
need_cmd vulkaninfo  00-base-packages.sh
need_cmd cmake       00-base-packages.sh
need_cmd ninja       00-base-packages.sh
need_cmd git         00-base-packages.sh
need_cmd curl        00-base-packages.sh
need_cmd cc          00-base-packages.sh
need_cmd mise        30-toolchains.sh

# node/npm come from mise — activate the user's shell hooks so we see them.
if command -v mise >/dev/null 2>&1; then
  if mise which node >/dev/null 2>&1; then
    ok "node ($(mise which node))"
  else
    bad "node — run 'mise use -g node@lts' (nucOptimized 30-toolchains.sh installs mise)"
  fi
fi

echo
echo "Render device:"
if [[ -r /dev/dri/renderD128 ]]; then
  ok "/dev/dri/renderD128 readable"
else
  bad "/dev/dri/renderD128 not readable — check 'video'/'render' group membership"
fi

echo
echo "Vulkan device visibility:"
if vulkaninfo --summary 2>/dev/null | grep -q 'deviceName'; then
  vulkaninfo --summary 2>/dev/null | awk '/deviceName/ {print "  OK   " $0}' | head -4
else
  bad "vulkaninfo reports no devices — driver/loader misconfigured"
fi

echo
echo "Mesa version (need >= 26.0 — critical MoE/Vulkan fixes on Strix Halo):"
mesa_ver="$(vulkaninfo 2>/dev/null | grep -m1 -oE 'Mesa [0-9]+\.[0-9]+' | awk '{print $2}')"
if [[ -n "$mesa_ver" ]]; then
  if (( ${mesa_ver%%.*} >= 26 )); then
    ok "Mesa $mesa_ver"
  else
    bad "Mesa $mesa_ver < 26.0 — MoE models run much slower; update the Vulkan/Mesa stack via nucOptimized"
  fi
else
  note "could not read Mesa version from vulkaninfo (verify the RADV driver manually)"
fi

echo
if (( fail )); then
  echo "FAIL — fix the items above (or re-run the relevant nucOptimized step) before continuing."
  exit 1
fi
echo "All prereqs present."
