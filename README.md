# localLLM

Bootstrap scripts for rebuilding the local inference stack from this repository.
The scripts are numbered, idempotent, and keep generated source, binaries, and
state under `build/` wherever possible.

## What This Builds

- `llama.cpp` with the Vulkan backend, linked into `build/bin/`.
- GGUF model files listed in `models.list`.
- Lemonade Server as the front-door OpenAI-compatible API, serving NPU models via
  FastFlowLM, `qwen36-35b` through Lemonade's llama.cpp Vulkan backend, and
  `SD-Turbo` through Lemonade's sd-cpp Vulkan backend.

## Architecture

```text
clients
  |
  | OpenAI-compatible requests
  v
Lemonade :13305/api/v1
  |
  +-- qwen3.5-4b-FLM          -> FastFlowLM / XDNA2 NPU
  +-- whisper-v3-turbo-FLM  -> FastFlowLM / XDNA2 NPU
  +-- qwen36-35b            -> llama.cpp Vulkan / Radeon iGPU
  +-- SD-Turbo              -> sd-cpp Vulkan / Radeon iGPU
```

The GPU text model is registered in Lemonade as `qwen36-35b`. Lemonade is the
router; there is no separate `llama-router`, LiteLLM, Postgres gateway, or
default standalone image server.

## Host Assumptions

The text stack expects a Linux host with:

- AMD Ryzen AI MAX+ 395 class hardware, or another Vulkan-capable host with
  enough shared memory for the configured models.
- Vulkan runtime and readable render device.
- Mesa 26 or newer for the Vulkan path used by these models.
- `cmake`, `ninja`, `git`, `curl`, C compiler, `mise`, and Node through `mise`.
- Lemonade Server (`lemond.service`) and FastFlowLM.

`00-prereq-check.sh` verifies these assumptions without changing the host.

## Bootstrap Scripts

| Step | Script | What it does |
|------|--------|--------------|
| 00 | `00-prereq-check.sh` | Read-only host checks for toolchain, Vulkan, render device, and Mesa. |
| 10 | `10-llama-cpp.sh` | Builds pinned `llama.cpp` with Vulkan and links binaries into `build/bin/`. |
| 20 | `20-models.sh` | Downloads GGUF files from `models.list` into `$LOCALLLM_MODELS_DIR`. |
| 40 | `40-npu-lemonade.sh` | Installs/configures Lemonade, FastFlowLM NPU models, Qwen GPU GGUF, and SD-Turbo through sd-cpp. |
| 50 | `50-stable-diffusion.sh` | Optional standalone image stack outside Lemonade: builds `stable-diffusion.cpp`, fetches SD-Turbo, and smoke-tests image generation. |
| 99 | `99-verify.sh` | Read-only verification for binaries, models, Lemonade service, retired services, and a completion round trip. |

`run-all.sh` runs the full Lemonade stack and verification. It does not run the
standalone `50-stable-diffusion.sh` path because Lemonade's `SD-Turbo` backend is
the default image-generation route.

## Quick Start

```sh
./run-all.sh
```

To build the optional standalone image stack:

```sh
./50-stable-diffusion.sh
```

To skip image-model downloads while checking the build path:

```sh
SD_FETCH_MODELS=0 SD_SMOKE_TEST=0 ./50-stable-diffusion.sh
```

## Text Gateway Usage

### Network Default

The docs and helper scripts use `10.0.0.30` as the expected LAN address for the
localLLM host. If this host moves to a different address, set
`LOCALLLM_BIND_HOST` before running the service, helpers, or verification.

```sh
# List available Lemonade models.
./use-model.sh list

# Warm a configured model.
./use-model.sh load qwen36-35b

# Unload one model, or all models from Lemonade.
./use-model.sh unload qwen36-35b
./use-model.sh unload
```

OpenAI-compatible request:

```sh
BASE="http://10.0.0.30:${LEMONADE_PORT:-13305}/api/v1"
curl "$BASE/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen36-35b","messages":[{"role":"user","content":"Reply: ok /no_think"}],"max_tokens":8}'
```

Useful operations:

```sh
curl "$BASE/models"
journalctl -u lemond -f
lemonade list --downloaded
```

## Image Generation Usage

Lemonade exposes the image backend as model `SD-Turbo`:

```sh
BASE="http://10.0.0.30:${LEMONADE_PORT:-13305}/api/v1"
curl "$BASE/images/generations" \
  -H 'Content-Type: application/json' \
  -d '{"model":"SD-Turbo","prompt":"a clean product render of a small brass desk lamp","size":"512x512","n":1}'
```

The standalone `stable-diffusion.cpp` lane is still available if you want SD-Turbo
outside Lemonade. After `50-stable-diffusion.sh` completes:

```sh
SD_MODELS_DIR="${SD_MODELS_DIR:-$HOME/sdmodels}"
build/bin/sd-cli \
  --diffusion-model "$SD_MODELS_DIR/flux1-schnell-q8_0.gguf" \
  --vae "$SD_MODELS_DIR/ae.safetensors" \
  --clip_l "$SD_MODELS_DIR/clip_l.safetensors" \
  --t5xxl "$SD_MODELS_DIR/t5xxl_fp16.safetensors" \
  --cfg-scale 1.0 \
  --sampling-method euler \
  --steps 4 \
  -W 1024 -H 1024 \
  -p "your prompt, plain white background" \
  -o asset.png
```

The smoke-test output is `build/sd-smoke.png`.

## Environment Variables

| Variable | Default | Used by |
|----------|---------|---------|
| `LOCALLLM_MODELS_DIR` | `~/models` | `20-models.sh`, `40-npu-lemonade.sh`, `99-verify.sh` |
| `LOCALLLM_BIND_HOST` | `10.0.0.30` | `40-npu-lemonade.sh`, `use-model.sh`, `99-verify.sh` |
| `LEMONADE_PORT` | `13305` | `40-npu-lemonade.sh`, `use-model.sh`, `99-verify.sh` |
| `LEMONADE_GPU_MODEL_ID` | `qwen36-35b` | `40-npu-lemonade.sh` |
| `LEMONADE_GPU_CHECKPOINT` | Qwen3.6 GGUF Hugging Face checkpoint | `40-npu-lemonade.sh` |
| `LEMONADE_IMAGE_MODEL_ID` | `SD-Turbo` | `40-npu-lemonade.sh` |
| `LEMONADE_IMAGE_SIZE` | `512` | `40-npu-lemonade.sh` |
| `LEMONADE_IMAGE_STEPS` | `4` | `40-npu-lemonade.sh` |
| `LEMONADE_IMAGE_CFG` | `1.0` | `40-npu-lemonade.sh` |
| `LEMONADE_GPU_CTX_SIZE` | `262144` | `40-npu-lemonade.sh` |
| `LEMONADE_LLAMACPP_ARGS` | Qwen tuned Vulkan args | `40-npu-lemonade.sh` |
| `LLAMA_CPP_REPO` | repository URL configured in the script | `10-llama-cpp.sh` |
| `LLAMA_CPP_REF` | pinned commit in `10-llama-cpp.sh` | `10-llama-cpp.sh` |
| `SD_CPP_REPO` | repository URL configured in the script | `50-stable-diffusion.sh` |
| `SD_CPP_REF` | pinned commit in `50-stable-diffusion.sh` | `50-stable-diffusion.sh` |
| `SD_MODELS_DIR` | `~/sdmodels` | `50-stable-diffusion.sh` |
| `SD_FETCH_MODELS` | `1` | `50-stable-diffusion.sh` |
| `SD_SMOKE_TEST` | `1` | `50-stable-diffusion.sh` |

## Adding a Text Model

1. Add the GGUF file to `models.list`.
2. Run `./20-models.sh`.
3. Register it in `40-npu-lemonade.sh` with `lemonade pull <name> --recipe llamacpp`.
4. Run `./40-npu-lemonade.sh`.
5. Run `LOCALLLM_VERIFY_MODEL=<name> ./99-verify.sh`.

## Generated State

`build/` contains generated source checkouts, compiled binaries, linked binaries,
downloaded helper binaries, and marker files. Lemonade model registrations and
backend state are managed by Lemonade Server.
