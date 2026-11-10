# amd-ai-kit

**Software is easy. Buy *more* hardware.**

Production llama-swap configs, hardened systemd units, and the war stories that
explain every tuning value — for running local LLMs on AMD GPUs (RDNA4 +
CDNA/server cards) without CUDA. This is the config layer that took ~200 hours
of ROCm pain to arrive at; it is rendered from your `.env`, so nothing is
hardcoded to anyone's box.

Measured proof this stack is real, published with the logs attached:

- **[Field Log 001 - 27B at 30 tok/s on a $376 32GB server GPU, no CUDA](https://blog.rebelintelligencedetachment.com/posts/27b-on-a-565-dollar-gpu/)** -
  Qwen3.8-27B Q6_K at **30.5-32.2 tok/s decode**, 196K context, on a Radeon Pro
  V620: MTP speculative decode at **92% draft acceptance**, six probe runs, five
  within 0.25 tok/s of each other.
- **[Field Log 002 - Running a 180B model on that same card](https://blog.rebelintelligencedetachment.com/posts/expanding-integration/)** -
  an 87 GiB MoE served from VRAM, pinned RAM and NVMe as one cache: prefill at
  90K **194 -> ~750 tok/s**, decode **13 -> 26-40 tok/s**, for the price of a
  64 GB RAM kit.

Both posts carry the probe output, the exact flags, and the traps that cost a
month. No CUDA anywhere.

## What this is

- Three llama-swap profiles (16 GB RDNA4 card / 32 GB server card / CPU
  expert-streaming) with per-model TTLs, health-check timeouts, and KV-cache
  quantization tuned from *measured* load times — every value's rationale is a
  comment in the config.
- **[The Troubleshooting Matrix](docs/troubleshooting.md)** — every incident on
  the reference box distilled to symptom → cause → fix, from the
  `hipRegisterTracerCallback` segfault to the case-fans-made-it-worse experiment.
- Hardened systemd user units (`NoNewPrivileges`, `ProtectSystem=full`,
  `RequiresMountsFor`, `MemoryMax` on the CPU profile so a runaway dies in its
  cgroup instead of freezing your desktop).
- A pure-bash installer that renders templates from `.env` — no gettext, no
  Python, no root.

## What this is not

- **Not model weights.** You download your own GGUFs.
- **Not a CUDA port.** This targets ROCm / TheRock / Vulkan (radv).
- **Not a daemon.** llama-swap is upstream ([mostlygeek/llama-swap](https://github.com/mostlygeek/llama-swap)) — the installer links to its releases, it does not bundle binaries.

## Quickstart

```bash
cp .env.example .env    # also created automatically on first run
$EDITOR .env            # paths, ports, GPU UUIDs — one screen, no secrets
./install.sh --dry-run  # renders to ./rendered/ — inspect before anything is touched
./install.sh 9060xt     # render for real (or: v620 | cpu | all)
systemctl --user start llama-swap-9060xt
curl -s http://127.0.0.1:11430/v1/models | head
```

Profiles:

| Profile | Card class | Models served | API port (default) |
|---|---|---|---|
| `9060xt` | 16 GB RDNA4 (RX 9060/9070 XT) | Gemma-4-12B, MiniCPM5-2B, Qwen3-8B (2 slots) | 11430 |
| `v620`   | 32 GB server card (V620 class) | Qwen3.8-27B Q6_K + MTP spec-decode | 11435 |
| `cpu`    | RAM + optional Vulkan offload | GLM-5.3-Flash via colibri | 11440 |

## Secrets policy

Tokens (HuggingFace etc.) live in **one file**: `~/.config/amd-ai-kit/secrets.env`,
mode 600, created on first `install.sh` run. It is never rendered into configs,
never referenced by systemd units, never committed. Helper scripts source it.
If a token has ever been in a script, config, or shell history: rotate it,
don't just delete the line.

## GPU selection: UUIDs, not indexes

Find your card UUIDs with `rocm-smi --showuniqueid`. Put them in `.env`
(`GPU_CHAT_UUID`, `GPU_LLM_UUID`); leave empty on a single-GPU box.

Why: binding a second GPU after boot renumbers HIP indexes. On the reference
box that pointed a 20.9 GB model at the 16 GB card and OOM'd — the config
comment in `llama-swap-v620.yaml` has the full story.

## ROCm flavor: system vs TheRock

If your distro's ROCm crashes on your kernel (the reference box: Arch ROCm
7.2.4 vs kernel 7.1.9), don't fight it — run a nightly [TheRock](https://github.com/ROCm/TheRock)
userspace side-by-side and point `THEROCK_LIB` in `.env` at its `lib/` dir.
Configs render it as `LD_LIBRARY_PATH` per-model, so system ROCm stays
untouched. Leave `THEROCK_LIB` empty to use system ROCm.

## Building llama.cpp for AMD

```bash
cmake -B build -DGGML_HIP=ON -DCMAKE_HIP_ARCHITECTURES="gfx1200" \
      -DROCM_PATH=/opt/rocm ...
cmake --build build -j
./build/bin/llama-server --list-devices   # must show your card before you trust anything
```

Match `CMAKE_HIP_ARCHITECTURES` to your card (gfx1200 = RDNA4 9060/9070 class;
gfx1030 = RDNA2; wrong arch = silent fallback or crash). A full recipe with
per-card values and the `--list-devices` verification step is in the kit docs.

## License

MIT (see `LICENSE`). Configures upstream software it does not include:
llama-swap, llama.cpp (MIT), colibri (Apache-2.0).

## Working with me

This repo is the handover artifact: if you hire me to set this up, this is the
state you get it in - rendered configs, units that survive a reboot, and every
tuning value justified in a comment. If you'd rather not do it yourself,
**[contract work: local & self-hosted AI deployment](https://blog.rebelintelligencedetachment.com/hire/)** -
fixed price, async, and you keep the written diagnosis either way.
