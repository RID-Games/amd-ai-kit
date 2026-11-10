# The Troubleshooting Matrix

Every row below is a real incident on a real AMD box — cardboard chassis, 2020
server card, RDNA4 desktop card — not a hypothetical. Symptoms are listed the way
you will actually encounter them: as a failure, not as a docs page.

## Startup & crashes

| Symptom | Cause | Fix |
|---|---|---|
| llama-server segfaults on first HIP call, stack shows `hipRegisterTracerCallback` in `libamdhip64.so` | Kernel/userspace ABI mismatch — distro ROCm built against a different kernel series than you run | Don't downgrade your kernel. Install TheRock nightly side-by-side and point `LD_LIBRARY_PATH` at its `lib/` **per model**; system ROCm stays untouched |
| Model "loads" but generates at CPU speeds | llama.cpp built for the wrong HIP arch (e.g. gfx1030-only build on an RDNA4 card) | Rebuild with the right `CMAKE_HIP_ARCHITECTURES`; verify with `llama-server --list-devices` **before** trusting any benchmark |
| RDNA4 card not detected by ROCm at all | Card not on the official support matrix yet | TheRock nightly (or `HSA_OVERRIDE_GFX_VERSION` as a blunt instrument); confirm via `--list-devices` |

## GPU selection (multi-GPU)

| Symptom | Cause | Fix |
|---|---|---|
| 20.9 GB model allocation OOMs **on the 16 GB card** although config "points at" the 32 GB one | Binding a second GPU after boot renumbers HIP indexes — index 0 is not your friend | Pin `HIP_VISIBLE_DEVICES` by **UUID** (`rocm-smi --showuniqueid`), never by index |
| Vulkan workload runs on the wrong GPU, slower than CPU | Device picker takes the first *discrete* device enumerated; a second vendor's ICD enumerates first | Pin `VK_DRIVER_FILES` to the AMD `radeon_icd.json` so only the intended driver is visible |

## Timeouts, loading & eviction

| Symptom | Cause | Fix |
|---|---|---|
| Model load killed at exactly N minutes, retried, gets slower each time | `healthCheckTimeout` sits inside your slow-load band; kill+retry **compounds** memory pressure | Measure your own load bands (below); set the timeout above the worst case; keep available RAM above the page-cache cliff |
| Cold loads suddenly take >300 s (was ~60 s) | Available memory below the cliff (~20 GiB on a 64 GB box): the kernel evicts pages as fast as they fault in, so the file is re-read repeatedly | Free RAM or shrink the co-resident model; this band is not fixable by raising timeouts, only by staying above it |
| Chat model evicted mid-conversation; next request takes minutes | Global TTL sized for burst workers applied to an interactive model; cold reload ≈ your health-check timeout | Per-model `ttl` override (e.g. 3600 s — resets on every request, so active sessions never trip it) |
| A model never unloads and starves everything else (swap full, other models failing health checks) | `ttl: 0` with **no** event-driven evictor — the model squats RAM/VRAM forever | Either set a TTL, or implement eviction-by-request (workers ask the server to unload before loading). Never ttl:0 without the second |
| Client dies with "stream idle timeout" while the model is loading or thinking | Client-side idle watchdog (often 300 s default) vs a cold load or slow first token | Raise the client's idle/stream timeout per provider; warm the model on startup if the first-token hit is unacceptable |

## llama-swap & config gotchas

| Symptom | Cause | Fix |
|---|---|---|
| `VAR=value command` prefix in a model `cmd:` fails to exec | llama-swap does **not** run `cmd` through a shell | Use the dedicated `env:` list for variables, not a shell prefix |
| Model + big context OOMs although weights alone fit | KV cache arithmetic ignored | Quantize the cache (`-ctk q8_0 -ctv q8_0`) and do the math: weights + KV at your ctx must fit VRAM |
| systemd unit starts before model files exist | Data mount not ready | `RequiresMountsFor=/path/to/models` in the unit |
| Runaway CPU-inference model freezes the desktop; kernel OOM-kills random processes | No cgroup bound on the service | `MemoryMax=` on the unit so a runaway dies in its own cgroup; pin any auto-sizing caches small and let disk stream |
| Auto-sized expert/cache grabs everything and gets OOM-killed repeatedly | "Auto-size to (MemAvailable − N GB)" computed at load time, not at steady state | Pin the cache explicitly; measure once, hardcode forever |

## Thermals

| Symptom | Cause | Fix |
|---|---|---|
| Passive server card sits at 99–100 °C under sustained load | It's a ducted server card in a gaming case with no duct | Duct + dedicated fans + **sealant**. Measured on this box: 99–100 °C plateau → 69 °C mean under load, VRAM 92 → 66 °C, for ~60 dollars and a print |
| Maxing the case fans makes the card **hotter** | Passive-tunnel card pulls its own intake; chassis airflow fights it | Stop buying airflow. Measure per-fan effects inside a single time window; seal the duct path |
| Card's temperature can't be controlled, only watched | VDI cards expose no `fan*`/`pwm*` interface at all | Fan control lives in hardware (controller board); pair it with a software watchdog that unloads models on thermal bands and trips a poweroff as a last resort |

## The meta-row

Almost every row above is the same bug in different clothes: **a default that was
reasonable on someone else's machine.** Timeouts, indexes, cache sizing, device
selection, airflow assumptions — all defaults, all wrong somewhere else. The fix
pattern never changes: measure your own box, pin everything explicitly, and make
every number's rationale a comment next to the number.
