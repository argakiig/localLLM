# localLLM

Bootstrap scripts for rebuilding the local inference stack from this repository.
The scripts are numbered, idempotent, and keep generated source, binaries, and
state under `build/` wherever possible.

## What This Builds

- `llama.cpp` with the Vulkan backend, linked into `build/bin/`.
- GGUF model files listed in `models.list`.
- `llama-swap` as one OpenAI-compatible endpoint that routes by model name.
- Optional `stable-diffusion.cpp` image generation binaries and FLUX.1-schnell
  model assets.

## Architecture

```text
clients
  |
  | OpenAI-compatible requests, model = configured name
  v
llama-swap
  |
  +-- embed
  +-- rerank
  +-- gemma4_12b
  +-- gemma4_26b
  +-- gemma4_31b
  +-- step37_q2
  +-- step37_q3
```

`llama-swap` owns model lifecycle. Requests select the model by the OpenAI
`model` field, and the generated matrix controls which models may stay loaded
together. The current resident set is `embed`, `rerank`, and `gemma4_26b`.
Larger alternates load on demand with `embed` and `rerank` kept warm.

## Host Assumptions

The text stack expects a Linux host with:

- AMD Ryzen AI MAX+ 395 class hardware, or another Vulkan-capable host with
  enough shared memory for the configured models.
- Vulkan runtime and readable render device.
- Mesa 26 or newer for the Vulkan path used by these models.
- `cmake`, `ninja`, `git`, `curl`, C compiler, `mise`, and Node through `mise`.
- User systemd available for `llama-swap.service`.

`00-prereq-check.sh` verifies these assumptions without changing the host.

## Bootstrap Scripts

| Step | Script | What it does |
|------|--------|--------------|
| 00 | `00-prereq-check.sh` | Read-only host checks for toolchain, Vulkan, render device, and Mesa. |
| 10 | `10-llama-cpp.sh` | Builds pinned `llama.cpp` with Vulkan and links binaries into `build/bin/`. |
| 20 | `20-models.sh` | Downloads GGUF files from `models.list` into `$LOCALLLM_MODELS_DIR`. |
| 30 | `30-llama-swap.sh` | Installs pinned `llama-swap`, writes config, and starts `llama-swap.service`. |
| 50 | `50-stable-diffusion.sh` | Optional image stack: builds `stable-diffusion.cpp`, fetches FLUX.1-schnell assets, and smoke-tests image generation. |
| 99 | `99-verify.sh` | Read-only text-stack verification for binaries, models, service, endpoint, and a completion round trip. |

`run-all.sh` runs `00`, `10`, `20`, `30`, and `99`. It does not run the optional
image generation step.

## Quick Start

```sh
./run-all.sh
```

To include the optional image generation stack:

```sh
./50-stable-diffusion.sh
```

To skip image-model downloads while checking the build path:

```sh
SD_FETCH_MODELS=0 SD_SMOKE_TEST=0 ./50-stable-diffusion.sh
```

## llama-swap Usage

### Network Default

The docs and helper scripts use `10.0.0.30` as the expected LAN address for the
localLLM host. If this host moves to a different address, set
`LOCALLLM_BIND_HOST` before running the service, helpers, or verification.

```sh
# List available and currently running models.
./use-model.sh list

# Warm a configured model.
./use-model.sh load gemma4_26b

# Unload one model, or all models.
./use-model.sh unload gemma4_26b
./use-model.sh unload
```

Direct OpenAI-compatible request:

```sh
BASE="http://10.0.0.30:${LOCALLLM_LLAMASWAP_PORT:-9090}"
curl "$BASE/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"gemma4_26b","messages":[{"role":"user","content":"Reply: ok /no_think"}],"max_tokens":8}'
```

Useful operations:

```sh
curl "$BASE/v1/models"
curl "$BASE/running"
curl "$BASE/upstream/gemma4_26b/props"
curl -X POST "$BASE/models/unload"
```

## Image Generation Usage

After `50-stable-diffusion.sh` completes:

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
| `LOCALLLM_MODELS_DIR` | `~/models` | `20-models.sh`, `30-llama-swap.sh`, `99-verify.sh` |
| `LOCALLLM_BIND_HOST` | `10.0.0.30` for helper and verification URLs; empty service listen unless set | `30-llama-swap.sh`, `use-model.sh`, `99-verify.sh` |
| `LOCALLLM_THREADS` | `16` | `30-llama-swap.sh` |
| `LOCALLLM_GPU_LAYERS` | `999` | `30-llama-swap.sh` |
| `LOCALLLM_LLAMASWAP_PORT` | `9090` | `30-llama-swap.sh`, `use-model.sh`, `99-verify.sh` |
| `LLAMA_CPP_REPO` | repository URL configured in the script | `10-llama-cpp.sh` |
| `LLAMA_CPP_REF` | pinned commit in `10-llama-cpp.sh` | `10-llama-cpp.sh` |
| `LLAMA_SWAP_VERSION` | `v217` | `30-llama-swap.sh` |
| `SD_CPP_REPO` | repository URL configured in the script | `50-stable-diffusion.sh` |
| `SD_CPP_REF` | pinned commit in `50-stable-diffusion.sh` | `50-stable-diffusion.sh` |
| `SD_MODELS_DIR` | `~/sdmodels` | `50-stable-diffusion.sh` |
| `SD_FETCH_MODELS` | `1` | `50-stable-diffusion.sh` |
| `SD_SMOKE_TEST` | `1` | `50-stable-diffusion.sh` |

## Adding a Text Model

1. Add the GGUF file to `models.list`.
2. Run `./20-models.sh`.
3. Add an entry to `INSTANCES` in `30-llama-swap.sh`.
4. Add the model to the matrix set that matches its memory behavior.
5. Run `./30-llama-swap.sh`.
6. Run `LOCALLLM_VERIFY_MODEL=<name> ./99-verify.sh`.

## Generated State

`build/` contains generated source checkouts, compiled binaries, linked binaries,
downloaded helper binaries, and marker files. Remove `build/` and rerun the
numbered scripts to rebuild generated artifacts from scratch.
